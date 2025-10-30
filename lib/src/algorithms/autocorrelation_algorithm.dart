import 'dart:math' as math;

import 'package:bpm/src/algorithms/algorithm_utils.dart';
import 'package:bpm/src/algorithms/bpm_detection_algorithm.dart';
import 'package:bpm/src/dsp/preprocessing_pipeline.dart';
import 'package:bpm/src/dsp/signal_utils.dart';
import 'package:bpm/src/models/bpm_models.dart';

/// Autocorrelation-based BPM detection using periodicity analysis.
///
/// Now uses pre-downsampled 8kHz signal from preprocessing pipeline,
/// improving performance by eliminating redundant downsampling.
class AutocorrelationAlgorithm extends BpmDetectionAlgorithm {
  AutocorrelationAlgorithm({
    this.maxAnalysisSeconds = 4,
  });

  final int maxAnalysisSeconds;

  @override
  String get id => 'autocorrelation';

  @override
  String get label => 'Autocorrelation';

  @override
  Duration get preferredWindow => const Duration(seconds: 12);

  @override
  Future<BpmReading?> analyze({
    required PreprocessedSignal signal,
  }) async {
    // Use pre-downsampled 8kHz signal from preprocessing
    var samples = List<double>.from(signal.samples8kHz);
    const effectiveSampleRate = 8000; // Target sample rate from preprocessing

    if (samples.isEmpty || samples.length < effectiveSampleRate) {
      return null;
    }

    // Limit analysis duration
    final maxSamples =
        math.min(samples.length, effectiveSampleRate * maxAnalysisSeconds);
    if (maxSamples < samples.length) {
      samples = samples.sublist(0, maxSamples);
    }

    // Normalize (preprocessing already removed DC and normalized, but ensure clean signal)
    samples = SignalUtils.normalize(SignalUtils.removeMean(samples));
    if (samples.every((value) => value == 0)) {
      return null;
    }

    // Calculate lag range based on BPM bounds
    final theoreticalMinLag =
        (effectiveSampleRate * 60 / signal.context.maxBpm).floor();
    final theoreticalMaxLag =
        (effectiveSampleRate * 60 / signal.context.minBpm).ceil();

    final minLag = math.max(1, theoreticalMinLag);
    final maxLag = math.min(samples.length - 1, theoreticalMaxLag);
    if (maxLag - minLag < 3) {
      return null;
    }

    final coarseStride = math.max(1, (maxLag - minLag) ~/ 100);
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

    final refineStart = math.max(minLag, bestLag - coarseStride * 2);
    final refineEnd = math.min(maxLag, bestLag + coarseStride * 2);
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

    final rawBpm = 60 * effectiveSampleRate / bestLag;
    final adjustment = AlgorithmUtils.coerceToRange(
      rawBpm,
      minBpm: signal.context.minBpm,
      maxBpm: signal.context.maxBpm,
    );
    if (adjustment == null) {
      return null;
    }

    final confidence = (bestScore.clamp(0.0, 1.0) *
            _harmonicPenalty(adjustment.multiplier, adjustment.clamped))
        .clamp(0.0, 1.0);

    return BpmReading(
      algorithmId: id,
      algorithmName: label,
      bpm: adjustment.bpm,
      confidence: confidence,
      timestamp: DateTime.now().toUtc(),
      metadata: {
        'lag': bestLag,
        'evaluations': evaluations,
        'coarseStride': coarseStride,
        'sampleRate': effectiveSampleRate,
        'analysisSeconds': samples.length / effectiveSampleRate,
        'rangeMultiplier': adjustment.multiplier,
        'rangeClamped': adjustment.clamped,
      },
    );
  }

  double _harmonicPenalty(double multiplier, bool clamped) {
    if (clamped) {
      return 0.6;
    }
    final deviation = (multiplier - 1.0).abs();
    if (deviation < 0.05) {
      return 1.0;
    }
    return (1.0 - math.min(0.5, deviation * 0.4)).clamp(0.5, 1.0);
  }
}
