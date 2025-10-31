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
      bucket.applyBoost(lengthRatio * lengthRatio * lengthRatio);
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
      var shouldSuppress = false;

      if (bucket.containsSource('half_interval') ||
          bucket.containsSource('half_lag')) {
        final fundamental = _findNearest(bucket.interval * 2);
        if (fundamental != null &&
            (fundamental.containsSource('interval') ||
                fundamental.containsSource('lag'))) {
          final share = fundamental.score / totalScore;
          if (share >= minShare) {
            shouldSuppress = true;
          }
        }
      }

      if (!shouldSuppress) {
        for (final candidate in _buckets.values) {
          if (candidate.interval <= bucket.interval) {
            continue;
          }
          final ratio = candidate.interval / bucket.interval;
          final nearThreeHalves = ratio >= 1.45 && ratio <= 1.7;
          final nearDouble = ratio >= 1.95 && ratio <= 2.2;
          final nearTriple = ratio >= 2.9 && ratio <= 3.3;
          if (!nearThreeHalves && !nearDouble && !nearTriple) {
            continue;
          }
          final share = candidate.score / totalScore;
          final threshold = nearThreeHalves ? minShare * 0.8 : minShare;
          if (share >= threshold) {
            shouldSuppress = true;
            break;
          }
        }
      }

      if (shouldSuppress) {
        bucket.suppress(suppressionFactor);
      }
    }
  }

  HistogramSelection? select({bool preferLonger = true}) {
    final sorted = _sortedBuckets();
    if (sorted.isEmpty) {
      return null;
    }

    var primary = sorted.first;
    if (primary.suppressed) {
      final alternative = sorted.firstWhere(
        (bucket) => !bucket.suppressed,
        orElse: () => primary,
      );
      primary = alternative;
    }
    var selected = primary;

    final primaryBpm = 60.0 / primary.interval;
    if (preferLonger && sorted.length > 1) {
      for (final bucket in sorted.skip(1)) {
        if (bucket.suppressed) {
          continue;
        }
        final intervalRatio = bucket.interval / primary.interval;
        if (intervalRatio >= 1.45 && bucket.score >= primary.score * 0.55) {
          selected = bucket;
          break;
        }
        final bpm = 60.0 / bucket.interval;
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
