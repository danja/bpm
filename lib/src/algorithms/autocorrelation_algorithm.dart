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

    final normalized = _normalize(flattened);
    final minLag =
        (context.sampleRate * 60 / context.maxBpm).floor().clamp(1, 10000);
    final maxLag =
        (context.sampleRate * 60 / context.minBpm).floor().clamp(minLag + 1, 60000);

    // Use stride to reduce computation on mobile devices
    final lagRange = maxLag - minLag;
    final stride = lagRange > 10000 ? max(2, lagRange ~/ 5000) : 1;

    double bestScore = double.negativeInfinity;
    int bestLag = minLag;

    for (var lag = minLag; lag <= maxLag; lag += stride) {
      final score = _autocorrelation(normalized, lag);
      if (score > bestScore) {
        bestScore = score;
        bestLag = lag;
      }
    }

    if (bestScore <= 0) return null;

    final bpm = 60 * context.sampleRate / bestLag;
    final confidence = bestScore.clamp(0.0, 1.0);

    return BpmReading(
      algorithmId: id,
      algorithmName: label,
      bpm: bpm,
      confidence: confidence,
      timestamp: DateTime.now().toUtc(),
      metadata: {'lag': bestLag},
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
