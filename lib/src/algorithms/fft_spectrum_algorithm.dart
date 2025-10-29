import 'dart:math';

import 'package:bpm/src/algorithms/bpm_detection_algorithm.dart';
import 'package:bpm/src/algorithms/detection_context.dart';
import 'package:bpm/src/dsp/fft_utils.dart';
import 'package:bpm/src/dsp/signal_utils.dart';
import 'package:bpm/src/models/bpm_models.dart';

class FftSpectrumAlgorithm extends BpmDetectionAlgorithm {
  FftSpectrumAlgorithm({
    this.maxWindowSeconds = 4,
    this.targetSampleRate = 16000,
  });
  final int maxWindowSeconds;
  final int targetSampleRate;

  @override
  String get id => 'fft_spectrum';

  @override
  String get label => 'FFT Spectrum';

  @override
  Duration get preferredWindow => const Duration(seconds: 12);

  @override
  Future<BpmReading?> analyze({
    required List<AudioFrame> window,
    required DetectionContext context,
  }) async {
    if (window.isEmpty) return null;

    var samples = SignalUtils.normalize(
      window.expand((frame) => frame.samples).toList(),
    );

    if (samples.length < context.sampleRate ~/ 2) {
      return null;
    }

    final decimation =
        max(1, (context.sampleRate / targetSampleRate).ceil());
    final effectiveSampleRate =
        max(1, (context.sampleRate / decimation).round());
    if (decimation > 1) {
      samples = SignalUtils.downsample(samples, decimation);
    }

    final envelope = _energyEnvelope(samples);
    if (envelope.isEmpty ||
        envelope.every((value) => value == 0 || value.isNaN)) {
      return null;
    }

    final maxSamples = min(
      envelope.length,
      effectiveSampleRate * maxWindowSeconds,
    );
    if (maxSamples < 256) {
      return null;
    }

    final trimmed =
        envelope.length > maxSamples ? envelope.sublist(0, maxSamples) : envelope;
    if (trimmed.every((value) => value == 0)) {
      return null;
    }

    final fftSize = _boundedPowerOfTwo(trimmed.length);

    final padded = List<double>.filled(fftSize, 0)
      ..setRange(0, min(trimmed.length, fftSize), trimmed);

    final windowed = SignalUtils.applyHannWindow(padded);
    final spectrum = FftUtils.magnitudeSpectrum(windowed);
    if (spectrum.magnitudes.isEmpty) {
      return null;
    }

    final freqResolution = effectiveSampleRate / spectrum.size;
    var bestBpm = 0.0;
    var bestMagnitude = 0.0;

    final minIndex = max(
      1,
      (context.minBpm / 60 / freqResolution).ceil(),
    );
    final maxIndex = min(
      spectrum.magnitudes.length - 1,
      (context.maxBpm / 60 / freqResolution).floor(),
    );
    if (maxIndex <= minIndex) {
      return null;
    }

    for (var i = minIndex; i <= maxIndex; i++) {
      final frequencyHz = i * freqResolution;
      final bpm = frequencyHz * 60;
      final magnitude = spectrum.magnitudes[i];
      if (magnitude > bestMagnitude) {
        bestMagnitude = magnitude;
        bestBpm = bpm;
      }
    }

    if (bestMagnitude <= 0) {
      return null;
    }

    final totalMagnitude = spectrum.magnitudes
        .sublist(minIndex, maxIndex + 1)
        .fold<double>(0, (sum, mag) => sum + mag);
    final averageMagnitude = totalMagnitude == 0
        ? 1
        : totalMagnitude / (maxIndex - minIndex + 1);
    final confidence =
        (bestMagnitude / averageMagnitude).clamp(0.0, 1.0);

    return BpmReading(
      algorithmId: id,
      algorithmName: label,
      bpm: bestBpm,
      confidence: confidence,
      timestamp: DateTime.now().toUtc(),
      metadata: {
        'fftSize': fftSize,
        'decimation': decimation,
        'effectiveSampleRate': effectiveSampleRate,
      },
    );
  }
}

int _boundedPowerOfTwo(int sampleCount) {
  final desired = max(1024, sampleCount);
  final nextPower = SignalUtils.nextPowerOfTwo(desired);
  return min(8192, nextPower);
}

List<double> _energyEnvelope(List<double> samples) {
  if (samples.isEmpty) {
    return const [];
  }

  const alpha = 0.1;
  var running = samples.first.abs();
  final envelope = List<double>.filled(samples.length, 0);
  for (var i = 0; i < samples.length; i++) {
    final magnitude = samples[i].abs();
    running = alpha * magnitude + (1 - alpha) * running;
    envelope[i] = running;
  }

  final withoutDc = SignalUtils.removeMean(envelope);
  return SignalUtils.normalize(withoutDc);
}
