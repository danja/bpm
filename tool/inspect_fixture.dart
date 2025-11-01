import 'dart:io';
import 'dart:typed_data';

import 'package:bpm/src/algorithms/autocorrelation_algorithm.dart';
import 'package:bpm/src/algorithms/bpm_detection_algorithm.dart';
import 'package:bpm/src/algorithms/detection_context.dart';
import 'package:bpm/src/algorithms/fft_spectrum_algorithm.dart';
import 'package:bpm/src/algorithms/simple_onset_algorithm.dart';
import 'package:bpm/src/algorithms/wavelet_energy_algorithm.dart';
import 'package:bpm/src/dsp/preprocessing_pipeline.dart';
import 'package:bpm/src/core/robust_consensus_engine.dart';
import 'package:bpm/src/models/bpm_models.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('Usage: dart run tool/inspect_fixture.dart <wav filename>');
    exit(64);
  }

  final filename = args.first;
  final file = File('data/$filename');
  if (!file.existsSync()) {
    stderr.writeln('Fixture not found at ${file.path}');
    exit(66);
  }

  final context = const DetectionContext(
    sampleRate: 44100,
    minBpm: 50,
    maxBpm: 250,
    windowDuration: Duration(seconds: 6),
  );

  final pipeline = const PreprocessingPipeline();
  final wav = _loadPcm16Wav(file.path);
  final frames = _framesFromSamples(
    wav.samples,
    sampleRate: wav.sampleRate,
  );

  final signal = pipeline.process(
    window: frames,
    context: context,
  );

  final algorithms = <BpmDetectionAlgorithm>[
    SimpleOnsetAlgorithm(),
    AutocorrelationAlgorithm(),
    FftSpectrumAlgorithm(),
    WaveletEnergyAlgorithm(levels: 2),
  ];

  print('Analyzing $filename...');
  final readings = <BpmReading>[];
  for (final algorithm in algorithms) {
    final reading = await algorithm.analyze(signal: signal);
    print(
        '${algorithm.runtimeType}: BPM=${reading?.bpm}, conf=${reading?.confidence}');
    if (reading != null) {
      print('  metadata: ${reading.metadata}');
      readings.add(reading);
    }
  }

  final consensusEngine = RobustConsensusEngine();
  final normalized = consensusEngine.debugNormalizeForTesting(readings);
  for (final reading in normalized) {
    print(
        'Normalized ${reading.algorithmId}: BPM=${reading.bpm.toStringAsFixed(3)}, conf=${reading.confidence.toStringAsFixed(3)}, metadata=${reading.metadata}',
        );
  }
  final consensus = consensusEngine.combine(readings);
  print('Consensus => ${consensus?.bpm} (conf=${consensus?.confidence})');
  if (consensus != null) {
    print('  weights: ${consensus.weights}');
  }
}

class _WavData {
  _WavData({
    required this.samples,
    required this.sampleRate,
    required this.channels,
  });

  final List<double> samples;
  final int sampleRate;
  final int channels;
}

_WavData _loadPcm16Wav(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    throw ArgumentError('WAV file not found at $path');
  }

  final bytes = file.readAsBytesSync();
  if (bytes.length < 44) {
    throw FormatException('WAV file too short');
  }

  if (String.fromCharCodes(bytes.sublist(0, 4)) != 'RIFF' ||
      String.fromCharCodes(bytes.sublist(8, 12)) != 'WAVE') {
    throw FormatException('Unsupported WAV header');
  }

  final data = ByteData.sublistView(bytes);

  int? sampleRate;
  int? bitsPerSample;
  int? channels;
  Uint8List? pcmBytes;

  var offset = 12;
  while (offset + 8 <= bytes.length) {
    final chunkId = String.fromCharCodes(bytes.sublist(offset, offset + 4));
    final chunkSize = data.getUint32(offset + 4, Endian.little);
    final chunkStart = offset + 8;
    final chunkEnd = chunkStart + chunkSize;
    if (chunkEnd > bytes.length) {
      break;
    }

    if (chunkId == 'fmt ') {
      if (chunkSize < 16) {
        throw FormatException('Invalid fmt chunk size');
      }
      final audioFormat = data.getUint16(chunkStart, Endian.little);
      channels = data.getUint16(chunkStart + 2, Endian.little);
      sampleRate = data.getUint32(chunkStart + 4, Endian.little);
      bitsPerSample = data.getUint16(chunkStart + 14, Endian.little);
      if (audioFormat != 1 || bitsPerSample != 16) {
        throw FormatException(
          'Only PCM16 WAV files are supported (format=$audioFormat, bits=$bitsPerSample)',
        );
      }
    } else if (chunkId == 'data') {
      pcmBytes = bytes.sublist(chunkStart, chunkEnd);
    }

    offset = chunkEnd + (chunkSize.isOdd ? 1 : 0);
  }

  if (sampleRate == null ||
      bitsPerSample == null ||
      channels == null ||
      pcmBytes == null) {
    throw FormatException('Incomplete WAV file (missing fmt or data chunk)');
  }

  final bytesPerSample = bitsPerSample ~/ 8;
  final frameSize = bytesPerSample * channels;
  final frameCount = pcmBytes.length ~/ frameSize;
  final samples = List<double>.filled(frameCount, 0);
  final pcmData = ByteData.sublistView(pcmBytes);

  for (var i = 0; i < frameCount; i++) {
    var sum = 0.0;
    for (var ch = 0; ch < channels; ch++) {
      final index = (i * channels + ch) * bytesPerSample;
      final sample = pcmData.getInt16(index, Endian.little) / 32768.0;
      sum += sample;
    }
    samples[i] = sum / channels;
  }

  return _WavData(
    samples: samples,
    sampleRate: sampleRate,
    channels: channels,
  );
}

List<AudioFrame> _framesFromSamples(
  List<double> samples, {
  required int sampleRate,
  int frameSize = 2048,
}) {
  final frames = <AudioFrame>[];
  var sequence = 0;
  for (var i = 0; i < samples.length; i += frameSize) {
    final chunk = samples.sublist(
      i,
      i + frameSize > samples.length ? samples.length : i + frameSize,
    );
    frames.add(
      AudioFrame(
        samples: chunk,
        sampleRate: sampleRate,
        channels: 1,
        sequence: sequence++,
      ),
    );
  }
  return frames;
}
