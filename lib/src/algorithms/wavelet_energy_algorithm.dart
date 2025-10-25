import 'dart:math';

import 'package:bpm/src/algorithms/bpm_detection_algorithm.dart';
import 'package:bpm/src/algorithms/detection_context.dart';
import 'package:bpm/src/dsp/signal_utils.dart';
import 'package:bpm/src/models/bpm_models.dart';

class WaveletEnergyAlgorithm extends BpmDetectionAlgorithm {
  WaveletEnergyAlgorithm({
    this.levels = 4,
  });

  final int levels;

  @override
  String get id => 'wavelet_energy';

  @override
  String get label => 'Wavelet Energy';

  @override
  Duration get preferredWindow => const Duration(seconds: 14);

  @override
  Future<BpmReading?> analyze({
    required List<AudioFrame> window,
    required DetectionContext context,
  }) async {
    if (window.isEmpty) return null;

    final samples = SignalUtils.normalize(
      window.expand((frame) => frame.samples).toList(),
    );

    if (samples.length < context.sampleRate ~/ 2) {
      return null;
    }

    final pow2 = SignalUtils.previousPowerOfTwo(samples.length);
    if (pow2 < 32) {
      return null;
    }
    final trimmed = samples.sublist(0, pow2);

    final envelope = _buildWaveletEnvelope(trimmed, levels);
    if (envelope.isEmpty || envelope.every((value) => value == 0)) {
      return null;
    }

    final normalized = SignalUtils.normalize(_removeDc(envelope));

    final minLag =
        (context.sampleRate * 60 / context.maxBpm).floor().clamp(1, normalized.length - 1);
    final maxLag =
        (context.sampleRate * 60 / context.minBpm).floor().clamp(minLag + 1, normalized.length - 1);
    if (minLag >= maxLag) {
      return null;
    }

    final lag = SignalUtils.dominantLag(
      normalized,
      minLag: minLag,
      maxLag: maxLag,
    );
    if (lag == null) {
      return null;
    }

    final bpm = 60 * context.sampleRate / lag;
    if (bpm < context.minBpm || bpm > context.maxBpm) {
      return null;
    }

    final confidence = SignalUtils.autocorrelation(normalized, lag).clamp(0.0, 1.0);

    return BpmReading(
      algorithmId: id,
      algorithmName: label,
      bpm: bpm,
      confidence: confidence,
      timestamp: DateTime.now().toUtc(),
      metadata: {
        'lag': lag,
      },
    );
  }

  List<double> _buildWaveletEnvelope(List<double> samples, int maxLevels) {
    final aggregated = List<double>.filled(samples.length, 0.0);
    var current = List<double>.from(samples);
    final sqrt2 = sqrt2Constant;

    for (var level = 0; level < maxLevels; level++) {
      if (current.length < 2) {
        break;
      }

      final approx = <double>[];
      final details = <double>[];

      for (var i = 0; i < current.length - 1; i += 2) {
        final a = current[i];
        final b = current[i + 1];
        approx.add((a + b) / sqrt2);
        details.add((a - b) / sqrt2);
      }

      if (details.isEmpty) {
        break;
      }

      final energy = details.map((value) => value * value).toList();
      final smoothWindow = max(2, energy.length ~/ 32);
      final smoothed = _movingAverage(energy, smoothWindow);
      final upsampled = _upsampleToLength(smoothed, aggregated.length);

      for (var i = 0; i < aggregated.length; i++) {
        aggregated[i] += upsampled[i];
      }

      current = approx;
    }
    return aggregated;
  }
}

const sqrt2Constant = 1.4142135623730951;

List<double> _movingAverage(List<double> data, int windowSize) {
  if (data.isEmpty || windowSize <= 1) {
    return List<double>.from(data);
  }
  final window = min(windowSize, data.length);
  final result = List<double>.filled(data.length, 0);
  var sum = 0.0;

  for (var i = 0; i < data.length; i++) {
    sum += data[i];
    if (i >= window) {
      sum -= data[i - window];
    }
    final currentWindow = min(i + 1, window);
    result[i] = sum / currentWindow;
  }
  return result;
}

List<double> _removeDc(List<double> data) {
  if (data.isEmpty) return data;
  final mean = data.reduce((a, b) => a + b) / data.length;
  return data.map((value) => value - mean).toList();
}

List<double> _upsampleToLength(List<double> data, int targetLength) {
  if (targetLength <= 0) {
    return const [];
  }
  if (data.isEmpty) {
    return List<double>.filled(targetLength, 0);
  }
  if (data.length == targetLength) {
    return List<double>.from(data);
  }

  final result = List<double>.filled(targetLength, 0);
  final scale = data.length / targetLength;
  for (var i = 0; i < targetLength; i++) {
    final sourceIndex = (i * scale).floor().clamp(0, data.length - 1);
    result[i] = data[sourceIndex];
  }
  return result;
}
