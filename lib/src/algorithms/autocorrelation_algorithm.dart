import 'dart:math';

import 'package:bpm/src/algorithms/bpm_detection_algorithm.dart';
import 'package:bpm/src/algorithms/detection_context.dart';
import 'package:bpm/src/dsp/signal_utils.dart';
import 'package:bpm/src/models/bpm_models.dart';

class AutocorrelationAlgorithm extends BpmDetectionAlgorithm {
  AutocorrelationAlgorithm({
    this.maxAnalysisSeconds = 4,
    this.targetSampleRate = 8000,
    this.minConfidenceThreshold = 0.25,
  });

  final int maxAnalysisSeconds;
  final int targetSampleRate;
  final double minConfidenceThreshold;

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
    if (flattened.length < context.sampleRate ~/ 2) {
      return null;
    }

    final maxSamples =
        min(flattened.length, context.sampleRate * maxAnalysisSeconds);
    var samples = flattened.sublist(0, maxSamples);

    final decimationFactor =
        max(1, (context.sampleRate / targetSampleRate).ceil());
    final effectiveSampleRate =
        max(1, (context.sampleRate / decimationFactor).round());

    if (decimationFactor > 1) {
      samples = SignalUtils.downsample(samples, decimationFactor);
    }

    if (samples.length < effectiveSampleRate) {
      return null;
    }

    samples = SignalUtils.normalize(SignalUtils.removeMean(samples));
    if (samples.every((value) => value == 0)) {
      return null;
    }

    final theoreticalMinLag =
        (effectiveSampleRate * 60 / context.maxBpm).floor();
    final theoreticalMaxLag =
        (effectiveSampleRate * 60 / context.minBpm).ceil();

    final minLag = max(1, theoreticalMinLag);
    final maxLag = min(samples.length - 1, theoreticalMaxLag);
    if (maxLag - minLag < 3) {
      return null;
    }

    final coarseStride = max(1, (maxLag - minLag) ~/ 100);
    var bestScore = double.negativeInfinity;
    var bestLag = minLag;
    var evaluations = 0;
    const maxEvaluations = 400;

    for (var lag = minLag; lag <= maxLag; lag += coarseStride) {
      final score = SignalUtils.autocorrelation(samples, lag);
      evaluations++;
      if (score > bestScore) {
        bestScore = score;
        bestLag = lag;
      }
      if (evaluations >= maxEvaluations) {
        break;
      }
    }

    final refineStart = max(minLag, bestLag - coarseStride * 2);
    final refineEnd = min(maxLag, bestLag + coarseStride * 2);
    for (var lag = refineStart; lag <= refineEnd; lag++) {
      final score = SignalUtils.autocorrelation(samples, lag);
      evaluations++;
      if (score > bestScore) {
        bestScore = score;
        bestLag = lag;
      }
      if (evaluations >= maxEvaluations) {
        break;
      }
    }

    final confidence = bestScore.clamp(0.0, 1.0);
    if (confidence < minConfidenceThreshold) {
      return null;
    }

    final bpm = 60 * effectiveSampleRate / bestLag;

    return BpmReading(
      algorithmId: id,
      algorithmName: label,
      bpm: bpm,
      confidence: confidence,
      timestamp: DateTime.now().toUtc(),
      metadata: {
        'lag': bestLag,
        'evaluations': evaluations,
        'coarseStride': coarseStride,
        'decimation': decimationFactor,
        'analysisSeconds': samples.length / effectiveSampleRate,
      },
    );
  }
}
