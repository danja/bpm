import 'dart:math' as math;

/// Utility helpers shared across BPM detection algorithms.
class AlgorithmUtils {
  /// Attempts to coerce [bpm] into the inclusive range [minBpm, maxBpm]
  /// by considering common harmonic relationships (double/half tempo, etc.).
  ///
  /// Returns a [BpmRangeResult] describing the adjusted tempo. When no harmonic
  /// candidate falls inside the range, the value is clamped to the nearest
  /// boundary. If [bpm] is non-positive, `null` is returned.
  static BpmRangeResult? coerceToRange(
    double bpm, {
    required double minBpm,
    required double maxBpm,
  }) {
    if (bpm <= 0 || bpm.isNaN || bpm.isInfinite) {
      return null;
    }

    final candidates = <_Candidate>[];
    const harmonicMultipliers = <double>[
      1.0,
      0.5,
      2.0,
      1 / 3,
      3.0,
      0.25,
      4.0,
      2 / 3,
      1.5,
      0.2,
      5.0,
    ];

    final mid = (minBpm + maxBpm) / 2;

    for (final factor in harmonicMultipliers) {
      final candidate = bpm * factor;
      if (candidate < minBpm || candidate > maxBpm) {
        continue;
      }
      final distanceFromOriginal = (candidate - bpm).abs();
      final distanceFromMid = (candidate - mid).abs();
      // Small penalty for stronger harmonic jumps (factors far from 1.0)
      final harmonicPenalty = (factor - 1.0).abs();
      final score = distanceFromOriginal +
          distanceFromMid * 0.1 +
          harmonicPenalty * 0.05;
      candidates.add(
        _Candidate(
          bpm: candidate,
          factor: factor,
          score: score,
        ),
      );
    }

    if (candidates.isNotEmpty) {
      candidates.sort((a, b) => a.score.compareTo(b.score));
      final winner = candidates.first;
      return BpmRangeResult(
        bpm: winner.bpm,
        multiplier: winner.factor,
        clamped: false,
      );
    }

    final clamped = bpm.clamp(minBpm, maxBpm);
    return BpmRangeResult(
      bpm: clamped.toDouble(),
      multiplier: clamped == 0 ? 0 : clamped / bpm,
      clamped: true,
    );
  }

  /// Normalizes [bpm] so it aligns with [reference] under common octave
  /// relationships. Useful for consensus engines attempting to collapse
  /// half/double tempo disagreements.
  static double normalizeToReference(
    double bpm,
    double reference, {
    required double minBpm,
    required double maxBpm,
  }) {
    if (bpm <= 0 || reference <= 0) {
      return bpm;
    }

    const harmonics = <double>[
      1 / 4,
      1 / 3,
      0.5,
      2 / 3,
      1.0,
      1.5,
      2.0,
      3.0,
      4.0,
    ];

    _Candidate? best;
    for (final factor in harmonics) {
      final candidate = bpm * factor;
      if (candidate < minBpm || candidate > maxBpm) {
        continue;
      }
      final diff = (candidate - reference).abs();
      final harmonicPenalty = math.max(0.0, (factor - 1.0).abs() - 0.1);
      final score = diff + harmonicPenalty * 2;
      if (best == null || score < best.score) {
        best = _Candidate(
          bpm: candidate,
          factor: factor,
          score: score,
        );
      }
    }

    if (best != null) {
      return best.bpm;
    }

    return bpm.clamp(minBpm, maxBpm).toDouble();
  }

  static TempoRefinementResult? refineFromCandidates({
    required List<TempoCandidate> candidates,
    required double minBpm,
    required double maxBpm,
    double clusterToleranceBpm = 1.5,
  }) => AlgorithmTempoRefinement.refineFromCandidates(
        candidates: candidates,
        minBpm: minBpm,
        maxBpm: maxBpm,
        clusterToleranceBpm: clusterToleranceBpm,
      );

  static TempoRefinementResult? refineFromIntervals({
    required List<double> intervals,
    required double minBpm,
    required double maxBpm,
  }) => AlgorithmTempoRefinement.refineFromIntervals(
        intervals: intervals,
        minBpm: minBpm,
        maxBpm: maxBpm,
      );
}

/// Result of adjusting a BPM value into a constrained range.
class BpmRangeResult {
  const BpmRangeResult({
    required this.bpm,
    required this.multiplier,
    required this.clamped,
  });

  /// Adjusted BPM within bounds.
  final double bpm;

  /// Multiplier applied to the original BPM to obtain [bpm].
  /// Values far from 1.0 indicate octave corrections.
  final double multiplier;

  /// True when the value simply clamped to nearest boundary (no harmonic found).
  final bool clamped;
}

class _Candidate {
  const _Candidate({
    required this.bpm,
    required this.factor,
    required this.score,
  });

  final double bpm;
  final double factor;
  final double score;
}

/// Weighted BPM candidate used for harmonic clustering.
class TempoCandidate {
  const TempoCandidate({
    required this.bpm,
    this.weight = 1.0,
    this.source,
    this.allowHarmonics = true,
  });

  /// Raw BPM estimate (may be outside target range).
  final double bpm;

  /// Relative weight for the candidate prior to harmonic penalties.
  final double weight;

  /// Optional label for debugging/metadata.
  final String? source;

  /// If false, candidate is considered literal (no harmonic adjustments).
  final bool allowHarmonics;
}

/// Result of harmonic clustering and refinement.
class TempoRefinementResult {
  const TempoRefinementResult({
    required this.bpm,
    required this.totalWeight,
    required this.std,
    required this.consistency,
    required this.clusterSize,
    required this.maxMultiplierDeviation,
    required this.clampedCount,
    required this.averageMultiplier,
    required this.metadata,
  });

  final double bpm;
  final double totalWeight;
  final double std;
  final double consistency;
  final int clusterSize;
  final double maxMultiplierDeviation;
  final int clampedCount;
  final double averageMultiplier;
  final Map<String, Object?> metadata;
}

/// Shared harmonic refinement utilities for algorithms.
extension AlgorithmTempoRefinement on AlgorithmUtils {
  /// Builds a refined tempo estimate by clustering a list of [TempoCandidate]s.
  static TempoRefinementResult? refineFromCandidates({
    required List<TempoCandidate> candidates,
    required double minBpm,
    required double maxBpm,
    double clusterToleranceBpm = 1.5,
  }) {
    if (candidates.isEmpty) {
      return null;
    }

    final clusters = <_TempoCluster>[];

    for (final candidate in candidates) {
      if (candidate.bpm <= 0 || candidate.weight <= 0) {
        continue;
      }

      final harmonicFactors = candidate.allowHarmonics
          ? const [1.0, 0.5, 2.0, 1.5, 2 / 3, 3.0]
          : const [1.0];

      for (final factor in harmonicFactors) {
        final adjusted = AlgorithmUtils.coerceToRange(
          candidate.bpm * factor,
          minBpm: minBpm,
          maxBpm: maxBpm,
        );
        if (adjusted == null || adjusted.bpm <= 0) {
          continue;
        }

        var weight = candidate.weight;
        final multiplierDeviation = (adjusted.multiplier - 1.0).abs();
        weight *= (1.0 - math.min(0.5, multiplierDeviation * 0.4));
        if (adjusted.clamped) {
          weight *= 0.6;
        }
        if (weight <= 0) {
          continue;
        }

        _TempoCluster? cluster;
        for (final existing in clusters) {
          if ((existing.mean - adjusted.bpm).abs() <= clusterToleranceBpm) {
            cluster = existing;
            break;
          }
        }
        cluster ??= _TempoCluster();
        cluster.add(
          bpm: adjusted.bpm,
          weight: weight,
          multiplier: adjusted.multiplier,
          clamped: adjusted.clamped,
          source: candidate.source,
        );
        if (!clusters.contains(cluster)) {
          clusters.add(cluster);
        }
      }
    }

    if (clusters.isEmpty) {
      return null;
    }

    clusters.sort((a, b) {
      final scoreA = a.qualityScore;
      final scoreB = b.qualityScore;
      if (scoreA == scoreB) {
        return b.totalWeight.compareTo(a.totalWeight);
      }
      return scoreB.compareTo(scoreA);
    });

    final winner = clusters.first;
    final refinedBpm = AlgorithmUtils.coerceToRange(
      winner.mean,
      minBpm: minBpm,
      maxBpm: maxBpm,
    )?.bpm ?? winner.mean;

    final metadata = <String, Object?>{
      'clusterWeight': winner.totalWeight,
      'clusterStd': winner.std,
      'clusterCount': winner.count,
      'clusterConsistency': winner.consistency,
      'maxMultiplierDeviation': winner.maxMultiplierDeviation,
      'clampedContributors': winner.clampedCount,
      'rangeMultiplier': winner.averageMultiplier,
      'rangeClamped': winner.clampedCount > 0,
      'sources': winner.sources.toList(),
      'rawClusterBpm': winner.mean,
    };

    return TempoRefinementResult(
      bpm: refinedBpm,
      totalWeight: winner.totalWeight,
      std: winner.std,
      consistency: winner.consistency,
      clusterSize: winner.count,
      maxMultiplierDeviation: winner.maxMultiplierDeviation,
      clampedCount: winner.clampedCount,
      averageMultiplier: winner.averageMultiplier,
      metadata: metadata,
    );
  }

  /// Convenience helper for refining tempo based on inter-onset intervals.
  static TempoRefinementResult? refineFromIntervals({
    required List<double> intervals,
    required double minBpm,
    required double maxBpm,
  }) {
    if (intervals.isEmpty) {
      return null;
    }

    final cleaned = intervals.where((value) => value > 0).toList();
    if (cleaned.isEmpty) {
      return null;
    }

    cleaned.sort();
    final representative = _representativeInterval(cleaned);
    if (representative <= 0) {
      return null;
    }

    final medianInterval = cleaned[cleaned.length ~/ 2];
    final maxInterval = cleaned.last;
    final minInterval = cleaned.first;
    final spread = math.max(1e-6, representative * 0.4);

    final candidates = <TempoCandidate>[];

    for (final interval in cleaned) {
      final weight = 1.0 /
          (1.0 +
              (interval - representative).abs() / spread +
              (interval - medianInterval).abs() / (representative * 0.6 + 1e-6));
      candidates.add(
        TempoCandidate(
          bpm: 60.0 / interval,
          weight: weight,
          source: 'interval',
        ),
      );
    }

    // Add aggregate candidates.
    final meanInterval =
        cleaned.fold<double>(0, (sum, value) => sum + value) / cleaned.length;
    candidates.add(
      TempoCandidate(
        bpm: 60.0 / representative,
        weight: 1.2,
        source: 'representative',
      ),
    );
    candidates.add(
      TempoCandidate(
        bpm: 60.0 / meanInterval,
        weight: 0.9,
        source: 'mean',
      ),
    );
    candidates.add(
      TempoCandidate(
        bpm: 60.0 / medianInterval,
        weight: 1.0,
        source: 'median',
      ),
    );
    candidates.add(
      TempoCandidate(
        bpm: 60.0 / maxInterval,
        weight: 0.6,
        source: 'max',
      ),
    );
    candidates.add(
      TempoCandidate(
        bpm: 60.0 / minInterval,
        weight: 0.6,
        source: 'min',
      ),
    );

    return refineFromCandidates(
      candidates: candidates,
      minBpm: minBpm,
      maxBpm: maxBpm,
    );
  }
}

class _TempoCluster {
  double totalWeight = 0;
  double weightedSum = 0;
  double weightedSquareSum = 0;
  int count = 0;
  double maxMultiplierDeviation = 0;
  int clampedCount = 0;
  double weightedMultiplierSum = 0;
  final Set<String> sources = <String>{};

  double get mean => totalWeight == 0 ? 0 : weightedSum / totalWeight;

  double get std {
    if (totalWeight == 0) return 0;
    final m = mean;
    final variance =
        (weightedSquareSum / totalWeight) - (m * m);
    return variance <= 0 ? 0 : math.sqrt(variance);
  }

  double get consistency {
    final spread = std;
    final spreadScore = (1.0 / (1.0 + spread / 3.0)).clamp(0.25, 1.0);
    final harmonicPenalty =
        (1.0 - math.min(0.5, maxMultiplierDeviation * 0.35)).clamp(0.35, 1.0);
    final clampPenalty =
        clampedCount == 0 ? 1.0 : math.max(0.55, 1.0 - clampedCount * 0.08);
    return (spreadScore * harmonicPenalty * clampPenalty).clamp(0.2, 1.0);
  }

  double get qualityScore => totalWeight * consistency;

  double get averageMultiplier =>
      totalWeight == 0 ? 1.0 : weightedMultiplierSum / totalWeight;

  void add({
    required double bpm,
    required double weight,
    required double multiplier,
    required bool clamped,
    String? source,
  }) {
    totalWeight += weight;
    weightedSum += bpm * weight;
    weightedSquareSum += bpm * bpm * weight;
    maxMultiplierDeviation =
        math.max(maxMultiplierDeviation, (multiplier - 1.0).abs());
    if (clamped) {
      clampedCount++;
    }
    weightedMultiplierSum += multiplier * weight;
    if (source != null) {
      sources.add(source);
    }
    count++;
  }
}

double _representativeInterval(List<double> sortedIntervals) {
  if (sortedIntervals.isEmpty) {
    return 0;
  }
  if (sortedIntervals.length <= 2) {
    return sortedIntervals[sortedIntervals.length ~/ 2];
  }
  final start =
      (sortedIntervals.length * 0.25).floor().clamp(0, sortedIntervals.length - 1);
  final end =
      (sortedIntervals.length * 0.85).ceil().clamp(start + 1, sortedIntervals.length);
  final slice = sortedIntervals.sublist(start, end);
  slice.sort();
  return slice[slice.length ~/ 2];
}
