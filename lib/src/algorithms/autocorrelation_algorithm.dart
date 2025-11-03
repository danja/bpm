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
    this.maxAnalysisSeconds = 10,
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
    // Use onset envelope (10ms hop) for periodicity to emphasise rhythmic energy
    var samples = signal.onsetEnvelope.map((value) => value.toDouble()).toList();
    final effectiveSampleRate =
        (1.0 / signal.onsetTimeScale).round(); // ~100 Hz feature rate

    double? plpAnchorBpm;
    if (signal.dominantTempoCurve.isNotEmpty) {
      final anchorCandidates = <double>[];
      for (final value in signal.dominantTempoCurve) {
        if (value > 0) {
          anchorCandidates.add(value.toDouble());
        }
      }
      if (anchorCandidates.isNotEmpty) {
        anchorCandidates.sort();
        plpAnchorBpm = anchorCandidates[anchorCandidates.length ~/ 2];
      }
    }

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

    final coarseStride = math.max(1, (maxLag - minLag) ~/ 200);
    var bestScore = double.negativeInfinity;
    var bestLag = minLag;
    var evaluations = 0;
    const maxEvaluations = 800;
    final lagScores = <int, double>{};

    for (var lag = minLag; lag <= maxLag; lag += coarseStride) {
      final rawScore = SignalUtils.autocorrelation(samples, lag);
      final score = rawScore.abs();
      evaluations++;
      lagScores[lag] =
          math.max(lagScores[lag] ?? double.negativeInfinity, score);
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
      final rawScore = SignalUtils.autocorrelation(samples, lag);
      final score = rawScore.abs();
      evaluations++;
      lagScores[lag] =
          math.max(lagScores[lag] ?? double.negativeInfinity, score);
      if (score > bestScore) {
        bestScore = score;
        bestLag = lag;
      }
      if (evaluations >= maxEvaluations) {
        break;
      }
    }

    final rawBpm = 60 * effectiveSampleRate / bestLag;

    // ENHANCEMENT: Subharmonic suppression - prefer lags without strong subharmonics
    // True fundamental has peaks at L, 2L, 3L but harmonics (like 2L) don't have peaks at L/2
    final fundamentalScores = <int, double>{};
    for (final entry in lagScores.entries) {
      final lag = entry.key;
      final score = entry.value;

      var fundamentalScore = score;

      // Penalize if subharmonic (L/2) has comparable or stronger peak
      final halfLag = lag ~/ 2;
      if (halfLag >= minLag && lagScores.containsKey(halfLag)) {
        final halfScore = lagScores[halfLag]!;
        if (halfScore > score * 0.5) {
          // Strong subharmonic suggests this lag is a harmonic - penalize heavily
          fundamentalScore *= 0.1;
        } else if (halfScore > score * 0.7) {
          fundamentalScore *= 0.3;
        }
      }

      // Penalize if L/3 has strong peak (L might be 3× harmonic)
      final thirdLag = lag ~/ 3;
      if (thirdLag >= minLag && lagScores.containsKey(thirdLag)) {
        final thirdScore = lagScores[thirdLag]!;
        if (thirdScore > score * 0.4) {
          fundamentalScore *= 0.2;
        } else if (thirdScore > score * 0.6) {
          fundamentalScore *= 0.5;
        }
      }

      // Bonus if 2L has strong peak (confirms L is fundamental)
      final doubleLag = lag * 2;
      if (doubleLag <= maxLag && lagScores.containsKey(doubleLag)) {
        final doubleScore = lagScores[doubleLag]!;
        if (doubleScore > score * 0.2) {
          fundamentalScore *= 1.5;
        }
      }

      // Bonus if 3L has peak (further confirms fundamental)
      final tripleLag = lag * 3;
      if (tripleLag <= maxLag && lagScores.containsKey(tripleLag)) {
        final tripleScore = lagScores[tripleLag]!;
        if (tripleScore > score * 0.15) {
          fundamentalScore *= 1.4;
        }
      }

      fundamentalScores[lag] = fundamentalScore;
    }

    // Find best lag using fundamental-adjusted scores
    var primaryLag = bestLag;
    var primaryScore = bestScore;
    var bestFundamentalScore = fundamentalScores[bestLag] ?? bestScore;

    for (final entry in fundamentalScores.entries) {
      if (entry.value > bestFundamentalScore) {
        bestFundamentalScore = entry.value;
        primaryLag = entry.key;
        primaryScore = lagScores[entry.key] ?? entry.value;
      }
    }

    final histogram = IntervalHistogram(
      context: signal.context,
      binSize: 0.02,
    );

    // Only include lags with significant scores (top 50% or score > 0.3 * bestScore)
    final scoreThreshold = math.max(bestScore * 0.3, 0.01);
    final significantLags = lagScores.entries
        .where((entry) => entry.value >= scoreThreshold)
        .toList();

    for (final entry in significantLags) {
      final lag = entry.key;
      final score = entry.value;
      if (lag <= 0 || score <= 0) continue;

      final interval = lag / effectiveSampleRate;
      // Weight more heavily by score - emphasize strong peaks
      final rawWeight = score * score;
      var directWeight = rawWeight;
      var harmonicExpansionWeight = rawWeight;
      final isPrimary = lag == primaryLag;

      // ENHANCEMENT: Massively boost primaryLag, suppress its harmonics
      if (isPrimary) {
        // Give 100× weight to the identified fundamental's DIRECT interval only
        directWeight *= 100.0;
        // But don't boost its harmonic expansions at all
        harmonicExpansionWeight *= 0.01;
      } else {
        // Check if this lag is a harmonic of primaryLag - add more ratios
        final ratio = lag.toDouble() / primaryLag.toDouble();
        if ((ratio - 2.0).abs() < 0.15 ||  // 2× harmonic
            (ratio - 3.0).abs() < 0.15 ||  // 3× harmonic
            (ratio - 1.5).abs() < 0.15 ||  // 3/2 harmonic
            (ratio - 4.0/3.0).abs() < 0.15 ||  // 4/3 harmonic
            (ratio - 3.0/4.0).abs() < 0.15 ||  // 3/4 subharmonic
            (ratio - 5.0/4.0).abs() < 0.15 ||  // 5/4 harmonic
            (ratio - 4.0/5.0).abs() < 0.15 ||  // 4/5 subharmonic
            (ratio - 0.5).abs() < 0.15) {  // 1/2 subharmonic
          // This is a harmonic of the primary - suppress it very heavily
          directWeight *= 0.01;
          harmonicExpansionWeight *= 0.001;
        }
      }

      // Only add the primary interval - don't pollute with harmonics
      histogram.accumulate(
        interval: interval,
        weight: directWeight,
        supporters: 1,
        source: 'lag',
      );

      for (final adjustment in _lagHarmonicAdjustments) {
        final scaledInterval = interval * adjustment.scale;
        if (scaledInterval <= 0) {
          continue;
        }
        final scaledBpm = 60.0 / scaledInterval;
        if (scaledBpm.isNaN ||
            scaledBpm.isInfinite ||
            scaledBpm < signal.context.minBpm * 0.8 ||
            scaledBpm > signal.context.maxBpm * 1.25) {
          continue;
        }
        histogram.accumulate(
          interval: scaledInterval,
          weight: harmonicExpansionWeight * adjustment.weight,
          supporters: 0,
          source: adjustment.label,
        );
      }

      // Only add half/double for very strong peaks (>0.7 * best)
      if (score > bestScore * 0.7 && !isPrimary) {
        histogram.accumulate(
          interval: interval * 2,
          weight: harmonicExpansionWeight * 0.02,
          supporters: 0,
          source: 'lag_double',
        );
        histogram.accumulate(
          interval: interval / 2,
          weight: harmonicExpansionWeight * 0.015,
          supporters: 0,
          source: 'half_lag',
        );
      }
    }

    histogram.applyLengthBoost();
    histogram.suppressLongerHarmonics(
      minShare: 0.08,
      suppressionFactor: 0.35,
    );

    if (plpAnchorBpm != null && plpAnchorBpm > 0) {
      final anchorInterval = 60.0 / plpAnchorBpm;
      final anchorBaseWeight = (bestScore * 0.08).clamp(0.00001, 0.02);
      histogram.accumulate(
        interval: anchorInterval,
        weight: anchorBaseWeight,
        supporters: 0,
        source: 'plp_anchor',
      );
      const expansionRatios = [6 / 5, 5 / 4, 4 / 3];
      for (final ratio in expansionRatios) {
        final scaledInterval = anchorInterval / ratio;
        if (scaledInterval <= 0) {
          continue;
        }
        final scaledBpm = 60.0 / scaledInterval;
        if (scaledBpm < signal.context.minBpm * 0.8 ||
            scaledBpm > signal.context.maxBpm * 1.2) {
          continue;
        }
        histogram.accumulate(
          interval: scaledInterval,
          weight: anchorBaseWeight * 0.6,
          supporters: 0,
          source: 'plp_anchor_ratio_${ratio.toStringAsFixed(2)}',
        );
      }
    }

    final histogramSelection = histogram.select();
    final candidates = histogram.toTempoCandidates();

    // ENHANCEMENT: Add the PRIMARY lag (fundamental-corrected) with very strong weight
    if (primaryLag > 0 && primaryScore > 0) {
      final primaryBpm = 60 * effectiveSampleRate / primaryLag;
      // Weight the primary lag MASSIVELY (20×) - it should overwhelmingly dominate
      // If HPS found a different fundamental, weight it even higher (30×)
      final hpsCorrected = primaryLag != bestLag;
      final baseWeight = hpsCorrected ? 30.0 : 20.0;
      final primaryLagWeight = primaryScore * baseWeight;
      candidates.add(
        TempoCandidate(
          bpm: primaryBpm,
          weight: primaryLagWeight,
          source: hpsCorrected ? 'hps_fundamental' : 'best_lag',
        ),
      );
      // Add harmonic expansions with reduced weight
      for (final expansion in _bestLagExpansions) {
        final candidateBpm = primaryBpm * expansion.multiplier;
        if (!candidateBpm.isFinite) {
          continue;
        }
        if (candidateBpm < signal.context.minBpm * 0.8 ||
            candidateBpm > signal.context.maxBpm * 1.25) {
          continue;
        }
        candidates.add(
          TempoCandidate(
            bpm: candidateBpm,
            weight: primaryLagWeight * expansion.weightScale * 0.5,
            source: expansion.label,
            allowHarmonics: false,
          ),
        );
      }
      final doubleCandidate = primaryBpm * 2;
      if (doubleCandidate.isFinite &&
          doubleCandidate >= signal.context.minBpm * 0.85 &&
          doubleCandidate <= signal.context.maxBpm * 1.2) {
        candidates.add(
          TempoCandidate(
            bpm: doubleCandidate,
            weight: primaryLagWeight * 0.15,
            source: 'hps_double',
            allowHarmonics: false,
          ),
        );
      }
      final tripleCandidate = primaryBpm * 3;
      if (tripleCandidate.isFinite &&
          tripleCandidate >= signal.context.minBpm * 0.85 &&
          tripleCandidate <= signal.context.maxBpm * 1.2) {
        candidates.add(
          TempoCandidate(
            bpm: tripleCandidate,
            weight: primaryLagWeight * 0.5,
            source: 'hps_triple',
            allowHarmonics: false,
          ),
        );
      }
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

    var bpm = refinement?.bpm ??
        histogramBpm ??
        fallbackAdjustment!.bpm;

    double? histogramPreferenceMultiplier;
    var histogramSecondaryApplied = false;
    if (histogramSelection != null) {
      final preferredBpm = _preferLongerHistogramCandidate(
        currentBpm: bpm,
        histogram: histogramSelection,
        anchorBpm: plpAnchorBpm,
      );
      if (preferredBpm != null &&
          preferredBpm > 0 &&
          (preferredBpm - bpm).abs() > 0.25) {
        histogramPreferenceMultiplier = preferredBpm / (bpm == 0 ? 1 : bpm);
        bpm = preferredBpm;
      }

      final secondaryCandidate = _selectHistogramCandidateByRatio(
        histogram: histogramSelection,
        baseBpm: bpm,
        minRatio: 0.75,
        maxRatio: 0.9,
        minRelative: 0.45,
      );
      if (secondaryCandidate != null &&
          (secondaryCandidate - bpm).abs() > 0.3 &&
          (plpAnchorBpm == null ||
              secondaryCandidate >= plpAnchorBpm * 0.85)) {
        final multiplier = secondaryCandidate / (bpm == 0 ? 1 : bpm);
        histogramPreferenceMultiplier =
            (histogramPreferenceMultiplier ?? 1.0) * multiplier.abs();
        bpm = secondaryCandidate;
        if (histogramPreferenceMultiplier < 0) {
          histogramPreferenceMultiplier = histogramPreferenceMultiplier.abs();
        }
        histogramSecondaryApplied = true;
      }

      final fasterCandidate = _selectHistogramCandidateByRatio(
        histogram: histogramSelection,
        baseBpm: bpm,
        minRatio: 1.05,
        maxRatio: 1.28,
        minRelative: 0.35,
      );
      if (fasterCandidate != null &&
          (fasterCandidate - bpm).abs() > 0.3 &&
          (plpAnchorBpm == null || fasterCandidate <= plpAnchorBpm * 1.4)) {
        final multiplier = fasterCandidate / (bpm == 0 ? 1 : bpm);
        histogramPreferenceMultiplier =
            (histogramPreferenceMultiplier ?? 1.0) * multiplier.abs();
        bpm = fasterCandidate;
        histogramSecondaryApplied = true;
      }

      if (plpAnchorBpm != null && plpAnchorBpm > 0) {
        const expansionRatios = [6 / 5, 5 / 4, 4 / 3];
        double bestScore = 0;
        double? bestAnchorCandidate;
        for (final ratio in expansionRatios) {
          final candidateBpm = (plpAnchorBpm * ratio)
              .clamp(signal.context.minBpm, signal.context.maxBpm);
          final candidateScore =
              _scoreForHistogramBpm(histogramSelection, candidateBpm) ?? 0.0;
          if (candidateScore > bestScore + 1e-6 &&
              (candidateBpm - bpm).abs() > 0.3) {
            bestScore = candidateScore;
            bestAnchorCandidate = candidateBpm;
          }
        }
        if (bestAnchorCandidate != null &&
            (bestAnchorCandidate - bpm).abs() > 0.3) {
          final multiplier = bestAnchorCandidate / (bpm == 0 ? 1 : bpm);
          histogramPreferenceMultiplier =
              (histogramPreferenceMultiplier ?? 1.0) * multiplier.abs();
          bpm = bestAnchorCandidate;
          histogramSecondaryApplied = true;
        }
      }
    }

    var rangeMultiplier = 1.0;
    var rangeClamped = false;
    if (refinement != null) {
      rangeMultiplier = refinement.averageMultiplier;
      rangeClamped = refinement.clampedCount > 0;
    } else if (fallbackAdjustment != null) {
      rangeMultiplier = fallbackAdjustment.multiplier;
      rangeClamped = fallbackAdjustment.clamped;
    }

    final coerced = AlgorithmUtils.coerceToRange(
      bpm,
      minBpm: signal.context.minBpm,
      maxBpm: signal.context.maxBpm,
    );
    if (coerced != null) {
      if ((coerced.multiplier - 1.0).abs() > 0.05 || coerced.clamped) {
        bpm = coerced.bpm;
      }
      rangeMultiplier *= coerced.multiplier;
      rangeClamped = rangeClamped || coerced.clamped;
    }

    if (histogramPreferenceMultiplier != null) {
      rangeMultiplier *= histogramPreferenceMultiplier.abs();
    }

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

    final totalLagEnergy = lagScores.values.fold<double>(
      0,
      (sum, value) => sum + math.max(0.0, value),
    );
    final meanLagEnergy = lagScores.isEmpty
        ? 0.0
        : totalLagEnergy / lagScores.length;
    final contrast = meanLagEnergy > 0
        ? ((bestScore - meanLagEnergy) / (bestScore + 1e-6))
            .clamp(0.0, 1.0)
        : 1.0;
    final clusterStrength = histogramSelection != null
        ? (histogramSelection.score /
                (histogramSelection.totalScore + 1e-6))
            .clamp(0.0, 1.0)
        : 0.5;

    final confidence = (0.45 * penalty +
            0.35 * clusterStrength +
            0.2 * contrast)
        .clamp(0.0, 1.0);

    final metadata = <String, Object?>{
      'lag': primaryLag,
      'evaluations': evaluations,
      'coarseStride': coarseStride,
      'sampleRate': effectiveSampleRate,
      'analysisSeconds': samples.length / effectiveSampleRate,
      'rawBpm': rawBpm,
      'fundamentalCorrected': primaryLag != bestLag,
      'fundamentalCorrectedFrom': bestLag,
      'fundamentalScore': bestFundamentalScore,
      'clusterConsistency': penalty,
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
      metadata['histogramInterval'] = histogramSelection.normalizedInterval;
      metadata['histogramScoreMap'] = histogramSelection.scoreMap;
      if (histogramPreferenceMultiplier != null) {
        metadata['histogramPreferenceMultiplier'] =
            histogramPreferenceMultiplier;
        metadata['histogramPreferenceApplied'] = true;
      }
      if (histogramSecondaryApplied) {
        metadata['histogramSecondaryApplied'] = true;
      }
    }

    if (plpAnchorBpm != null && plpAnchorBpm > 0) {
      metadata['plpAnchorBpm'] = plpAnchorBpm;
    }

    metadata['rangeMultiplier'] = rangeMultiplier;
    metadata['rangeClamped'] = rangeClamped;
    if (coerced != null &&
        (coerced.multiplier - 1.0).abs() > 0.05 &&
        !metadata.containsKey('harmonicAdjusted')) {
      metadata['harmonicAdjusted'] = coerced.multiplier;
    }

    metadata['clusterConsistency'] ??= penalty;
    final topLagScores = lagScores.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    metadata['lagPeaks'] = topLagScores
        .take(6)
        .map((entry) => {'lag': entry.key, 'score': entry.value})
        .toList();

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

double? _preferLongerHistogramCandidate({
  required double currentBpm,
  required HistogramSelection histogram,
  double? anchorBpm,
}) {
  if (currentBpm <= 0) {
    return null;
  }
  final currentScore =
      _scoreForHistogramBpm(histogram, currentBpm) ?? histogram.score;
  var bestBpm = currentBpm;
  var bestScoreRatio = 0.0;
  var foundBetter = false;
  var bestIsPreferredBand = false;

  histogram.scoreMap.forEach((candidateBpm, score) {
    if (candidateBpm <= 0 || candidateBpm >= currentBpm) {
      return;
    }
    final ratio = candidateBpm / currentBpm;
    // Focus on musically common slow-downs (5/4, 4/3, 3/2, 6/5, etc.)
    if (ratio < 0.64 || ratio > 0.92) {
      return;
    }

    final isPreferredBand = ratio >= 0.7;
    final relative = currentScore == 0 ? 0.0 : score / currentScore;
    final absolute =
        histogram.totalScore == 0 ? 0.0 : score / histogram.totalScore;
    double anchorAffinity = 0.0;
    if (anchorBpm != null && anchorBpm > 0) {
      final tolerance = math.max(6.0, anchorBpm * 0.1);
      anchorAffinity =
          (1.0 - ((candidateBpm - anchorBpm).abs() / tolerance)).clamp(0.0, 1.0);
    }

    if (relative >= 0.35 || absolute >= 0.2 || anchorAffinity > 0.35) {
      final ratioAffinity =
          (1.0 - ((1.0 - ratio).abs() / 0.28)).clamp(0.0, 1.0);
      final scoreRatio =
          relative * 0.42 + absolute * 0.2 + ratioAffinity * 0.22 + anchorAffinity * 0.16;
      if (!foundBetter ||
          scoreRatio > bestScoreRatio + 1e-6 ||
          (isPreferredBand && !bestIsPreferredBand) ||
          ((scoreRatio - bestScoreRatio).abs() <= 1e-6 &&
              candidateBpm < bestBpm)) {
        foundBetter = true;
        bestBpm = candidateBpm;
        bestScoreRatio = scoreRatio;
        bestIsPreferredBand = isPreferredBand;
      }
    }
  });

  if (foundBetter && (bestBpm - currentBpm).abs() > 0.25) {
    return bestBpm;
  }
  return null;
}

double? _scoreForHistogramBpm(HistogramSelection histogram, double bpm) {
  double? closestScore;
  double bestDiff = double.infinity;
  histogram.scoreMap.forEach((candidateBpm, score) {
    final diff = (candidateBpm - bpm).abs();
    if (diff < bestDiff && diff <= 1.5) {
      closestScore = score;
      bestDiff = diff;
    }
  });
  return closestScore;
}

double? _selectHistogramCandidateByRatio({
  required HistogramSelection histogram,
  required double baseBpm,
  required double minRatio,
  required double maxRatio,
  required double minRelative,
}) {
  final baseScore =
      _scoreForHistogramBpm(histogram, baseBpm) ?? histogram.score;
  double? bestBpm;
  var bestScore = 0.0;

  histogram.scoreMap.forEach((candidateBpm, score) {
    if (candidateBpm <= 0) {
      return;
    }
    final ratio = candidateBpm / baseBpm;
    if (ratio < minRatio || ratio > maxRatio) {
      return;
    }
    final relative = baseScore == 0 ? 0.0 : score / baseScore;
    if (relative < minRelative) {
      return;
    }
    if (score <= baseScore * 0.8) {
      return;
    }
    if (score > bestScore + 1e-6 ||
        (score - bestScore).abs() <= 1e-6 &&
            (bestBpm == null || candidateBpm < bestBpm!)) {
      bestScore = score;
      bestBpm = candidateBpm;
    }
  });

  return bestBpm;
}

class _LagAdjustment {
  const _LagAdjustment({
    required this.scale,
    required this.weight,
    required this.label,
  });

  final double scale;
  final double weight;
  final String label;
}

class _LagExpansion {
  const _LagExpansion({
    required this.multiplier,
    required this.weightScale,
    required this.label,
  });

  final double multiplier;
  final double weightScale;
  final String label;
}

const List<_LagAdjustment> _lagHarmonicAdjustments = [
  _LagAdjustment(
    scale: 2 / 3,
    weight: 0.22,
    label: 'lag_two_thirds',
  ),
  _LagAdjustment(
    scale: 0.75,
    weight: 0.2,
    label: 'lag_three_fourths',
  ),
  _LagAdjustment(
    scale: 0.8,
    weight: 0.28,
    label: 'lag_four_fifths',
  ),
  _LagAdjustment(
    scale: 4 / 3,
    weight: 0.16,
    label: 'lag_four_thirds',
  ),
  _LagAdjustment(
    scale: 5 / 4,
    weight: 0.2,
    label: 'lag_five_fourths',
  ),
  _LagAdjustment(
    scale: 3 / 2,
    weight: 0.14,
    label: 'lag_three_halves',
  ),
];

const List<_LagExpansion> _bestLagExpansions = [
  _LagExpansion(
    multiplier: 4 / 3,
    weightScale: 0.62,
    label: 'best_lag_times_4over3',
  ),
  _LagExpansion(
    multiplier: 5 / 4,
    weightScale: 0.58,
    label: 'best_lag_times_5over4',
  ),
  _LagExpansion(
    multiplier: 3 / 2,
    weightScale: 0.55,
    label: 'best_lag_times_3over2',
  ),
  _LagExpansion(
    multiplier: 2 / 3,
    weightScale: 0.5,
    label: 'best_lag_times_2over3',
  ),
  _LagExpansion(
    multiplier: 3 / 4,
    weightScale: 0.46,
    label: 'best_lag_times_3over4',
  ),
  _LagExpansion(
    multiplier: 4 / 5,
    weightScale: 0.45,
    label: 'best_lag_times_4over5',
  ),
];

/// Apply Harmonic Product Spectrum to autocorrelation lag scores.
///
/// Multiplies autocorrelation at lag L with values at 2L, 3L, 4L, etc.
/// The true fundamental will have strong autocorrelation at all its multiples.
/// Harmonics won't have strong autocorrelation at their sub-harmonics.
