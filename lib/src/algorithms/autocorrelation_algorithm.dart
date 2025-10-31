import 'dart:math' as math;

import 'package:bpm/src/algorithms/algorithm_utils.dart';
import 'package:bpm/src/algorithms/bpm_detection_algorithm.dart';
import 'package:bpm/src/algorithms/interval_histogram.dart';
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
    final lagScores = <int, double>{};

    for (var lag = minLag; lag <= maxLag; lag += coarseStride) {
      final score = SignalUtils.autocorrelation(samples, lag);
      evaluations++;
      lagScores[lag] = math.max(lagScores[lag] ?? double.negativeInfinity, score);
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
      lagScores[lag] = math.max(lagScores[lag] ?? double.negativeInfinity, score);
      if (score > bestScore) {
        bestScore = score;
        bestLag = lag;
      }
      if (evaluations >= maxEvaluations) {
        break;
      }
    }

    final rawBpm = 60 * effectiveSampleRate / bestLag;

    final histogram = IntervalHistogram(
      context: signal.context,
      binSize: 0.02,
    );

    lagScores.forEach((lag, score) {
      if (lag <= 0 || score <= 0) return;
      final interval = lag / effectiveSampleRate;
      final baseWeight = interval * interval * score;
      histogram.accumulate(
        interval: interval,
        weight: baseWeight,
        supporters: 1,
        source: 'lag',
      );
      histogram.accumulate(
        interval: interval * 2,
        weight: baseWeight * 0.2,
        supporters: 0,
        source: 'lag_double',
      );
      histogram.accumulate(
        interval: interval / 2,
        weight: baseWeight * 0.08,
        supporters: 0,
        source: 'half_lag',
      );
    });

    histogram.applyLengthBoost();
    histogram.suppressShorterHarmonics(minShare: 0.2, suppressionFactor: 0.1);

    final histogramSelection = histogram.select();
    final candidates = histogram.toTempoCandidates();
    if (bestLag > 0 && bestScore > 0 && rawBpm.isFinite) {
      candidates.add(
        TempoCandidate(
          bpm: rawBpm,
          weight: bestScore,
          source: 'best_lag',
        ),
      );
    }

    final refinement = candidates.isEmpty
        ? null
        : AlgorithmUtils.refineFromCandidates(
            candidates: candidates,
            minBpm: signal.context.minBpm,
            maxBpm: signal.context.maxBpm,
            clusterToleranceBpm: 1.25,
          );

    BpmRangeResult? fallbackAdjustment;
    double? histogramBpm;
    if (histogramSelection != null &&
        histogramSelection.normalizedInterval > 0) {
      histogramBpm = 60.0 / histogramSelection.normalizedInterval;
    }

    if (refinement == null && histogramBpm == null) {
      fallbackAdjustment = AlgorithmUtils.coerceToRange(
        rawBpm,
        minBpm: signal.context.minBpm,
        maxBpm: signal.context.maxBpm,
      );
      if (fallbackAdjustment == null) {
        return null;
      }
    }

    final bpm = refinement?.bpm ??
        histogramBpm ??
        fallbackAdjustment!.bpm;

    final penalty = refinement != null
        ? refinement.consistency
        : histogramSelection != null
            ? (histogramSelection.score /
                    (histogramSelection.totalScore + 1e-6))
                .clamp(0.35, 1.0)
            : _harmonicPenalty(
                fallbackAdjustment!.multiplier,
                fallbackAdjustment.clamped,
              );

    final confidence =
        (bestScore.clamp(0.0, 1.0) * penalty).clamp(0.0, 1.0);

    final metadata = <String, Object?>{
      'lag': bestLag,
      'evaluations': evaluations,
      'coarseStride': coarseStride,
      'sampleRate': effectiveSampleRate,
      'analysisSeconds': samples.length / effectiveSampleRate,
      'rawBpm': rawBpm,
      'clusterConsistency': penalty,
      'lagScores': {
        for (final entry in lagScores.entries)
          entry.key.toString(): entry.value,
      },
    };

    if (refinement != null) {
      metadata.addAll(refinement.metadata);
      metadata['rangeMultiplier'] = refinement.averageMultiplier;
      metadata['rangeClamped'] = refinement.clampedCount > 0;
    } else if (histogramSelection != null) {
      metadata['clusterWeight'] = histogramSelection.score;
      metadata['clusterStd'] = 0.0;
      metadata['clusterCount'] = histogramSelection.supporters;
      metadata['clusterConsistency'] =
          histogramSelection.score / (histogramSelection.totalScore + 1e-6);
      metadata['maxMultiplierDeviation'] =
          (histogramSelection.multiplier - 1.0).abs();
      metadata['clampedContributors'] = 0;
      metadata['sources'] = histogramSelection.sources;
      metadata['rangeMultiplier'] = histogramSelection.multiplier;
      metadata['rangeClamped'] =
          histogramSelection.multiplier.abs() > 1.05;
      metadata['candidateScores'] = histogramSelection.scoreMap;
      metadata['suppressedBuckets'] = histogramSelection.suppressedBpms;
    } else {
      final normalizedLag = lagScores.entries
          .where((entry) => entry.value == lagScores.values.reduce(math.max))
          .map((entry) => entry.key)
          .first;
      metadata['clusterWeight'] = lagScores[normalizedLag] ?? 0.0;
      metadata['clusterStd'] = 0.0;
      metadata['clusterCount'] = 1;
      metadata['maxMultiplierDeviation'] =
          (fallbackAdjustment!.multiplier - 1.0).abs();
      metadata['clampedContributors'] = fallbackAdjustment.clamped ? 1 : 0;
      metadata['sources'] = const <String>['fallback'];
      metadata['rangeMultiplier'] = fallbackAdjustment.multiplier;
      metadata['rangeClamped'] = fallbackAdjustment.clamped;
    }

    if (histogramSelection != null) {
      metadata['histogramTotalScore'] = histogramSelection.totalScore;
      metadata['histogramSuppressed'] = histogramSelection.suppressedBpms;
      metadata['candidateScores'] ??= histogramSelection.scoreMap;
      metadata['suppressedBuckets'] ??= histogramSelection.suppressedBpms;
    }

    metadata['clusterConsistency'] ??= penalty;

    return BpmReading(
      algorithmId: id,
      algorithmName: label,
      bpm: bpm,
      confidence: confidence,
      timestamp: DateTime.now().toUtc(),
      metadata: metadata,
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
