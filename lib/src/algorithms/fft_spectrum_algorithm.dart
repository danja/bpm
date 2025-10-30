import 'dart:math';

import 'package:bpm/src/algorithms/algorithm_utils.dart';
import 'package:bpm/src/algorithms/bpm_detection_algorithm.dart';
import 'package:bpm/src/dsp/fft_utils.dart';
import 'package:bpm/src/dsp/preprocessing_pipeline.dart';
import 'package:bpm/src/dsp/signal_utils.dart';
import 'package:bpm/src/models/bpm_models.dart';

/// FFT-based tempo detection analyzing the energy envelope spectrum.
///
/// Now uses pre-downsampled 400Hz signal from preprocessing pipeline,
/// eliminating redundant downsampling and improving performance.
class FftSpectrumAlgorithm extends BpmDetectionAlgorithm {
  FftSpectrumAlgorithm({
    this.maxWindowSeconds = 6,
    this.minFftSize = 2048,
  });

  final int maxWindowSeconds;
  final int minFftSize;

  @override
  String get id => 'fft_spectrum';

  @override
  String get label => 'FFT Spectrum';

  @override
  Duration get preferredWindow => const Duration(seconds: 12);

  @override
  Future<BpmReading?> analyze({
    required PreprocessedSignal signal,
  }) async {
    // Use pre-downsampled 400Hz signal from preprocessing
    var samples = List<double>.from(signal.samples400Hz);
    const effectiveSampleRate = 400; // Target sample rate from preprocessing

    if (samples.isEmpty || samples.length < 200) {
      return null;
    }

    // Create energy envelope
    final envelope = _energyEnvelope(samples);
    if (envelope.isEmpty ||
        envelope.every((value) => value == 0 || value.isNaN)) {
      return null;
    }

    final maxSamples = min(
      envelope.length,
      effectiveSampleRate * maxWindowSeconds,
    );
    if (maxSamples < minFftSize ~/ 2) {
      return null;
    }

    final trimmed =
        envelope.length > maxSamples ? envelope.sublist(0, maxSamples) : envelope;
    if (trimmed.every((value) => value == 0)) {
      return null;
    }

    final fftSize = _boundedPowerOfTwo(trimmed.length, minFftSize);

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

    // Find peak in BPM range
    final minIndex = max(
      1,
      (signal.context.minBpm / 60 / freqResolution).ceil(),
    );
    final maxIndex = min(
      spectrum.magnitudes.length - 1,
      (signal.context.maxBpm / 60 / freqResolution).floor(),
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
    final adjustment = AlgorithmUtils.coerceToRange(
      bestBpm,
      minBpm: signal.context.minBpm,
      maxBpm: signal.context.maxBpm,
    );
    if (adjustment == null) {
      return null;
    }

    final harmonicPenalty = adjustment.clamped
        ? 0.6
        : (1.0 - (adjustment.multiplier - 1.0).abs() * 0.2).clamp(0.6, 1.0);
    final confidence =
        ((bestMagnitude / averageMagnitude) * harmonicPenalty).clamp(0.0, 1.0);

    return BpmReading(
      algorithmId: id,
      algorithmName: label,
      bpm: adjustment.bpm,
      confidence: confidence,
      timestamp: DateTime.now().toUtc(),
      metadata: {
        'fftSize': fftSize,
        'sampleRate': effectiveSampleRate,
        'peakMagnitude': bestMagnitude,
        'avgMagnitude': averageMagnitude,
        'rangeMultiplier': adjustment.multiplier,
        'rangeClamped': adjustment.clamped,
      },
    );
  }
}

int _boundedPowerOfTwo(int sampleCount, int minSize) {
  final desired = max(minSize, sampleCount);
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
