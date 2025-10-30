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
