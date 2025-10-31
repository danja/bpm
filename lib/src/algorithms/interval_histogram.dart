import 'dart:math' as math;

import 'package:bpm/src/algorithms/detection_context.dart';

import 'algorithm_utils.dart';

/// Histogram-based selector favouring longer fundamental intervals.
class IntervalHistogram {
  IntervalHistogram({
    required this.context,
    this.binSize = 0.02,
  });

  final DetectionContext context;
  final double binSize;

  final Map<double, _HistogramBucket> _buckets = <double, _HistogramBucket>{};
  double _longestInterval = 0;

  void accumulate({
    required double interval,
    required double weight,
    int supporters = 0,
    required String source,
  }) {
    if (interval <= 0 || weight <= 0) {
      return;
    }
    final normalized = _normalizeInterval(interval);
    if (normalized <= 0) {
      return;
    }
    final bin = (normalized / binSize).round() * binSize;
    final bucket =
        _buckets.putIfAbsent(bin, () => _HistogramBucket(interval: bin));
    bucket.add(
      weight: weight,
      supporters: supporters,
      source: source,
    );
    if (normalized > _longestInterval) {
      _longestInterval = normalized;
    }
  }

  /// Prefers longer intervals by boosting weights based on interval ratio.
  void applyLengthBoost() {
    if (_longestInterval <= 0) {
      return;
    }
    for (final bucket in _buckets.values) {
      final lengthRatio = (bucket.interval / _longestInterval).clamp(0.3, 1.0);
      bucket.applyBoost(lengthRatio * lengthRatio);
    }
  }

  /// Suppresses harmonic buckets (half-intervals) when a longer fundamental has strong support.
  void suppressShorterHarmonics({
    double minShare = 0.2,
    double suppressionFactor = 0.12,
  }) {
    final totalScore = _totalScore();
    if (totalScore <= 0) {
      return;
    }

    for (final bucket in _buckets.values) {
      if (!bucket.containsSource('half_interval') &&
          !bucket.containsSource('half_lag')) {
        continue;
      }
      final fundamental = _findNearest(bucket.interval * 2);
      if (fundamental == null) {
        continue;
      }
      if (!fundamental.containsSource('interval') &&
          !fundamental.containsSource('lag')) {
        continue;
      }
      final share = fundamental.score / totalScore;
      if (share >= minShare) {
        bucket.suppress(suppressionFactor);
      }
    }
  }

  HistogramSelection? select({bool preferLonger = true}) {
    final sorted = _sortedBuckets();
    if (sorted.isEmpty) {
      return null;
    }

    final primary = sorted.first;
    var selected = primary;

    if (preferLonger) {
      for (final bucket in sorted) {
        final bpm = 60.0 / bucket.interval;
        final primaryBpm = 60.0 / primary.interval;
        if (bpm <= primaryBpm / 1.6 && bucket.score >= primary.score * 0.6) {
          selected = bucket;
          break;
        }
      }
    }

    final normalizedInterval = _normalizeInterval(selected.interval);
    if (normalizedInterval <= 0) {
      return null;
    }

    final multiplier = normalizedInterval / selected.interval;
    final scoreMap = <double, double>{
      for (final bucket in sorted) 60.0 / bucket.interval: bucket.score,
    };

    final suppressed = sorted
        .where((bucket) => bucket.suppressed)
        .map((bucket) => 60.0 / bucket.interval)
        .toList();

    return HistogramSelection(
      interval: selected.interval,
      normalizedInterval: normalizedInterval,
      score: selected.score,
      totalScore: _totalScore(),
      supporters: selected.count,
      scoreMap: scoreMap,
      multiplier: multiplier,
      sources: selected.sources.toList(),
      suppressedBpms: suppressed,
    );
  }

  List<TempoCandidate> toTempoCandidates() {
    return _buckets.values
        .map(
          (bucket) => TempoCandidate(
            bpm: 60.0 / bucket.interval,
            weight: bucket.score,
            source: bucket.sources.isEmpty
                ? null
                : bucket.sources.join('+'),
          ),
        )
        .toList();
  }

  double _totalScore() =>
      _buckets.values.fold<double>(0, (sum, bucket) => sum + bucket.score);

  List<_HistogramBucket> _sortedBuckets() {
    final list = _buckets.values.toList()
      ..sort((a, b) {
        final scoreCompare = b.score.compareTo(a.score);
        if (scoreCompare != 0) {
          return scoreCompare;
        }
        return a.interval.compareTo(b.interval);
      });
    return list;
  }

  _HistogramBucket? _findNearest(double targetInterval) {
    _HistogramBucket? best;
    var bestDiff = double.infinity;
    for (final bucket in _buckets.values) {
      final diff = (bucket.interval - targetInterval).abs();
      if (diff < bestDiff && diff <= binSize * 2.5) {
        best = bucket;
        bestDiff = diff;
      }
    }
    return best;
  }

  double _normalizeInterval(double interval) {
    var value = interval;
    var guard = 0;
    while (value > 0 && 60.0 / value > context.maxBpm && guard < 6) {
      value *= 2;
      guard++;
    }
    while (value > 0 && 60.0 / value < context.minBpm && guard > -6) {
      value /= 2;
      guard--;
    }
    return value <= 0 ? 0 : value;
  }
}

class HistogramSelection {
  const HistogramSelection({
    required this.interval,
    required this.normalizedInterval,
    required this.score,
    required this.totalScore,
    required this.supporters,
    required this.scoreMap,
    required this.multiplier,
    required this.sources,
    required this.suppressedBpms,
  });

  final double interval;
  final double normalizedInterval;
  final double score;
  final double totalScore;
  final int supporters;
  final Map<double, double> scoreMap;
  final double multiplier;
  final List<String> sources;
  final List<double> suppressedBpms;
}

class _HistogramBucket {
  _HistogramBucket({required this.interval});

  final double interval;
  double weight = 0;
  int count = 0;
  bool suppressed = false;
  final Set<String> sources = <String>{};

  double get score => weight * interval;

  void add({
    required double weight,
    required int supporters,
    required String source,
  }) {
    this.weight += weight;
    count += supporters;
    sources.add(source);
  }

  void applyBoost(double multiplier) {
    weight *= multiplier;
  }

  void suppress(double factor) {
    weight *= factor;
    suppressed = true;
  }

  bool containsSource(String source) => sources.contains(source);
}
