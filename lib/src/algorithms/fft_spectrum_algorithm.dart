import 'dart:math';

import 'package:bpm/src/algorithms/bpm_detection_algorithm.dart';
import 'package:bpm/src/algorithms/detection_context.dart';
import 'package:bpm/src/dsp/fft_utils.dart';
import 'package:bpm/src/dsp/signal_utils.dart';
import 'package:bpm/src/models/bpm_models.dart';

class FftSpectrumAlgorithm extends BpmDetectionAlgorithm {
  FftSpectrumAlgorithm({
    this.minMagnitudeRatio = 0.25,
    this.maxWindowSeconds = 4,
    this.targetSampleRate = 16000,
  });

  final double minMagnitudeRatio;
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

    final maxSamples = min(
      samples.length,
      effectiveSampleRate * maxWindowSeconds,
    );
    if (maxSamples < 512) {
      return null;
    }

    final fftSize = _boundedPowerOfTwo(maxSamples);

    final padded = List<double>.filled(fftSize, 0)
      ..setRange(0, min(samples.length, fftSize), samples);

    final windowed = SignalUtils.applyHannWindow(padded);
    final spectrum = FftUtils.magnitudeSpectrum(windowed);
    if (spectrum.magnitudes.isEmpty) {
      return null;
    }

    final freqResolution = effectiveSampleRate / spectrum.size;
    var bestBpm = 0.0;
    var bestMagnitude = 0.0;

    for (var i = 1; i < spectrum.magnitudes.length; i++) {
      final frequencyHz = i * freqResolution;
      final bpm = frequencyHz * 60;
      if (bpm < context.minBpm || bpm > context.maxBpm) {
        continue;
      }

      final magnitude = spectrum.magnitudes[i];
      if (magnitude > bestMagnitude) {
        bestMagnitude = magnitude;
        bestBpm = bpm;
      }
    }

    if (bestMagnitude <= 0) {
      return null;
    }

    final totalMagnitude =
        spectrum.magnitudes.fold<double>(0, (sum, mag) => sum + mag);
    final averageMagnitude = totalMagnitude == 0
        ? 1
        : totalMagnitude / spectrum.magnitudes.length;
    final confidence =
        (bestMagnitude / averageMagnitude).clamp(0.0, 1.0);

    if (confidence < minMagnitudeRatio) {
      return null;
    }

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
