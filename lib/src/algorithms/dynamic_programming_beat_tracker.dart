import 'dart:math' as math;

import 'package:bpm/src/algorithms/algorithm_utils.dart';
import 'package:bpm/src/algorithms/bpm_detection_algorithm.dart';
import 'package:bpm/src/dsp/preprocessing_pipeline.dart';
import 'package:bpm/src/models/bpm_models.dart';

/// Dynamic-programming beat tracker inspired by Ellis (2007).
///
/// Operates on the shared onset envelope produced by the preprocessing
/// pipeline and searches for a smooth sequence of beats that maximises onset
/// energy while penalising large tempo swings. The resulting beat interval is
/// converted to BPM so the algorithm can participate in the existing
/// consensus process.
class DynamicProgrammingBeatTracker extends BpmDetectionAlgorithm {
  DynamicProgrammingBeatTracker({
    this.lambda = 0.6,
    this.maxFrames = 2400,
    this.tempoStepBpm = 1.0,
  });

  /// Smoothness penalty applied when consecutive beat intervals diverge.
  final double lambda;

  /// Maximum number of onset frames evaluated (tail window).
  final int maxFrames;

  /// Tempo discretisation step in BPM.
  final double tempoStepBpm;

  @override
  String get id => 'dp_beat_tracker';

  @override
  String get label => 'Dynamic Programming Beat Tracker';

  @override
  Duration get preferredWindow => const Duration(seconds: 12);

  @override
  Future<BpmReading?> analyze({required PreprocessedSignal signal}) async {
    final onsetEnvelope = signal.onsetEnvelope;
    if (onsetEnvelope.isEmpty) {
      return null;
    }

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
    final featureRate = (1.0 / signal.onsetTimeScale).clamp(1.0, 200.0);
    final minBpm = signal.context.minBpm.clamp(40.0, 300.0);
    final maxBpm = signal.context.maxBpm.clamp(40.0, 300.0);
    if (maxBpm <= minBpm) {
      return null;
    }

    final minPeriod = (featureRate * 60.0 / maxBpm).floor().clamp(1, 400);
    final maxPeriod =
        (featureRate * 60.0 / minBpm).ceil().clamp(minPeriod, 800);
    if (maxPeriod - minPeriod < 2) {
      return null;
    }

    final frameCount = math.min(onsetEnvelope.length, maxFrames);
    final startOffset = onsetEnvelope.length - frameCount;
    final envelope = List<double>.generate(
      frameCount,
      (index) => onsetEnvelope[startOffset + index].toDouble(),
    );

    final tempoBins = _buildTempoBins(
      minPeriod: minPeriod,
      maxPeriod: maxPeriod,
      stepBpm: tempoStepBpm,
      featureRate: featureRate,
    );
    if (tempoBins.periods.isEmpty) {
      return null;
    }

    final dp = List.generate(
      frameCount,
      (_) => List<double>.filled(
          tempoBins.periods.length, double.negativeInfinity),
    );
    final backTime = List.generate(
      frameCount,
      (_) => List<int>.filled(tempoBins.periods.length, -1),
    );
    final backTempo = List.generate(
      frameCount,
      (_) => List<int>.filled(tempoBins.periods.length, -1),
    );

    // Pre-compute absolute differences to avoid recomputation inside loops.
    final tempoDifferences = List.generate(
      tempoBins.periods.length,
      (i) => List<double>.generate(
        tempoBins.periods.length,
        (j) => (tempoBins.periods[i] - tempoBins.periods[j]).abs().toDouble(),
      ),
    );

    // Dynamic programming forward pass.
    for (var t = 0; t < frameCount; t++) {
      final energy = envelope[t];
      for (var tempoIndex = 0;
          tempoIndex < tempoBins.periods.length;
          tempoIndex++) {
        final period = tempoBins.periods[tempoIndex];
        final tempoBpm = tempoBins.bpms[tempoIndex];
        final tempoPenalty = _tempoPenalty(tempoBpm, maxBpm);
        var bestScore = energy - tempoPenalty;
        var bestPrevTime = -1;
        var bestPrevTempo = -1;
        final prevTime = t - period;
        if (prevTime >= 0) {
          var candidateScore = double.negativeInfinity;
          for (var prevTempoIndex = 0;
              prevTempoIndex < tempoBins.periods.length;
              prevTempoIndex++) {
            final prevScore = dp[prevTime][prevTempoIndex];
            if (prevScore.isFinite) {
              final penalty =
                  lambda * tempoDifferences[tempoIndex][prevTempoIndex];
              final score = prevScore + energy - penalty - tempoPenalty;
              if (score > candidateScore) {
                candidateScore = score;
                bestPrevTime = prevTime;
                bestPrevTempo = prevTempoIndex;
              }
            }
          }
          if (candidateScore.isFinite) {
            bestScore = candidateScore;
          }
        }
        dp[t][tempoIndex] = bestScore;
        backTime[t][tempoIndex] = bestPrevTime;
        backTempo[t][tempoIndex] = bestPrevTempo;
      }
    }

    final bestTerminal = _findBestTerminal(dp);
    if (bestTerminal == null) {
      return null;
    }

    final pathFrames = <int>[];
    var currentTime = bestTerminal.time;
    var currentTempo = bestTerminal.tempoIndex;
    while (currentTime >= 0 && currentTempo >= 0) {
      pathFrames.add(currentTime);
      final prevTime = backTime[currentTime][currentTempo];
      final prevTempo = backTempo[currentTime][currentTempo];
      if (prevTime < 0 || prevTempo < 0) {
        break;
      }
      currentTime = prevTime;
      currentTempo = prevTempo;
    }

    if (pathFrames.length < 2) {
      return null;
    }

    pathFrames.sort();
    final beatIntervals = <int>[];
    for (var i = 1; i < pathFrames.length; i++) {
      beatIntervals.add(pathFrames[i] - pathFrames[i - 1]);
    }
    if (beatIntervals.isEmpty) {
      return null;
    }

    final filteredIntervals = _filterIntervals(
      beatIntervals,
      minPeriod: minPeriod,
      maxPeriod: maxPeriod,
    );
    if (filteredIntervals.isEmpty) {
      return null;
    }

    final startSeconds = startOffset / featureRate;
    final beatTimes = pathFrames
        .map((frame) => startSeconds + frame / featureRate)
        .toList(growable: false);

    final beatEnergy = pathFrames.fold<double>(
      0,
      (sum, t) => sum + envelope[t],
    );
    final totalEnergy =
        envelope.fold<double>(0, (sum, value) => sum + value.abs()) + 1e-6;
    final energyRatio = (beatEnergy / totalEnergy).clamp(0.0, 1.0);
    final basePeriod = _trimmedMean(filteredIntervals);
    final baseSmoothness = _computeSmoothness(filteredIntervals);

    final candidates = <_DpTempoCandidate>[
      _DpTempoCandidate(
        factor: 1.0,
        period: basePeriod,
        bpm: featureRate * 60.0 / basePeriod,
        smoothness: baseSmoothness,
        intervals: filteredIntervals,
        preferencePenalty: 0.0,
      ),
    ];

    for (var factor = 2; factor <= 4; factor++) {
      final aggregated = _aggregateIntervals(filteredIntervals, factor);
      if (aggregated.length < 2) {
        continue;
      }
      final period = _trimmedMean(aggregated);
      if (!period.isFinite || period <= 0) {
        continue;
      }
      final candidateBpm = featureRate * 60.0 / period;
      if (candidateBpm < minBpm || candidateBpm > maxBpm) {
        continue;
      }
      final candidateSmoothness = _computeSmoothness(aggregated);
      candidates.add(
        _DpTempoCandidate(
          factor: factor.toDouble(),
          period: period,
          bpm: candidateBpm,
          smoothness: candidateSmoothness,
          intervals: aggregated,
          preferencePenalty: 0.05 * (factor - 1),
        ),
      );
    }

    for (final expansion in _dpHarmonicExpansions) {
      final scaledPeriod = basePeriod * expansion.multiplier;
      if (!scaledPeriod.isFinite ||
          scaledPeriod <= 0 ||
          scaledPeriod < minPeriod ||
          scaledPeriod > maxPeriod) {
        continue;
      }
      final candidateBpm = featureRate * 60.0 / scaledPeriod;
      if (candidateBpm < minBpm || candidateBpm > maxBpm) {
        continue;
      }
      final scaledIntervals = _scaleIntervals(
        filteredIntervals,
        expansion.multiplier,
        minLimit: minPeriod,
        maxLimit: maxPeriod,
      );
      if (scaledIntervals.length < 2) {
        continue;
      }
      final candidateSmoothness = _computeSmoothness(scaledIntervals);
      candidates.add(
        _DpTempoCandidate(
          factor: expansion.multiplier,
          period: scaledPeriod,
          bpm: candidateBpm,
          smoothness: candidateSmoothness,
          intervals: scaledIntervals,
          preferencePenalty: expansion.penalty,
        ),
      );
    }

    final bestCandidate = _selectBestTempoCandidate(
      candidates: candidates,
      energyRatio: energyRatio,
    );

    final rawMultiplier = bestCandidate.factor;
    final subdivisionFactor = rawMultiplier >= 1.0
        ? rawMultiplier
        : (rawMultiplier <= 0 ? 1.0 : 1.0 / rawMultiplier);
    final effectiveIntervals = bestCandidate.intervals;
    final smoothness = bestCandidate.smoothness.clamp(0.0, 1.0);
    var bpm = bestCandidate.bpm.clamp(minBpm, maxBpm);
    final originalBpm = bpm;
    final trimmedPeriod = bestCandidate.period;
    var harmonicOverrideApplied = false;
    double? harmonicOverrideRatio;

    var confidence =
        (0.25 + 0.5 * energyRatio + 0.25 * (1.0 - smoothness).clamp(0.0, 1.0))
            .clamp(0.0, 1.0);
    if (subdivisionFactor > 1.0) {
      confidence *= math.pow(0.82, subdivisionFactor - 1).toDouble();
    }
    if (effectiveIntervals.length < 3) {
      confidence *= 0.9;
    }

    if (rawMultiplier < 0.95) {
      final adjustedBpm = (bpm * rawMultiplier).clamp(minBpm, maxBpm);
      if ((adjustedBpm - bpm).abs() > 2.0) {
        bpm = adjustedBpm;
        confidence *= 0.93;
        harmonicOverrideApplied = true;
        harmonicOverrideRatio = rawMultiplier;
      }
    }

    if (rawMultiplier >= 1.8 && rawMultiplier <= 3.5) {
      final adjustedRatio = (rawMultiplier - 0.5).clamp(1.1, 2.8);
      final adjustedBpm = (bpm * adjustedRatio).clamp(minBpm, maxBpm);
      if ((adjustedBpm - bpm).abs() > 2.5) {
        bpm = adjustedBpm;
        confidence *= 0.9;
        harmonicOverrideApplied = true;
        harmonicOverrideRatio = adjustedRatio;
      }
    }

    if (plpAnchorBpm != null && plpAnchorBpm > 0) {
      final preAnchorBpm = bpm;
      final normalized = AlgorithmUtils.normalizeToReference(
        bpm,
        plpAnchorBpm,
        minBpm: minBpm,
        maxBpm: maxBpm,
      );
      if ((normalized - plpAnchorBpm).abs() < (bpm - plpAnchorBpm).abs() - 1e-6) {
        bpm = normalized;
        confidence *= 0.95;
        harmonicOverrideApplied = true;
        harmonicOverrideRatio ??= normalized / originalBpm;
      }

      const anchorRatios = [4 / 5, 3 / 4, 5 / 6, 2 / 3];
      var bestAnchorCandidate = bpm;
      var bestAnchorDiff = (preAnchorBpm - plpAnchorBpm).abs();
      for (final ratio in anchorRatios) {
        final candidate = (preAnchorBpm * ratio).clamp(minBpm, maxBpm);
        final diff = (candidate - plpAnchorBpm).abs();
        if (diff + 1e-6 < bestAnchorDiff &&
            (candidate - bpm).abs() > 1.5) {
          bestAnchorDiff = diff;
          bestAnchorCandidate = candidate;
          harmonicOverrideRatio = ratio;
        }
      }
      if ((bestAnchorCandidate - bpm).abs() > 1.5 &&
          bestAnchorDiff < (preAnchorBpm - plpAnchorBpm).abs() - 1e-6) {
        bpm = bestAnchorCandidate;
        confidence *= 0.95;
        harmonicOverrideApplied = true;
      }
    }

    return BpmReading(
      algorithmId: id,
      algorithmName: label,
      bpm: bpm,
      confidence: confidence,
      timestamp: DateTime.now().toUtc(),
      metadata: {
        'featureRate': featureRate,
        'meanPeriodFrames': trimmedPeriod,
        'energyRatio': energyRatio,
        'smoothness': smoothness,
        'score': bestTerminal.score,
        'tempoEstimateBpm': bpm,
        'tempoBinCount': tempoBins.periods.length,
        'lambda': lambda,
        'beatCount': pathFrames.length,
        'beatTimes': beatTimes,
        'beatIntervalsFrames': effectiveIntervals,
        if (subdivisionFactor > 1.0 || rawMultiplier < 1.0)
          'rawBeatIntervalsFrames': filteredIntervals,
        'subdivisionFactor': subdivisionFactor,
        if (rawMultiplier != subdivisionFactor)
          'harmonicMultiplier': rawMultiplier,
        if (harmonicOverrideApplied)
          'harmonicOverrideRatio': harmonicOverrideRatio,
        if (harmonicOverrideApplied)
          'harmonicOverrideApplied': true,
        'baseTempoEstimateBpm': originalBpm,
        if (plpAnchorBpm != null) 'plpAnchorBpm': plpAnchorBpm,
      },
    );
  }

  _TempoBins _buildTempoBins({
    required int minPeriod,
    required int maxPeriod,
    required double stepBpm,
    required double featureRate,
  }) {
    final periods = <int>[];
    final bpms = <double>[];
    final minBpm = featureRate * 60.0 / maxPeriod;
    final maxBpm = featureRate * 60.0 / minPeriod;
    for (var bpm = minBpm; bpm <= maxBpm; bpm += stepBpm) {
      final period = (featureRate * 60.0 / bpm).round();
      if (period < minPeriod || period > maxPeriod) {
        continue;
      }
      if (periods.isEmpty || periods.last != period) {
        periods.add(period);
        bpms.add(bpm);
      }
    }
    return _TempoBins(periods: periods, bpms: bpms);
  }

  _TerminalState? _findBestTerminal(List<List<double>> dp) {
    var bestScore = double.negativeInfinity;
    var bestTime = -1;
    var bestTempo = -1;
    for (var t = 0; t < dp.length; t++) {
      for (var tempoIndex = 0; tempoIndex < dp[t].length; tempoIndex++) {
        final score = dp[t][tempoIndex];
        if (score > bestScore) {
          bestScore = score;
          bestTime = t;
          bestTempo = tempoIndex;
        }
      }
    }
    if (bestTime < 0 || bestTempo < 0 || !bestScore.isFinite) {
      return null;
    }
    return _TerminalState(
        time: bestTime, tempoIndex: bestTempo, score: bestScore);
  }

  double _computeSmoothness(List<int> intervals) {
    if (intervals.length < 2) {
      return 0.0;
    }
    final mean = intervals.reduce((a, b) => a + b) / intervals.length;
    final variance = intervals.fold<double>(
      0,
      (sum, value) => sum + math.pow(value - mean, 2),
    );
    final stdDev = math.sqrt(variance / intervals.length);
    return (stdDev / (mean.abs() + 1e-6)).clamp(0.0, 1.0);
  }

  double _tempoPenalty(double bpm, double contextMaxBpm) {
    final baseThreshold = contextMaxBpm - 25.0;
    final threshold = math.min(200.0, math.max(150.0, baseThreshold));
    if (bpm <= threshold) {
      return 0.0;
    }
    final span = math.max(30.0, contextMaxBpm - threshold);
    final normalized =
        ((bpm - threshold) / span).clamp(0.0, 1.0).toDouble();
    return math.pow(normalized, 1.1) * 0.18;
  }

  double _trimmedMean(List<int> intervals) {
    if (intervals.isEmpty) {
      return 1.0;
    }
    final values = intervals.map((e) => e.toDouble()).toList()..sort();
    final trim = (values.length * 0.1).floor();
    final start = trim.clamp(0, values.length - 1);
    final end = (values.length - trim).clamp(start + 1, values.length);
    final window = values.sublist(start, end);
    final sum = window.fold<double>(0, (sum, value) => sum + value);
    return sum / window.length;
  }

  List<int> _filterIntervals(
    List<int> intervals, {
    required int minPeriod,
    required int maxPeriod,
  }) {
    final lower = (minPeriod * 0.8).floor();
    final upper = (maxPeriod * 1.25).ceil();
    final filtered = intervals
        .where((value) => value >= lower && value <= upper)
        .toList(growable: false);
    if (filtered.isNotEmpty) {
      return filtered;
    }
    return intervals;
  }

  List<int> _aggregateIntervals(List<int> intervals, int factor) {
    if (factor <= 1 || intervals.length < factor) {
      return List<int>.from(intervals);
    }
    final aggregated = <int>[];
    for (var i = 0; i <= intervals.length - factor; i++) {
      var sum = 0;
      for (var j = 0; j < factor; j++) {
        sum += intervals[i + j];
      }
      aggregated.add(sum);
    }
    return aggregated;
  }

  List<int> _scaleIntervals(
    List<int> intervals,
    double multiplier, {
    required int minLimit,
    required int maxLimit,
  }) {
    if (intervals.isEmpty || multiplier <= 0) {
      return const [];
    }
    final scaled = <int>[];
    for (final value in intervals) {
      final scaledValue = (value * multiplier).round();
      if (scaledValue < minLimit || scaledValue > maxLimit) {
        continue;
      }
      scaled.add(scaledValue);
    }
    return scaled;
  }

  _DpTempoCandidate _selectBestTempoCandidate({
    required List<_DpTempoCandidate> candidates,
    required double energyRatio,
  }) {
    var best = candidates.first;
    var bestScore = double.negativeInfinity;
    for (final candidate in candidates) {
      final smoothScore =
          (1.0 - candidate.smoothness).clamp(0.0, 1.0).toDouble();
      final factorPenalty = 0.08 * (candidate.factor - 1);
      double energyAdjustment = 0.0;
      if (energyRatio < 0.12) {
        final boost = (0.12 - energyRatio).clamp(0.0, 0.12);
        energyAdjustment = boost * 2.5 * (candidate.factor - 1);
      } else if (energyRatio > 0.22) {
        final penalty = (energyRatio - 0.22).clamp(0.0, 0.12);
        energyAdjustment = -penalty * 2.0 * (candidate.factor - 1);
      }
      var score = smoothScore -
          factorPenalty +
          energyAdjustment -
          candidate.preferencePenalty;
      if (candidate.factor < 1.0) {
        final boost = (1.0 - candidate.factor).clamp(0.0, 0.5);
        score += 0.18 * boost;
      }
      if (score > bestScore + 1e-6) {
        best = candidate;
        bestScore = score;
      } else if ((score - bestScore).abs() <= 1e-6) {
        if (candidate.factor < best.factor ||
            (candidate.factor == best.factor &&
                candidate.bpm < best.bpm &&
                candidate.smoothness <= best.smoothness)) {
          best = candidate;
        }
      }
    }
    return best;
  }
}

class _TempoBins {
  const _TempoBins({required this.periods, required this.bpms});

  final List<int> periods;
  final List<double> bpms;
}

class _DpTempoCandidate {
  const _DpTempoCandidate({
    required this.factor,
    required this.period,
    required this.bpm,
    required this.smoothness,
    required this.intervals,
    required this.preferencePenalty,
  });

  final double factor;
  final double period;
  final double bpm;
  final double smoothness;
  final List<int> intervals;
  final double preferencePenalty;
}

class _TerminalState {
  const _TerminalState({
    required this.time,
    required this.tempoIndex,
    required this.score,
  });

  final int time;
  final int tempoIndex;
  final double score;
}

class _DpHarmonicExpansion {
  const _DpHarmonicExpansion({
    required this.multiplier,
    required this.penalty,
  });

  final double multiplier;
  final double penalty;
}

const List<_DpHarmonicExpansion> _dpHarmonicExpansions = [
  _DpHarmonicExpansion(
    multiplier: 4 / 3,
    penalty: 0.15,
  ),
  _DpHarmonicExpansion(
    multiplier: 3 / 2,
    penalty: 0.18,
  ),
  _DpHarmonicExpansion(
    multiplier: 5 / 4,
    penalty: 0.12,
  ),
  _DpHarmonicExpansion(
    multiplier: 6 / 5,
    penalty: 0.12,
  ),
  _DpHarmonicExpansion(
    multiplier: 3 / 4,
    penalty: 0.08,
  ),
  _DpHarmonicExpansion(
    multiplier: 2 / 3,
    penalty: 0.08,
  ),
  _DpHarmonicExpansion(
    multiplier: 5 / 6,
    penalty: 0.06,
  ),
];
