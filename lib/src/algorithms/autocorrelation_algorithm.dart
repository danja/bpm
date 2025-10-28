import 'dart:math';

import 'package:bpm/src/algorithms/bpm_detection_algorithm.dart';
import 'package:bpm/src/algorithms/detection_context.dart';
import 'package:bpm/src/models/bpm_models.dart';

class AutocorrelationAlgorithm extends BpmDetectionAlgorithm {
  @override
  String get id => 'autocorrelation';

  @override
  String get label => 'Autocorrelation';

  @override
  Duration get preferredWindow => const Duration(seconds: 12);

  @override
  Future<BpmReading?> analyze({
    required List<AudioFrame> window,
    required DetectionContext context,
  }) async {
    if (window.isEmpty) return null;
    final flattened = window.expand((frame) => frame.samples).toList();
    if (flattened.length < context.sampleRate) return null;

    // Use only first 3 seconds for speed (still plenty for BPM detection)
    final maxSamples = context.sampleRate * 3;
    final samples = flattened.length > maxSamples
        ? flattened.sublist(0, maxSamples)
        : flattened;

    final normalized = _normalize(samples);
    final minLag =
        (context.sampleRate * 60 / context.maxBpm).floor().clamp(1, 10000);
    final maxLag =
        (context.sampleRate * 60 / context.minBpm).floor().clamp(minLag + 1, 15000);

    // Very aggressive stride for mobile - only check ~50 total points
    final lagRange = maxLag - minLag;
    final stride = max(lagRange ~/ 50, 100);

    double bestScore = double.negativeInfinity;
    int bestLag = minLag;

    // Hard limit iterations to 50 max (was 200)
    final maxIterations = 50;
    var iterations = 0;

    for (var lag = minLag; lag <= maxLag && iterations < maxIterations; lag += stride) {
      final score = _autocorrelation(normalized, lag);
      if (score > bestScore) {
        bestScore = score;
        bestLag = lag;
      }
      iterations++;
    }

    if (bestScore <= 0.1) return null; // Higher threshold

    final bpm = 60 * context.sampleRate / bestLag;
    final confidence = (bestScore * 1.5).clamp(0.0, 1.0); // Boost confidence

    return BpmReading(
      algorithmId: id,
      algorithmName: label,
      bpm: bpm,
      confidence: confidence,
      timestamp: DateTime.now().toUtc(),
      metadata: {'lag': bestLag, 'iterations': iterations},
    );
  }

  double _autocorrelation(List<double> samples, int lag) {
    var sum = 0.0;
    for (var i = 0; i < samples.length - lag; i++) {
      sum += samples[i] * samples[i + lag];
    }
    return sum / (samples.length - lag);
  }

  List<double> _normalize(List<double> samples) {
    final maxValue = samples.map((e) => e.abs()).reduce(max);
    if (maxValue == 0) {
      return List.filled(samples.length, 0);
    }
    return samples.map((value) => value / maxValue).toList();
  }
}
