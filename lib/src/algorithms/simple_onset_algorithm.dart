import 'dart:math';

import 'package:bpm/src/algorithms/bpm_detection_algorithm.dart';
import 'package:bpm/src/algorithms/algorithm_utils.dart';
import 'package:bpm/src/algorithms/detection_context.dart';
import 'package:bpm/src/dsp/preprocessing_pipeline.dart';
import 'package:bpm/src/models/bpm_models.dart';

/// Energy-based transient detection translated into BPM.
///
/// Now uses pre-computed onset envelope from preprocessing pipeline,
/// eliminating redundant energy calculations and improving performance.
class SimpleOnsetAlgorithm extends BpmDetectionAlgorithm {
  SimpleOnsetAlgorithm();

  @override
  String get id => 'simple_onset';

  @override
  String get label => 'Onset Energy';

  @override
  Duration get preferredWindow => const Duration(seconds: 6);

  @override
  Future<BpmReading?> analyze({
    required PreprocessedSignal signal,
  }) async {
    // Use pre-computed onset envelope from preprocessing
    final envelope = signal.onsetEnvelope;
    if (envelope.length < 4) {
      return null;
    }

    // Smooth the envelope
    final smoothed = _smooth(envelope, max(3, envelope.length ~/ 60));

    // Detect peaks in the smoothed envelope
    final peaks = _detectPeaks(smoothed);
    if (peaks.length < 2) {
      return null;
    }

    // Calculate inter-peak intervals in seconds
    // Onset envelope is computed with ~10ms hop, so timeScale is 0.01 seconds per sample
    final timeScale = signal.onsetTimeScale;
    final intervals = <double>[];
    for (var i = 1; i < peaks.length; i++) {
      intervals.add((peaks[i] - peaks[i - 1]) * timeScale);
    }
    if (intervals.isEmpty) {
      return null;
    }

    final trimmedIntervals = _filterIntervals(
      intervals,
      minBpm: signal.context.minBpm,
      maxBpm: signal.context.maxBpm,
    );
    if (trimmedIntervals.isEmpty) {
      return null;
    }

    final representativeInterval = _representativeInterval(trimmedIntervals);
    if (representativeInterval <= 0) {
      return null;
    }

    final selection = _selectTempoCandidate(
      intervals: trimmedIntervals,
      context: signal.context,
    );
    if (selection == null || selection.normalizedInterval <= 0) {
      return null;
    }

    final bpm = 60.0 / selection.normalizedInterval;
    final effectiveInterval = selection.normalizedInterval;

    // Calculate variance of intervals (now in seconds)
    final variance = _variance(trimmedIntervals, effectiveInterval);
    final baseConfidence = (1 / (1 + variance / 0.5)).clamp(0.0, 1.0);
    final clusterStrength =
        (selection.score / (selection.totalScore + 1e-6)).clamp(0.0, 1.0);
    final supporterRatio =
        selection.supporters / trimmedIntervals.length.toDouble();
    final clusterConsistency =
        (0.7 * clusterStrength + 0.3 * supporterRatio.clamp(0.0, 1.0))
            .clamp(0.1, 1.0);

    final confidence =
        (baseConfidence * clusterConsistency).clamp(0.0, 1.0);

    final metadata = <String, Object?>{
      'intervalVariance': variance,
      'peakCount': peaks.length,
      'effectiveInterval': effectiveInterval,
      'candidateScores': selection.scoreMap,
      'clusterConsistency': clusterConsistency,
      'clusterStrength': clusterStrength,
      'totalScore': selection.totalScore,
      'baseBpm': 60.0 / selection.interval,
      'supporterCount': selection.supporters,
      'rangeMultiplier': selection.multiplier,
      'rangeClamped': selection.multiplier.abs() > 1.05,
      'sources': selection.sources,
    };

    return BpmReading(
      algorithmId: id,
      algorithmName: label,
      bpm: bpm,
      confidence: confidence,
      timestamp: DateTime.now().toUtc(),
      metadata: metadata,
    );
  }

  List<int> _detectPeaks(List<double> envelope) {
    final peaks = <int>[];
    final avg = envelope.reduce((a, b) => a + b) / envelope.length;
    final variance = envelope.fold<double>(0, (sum, value) => sum + pow(value - avg, 2));
    final std = sqrt((variance / envelope.length).clamp(0.0, double.infinity));
    final threshold = (avg + std * 0.3).clamp(0.15, 0.6);

    for (var i = 2; i < envelope.length - 2; i++) {
      final current = envelope[i];
      if (current > threshold &&
          current >= envelope[i - 1] &&
          current >= envelope[i + 1] &&
          current > envelope[i - 2] &&
          current > envelope[i + 2]) {
        peaks.add(i);
      }
    }

    if (peaks.length < 2) {
      final indexed = List.generate(envelope.length, (index) => (index, envelope[index]))
        ..sort((a, b) => b.$2.compareTo(a.$2));
      final fallback = indexed.take(4).map((entry) => entry.$1).toList()..sort();
      return fallback.length >= 2 ? fallback : peaks;
    }
    return peaks;
  }

  List<double> _normalize(List<double> values) {
    final maxValue = values.reduce(max);
    if (maxValue == 0) {
      return List.filled(values.length, 0);
    }
    return values.map((value) => value / maxValue).toList();
  }

  double _variance(List<double> values, double center) {
    if (values.length < 2) return 0;
    final sumSquares =
        values.fold(0.0, (sum, value) => sum + pow(value - center, 2));
    return sumSquares / (values.length - 1);
  }

  double _median(List<double> values) {
    final sorted = List<double>.from(values)..sort();
    final mid = sorted.length ~/ 2;
    if (sorted.length.isOdd) {
      return sorted[mid];
    }
    return (sorted[mid - 1] + sorted[mid]) / 2;
  }

  List<double> _smooth(List<double> values, int window) {
    if (values.isEmpty || window <= 1) {
      return List<double>.from(values);
    }
    final size = min(window, values.length);
    final smoothed = List<double>.filled(values.length, 0);
    var sum = 0.0;
    for (var i = 0; i < values.length; i++) {
      sum += values[i];
      if (i >= size) {
        sum -= values[i - size];
      }
      final currentWindow = min(i + 1, size);
      smoothed[i] = sum / currentWindow;
    }
    return _normalize(smoothed);
  }

  List<double> _filterIntervals(
    List<double> intervals, {
    required double minBpm,
    required double maxBpm,
  }) {
    final minInterval = 60.0 / maxBpm;
    final maxInterval = 60.0 / minBpm;

    var filtered = intervals
        .where((value) =>
            value > 0 &&
            value >= minInterval * 0.5 &&
            value <= maxInterval * 1.5)
        .toList();

    if (filtered.length < 3) {
      filtered = intervals.where((value) => value > 0).toList();
    }

    if (filtered.isEmpty) {
      return const <double>[];
    }

    final median = _median(filtered);
    final deviations =
        filtered.map((value) => (value - median).abs()).toList();
    final mad = _median(deviations);
    if (mad == 0) {
      final tolerance = median * 0.12;
      final candidates = filtered
          .where((value) => (value - median).abs() <= tolerance)
          .toList();
      return candidates.isEmpty ? filtered : candidates;
    }

    final threshold = mad * 3.0;
    final candidates = <double>[];
    for (var i = 0; i < filtered.length; i++) {
      final deviation = deviations[i];
      if (deviation <= threshold) {
        candidates.add(filtered[i]);
      }
    }

    return candidates.isEmpty ? filtered : candidates;
  }

  double _representativeInterval(List<double> intervals) {
    if (intervals.isEmpty) {
      return 0;
    }
    if (intervals.length == 1) {
      return intervals.first;
    }
    final sorted = List<double>.from(intervals)..sort();
    final startIndex =
        (sorted.length * 0.35).floor().clamp(0, sorted.length - 1);
    final endIndex =
        (sorted.length * 0.9).ceil().clamp(startIndex + 1, sorted.length);
    final slice = sorted.sublist(startIndex, endIndex);
    return _median(slice);
  }

_TempoSelection? _selectTempoCandidate({
  required List<double> intervals,
  required DetectionContext context,
}) {
  const binSize = 0.02; // 20ms histogram bins
  if (intervals.isEmpty) {
    return null;
  }

  final sorted = List<double>.from(intervals.where((value) => value > 0))
    ..sort();
  if (sorted.isEmpty) {
    return null;
  }

  final startIndex = (sorted.length * 0.4).floor().clamp(0, sorted.length - 1);
  final dominantIntervals = sorted.sublist(startIndex);

  final buckets = <double, _HistogramBucket>{};

  void accumulate(
    double rawInterval,
    double weight,
    int supporters,
    String source,
  ) {
    if (rawInterval <= 0 || weight <= 0) return;
    final normalized = _normalizeInterval(rawInterval, context);
    if (normalized <= 0) return;
    final bin = (normalized / binSize).round() * binSize;
    final bucket =
        buckets.putIfAbsent(bin, () => _HistogramBucket(interval: bin));
    bucket.add(weight: weight, supporters: supporters, source: source);
  }

  for (final interval in dominantIntervals) {
    final baseWeight = interval * interval;
    accumulate(interval, baseWeight, 1, 'interval');
    accumulate(interval * 2, baseWeight * 0.25, 0, 'double_interval');
    accumulate(interval * 3, baseWeight * 0.15, 0, 'triple_interval');
    accumulate(interval / 2, baseWeight * 0.1, 0, 'half_interval');
  }

  if (buckets.isEmpty) {
    return null;
  }

  final bucketList = buckets.values.toList()
    ..sort((a, b) {
      final scoreCompare = b.score.compareTo(a.score);
      if (scoreCompare != 0) {
        return scoreCompare;
      }
      return a.interval.compareTo(b.interval);
    });

  final primary = bucketList.first;
  var selected = primary;

  for (final bucket in bucketList) {
    final bpm = 60.0 / bucket.interval;
    final primaryBpm = 60.0 / primary.interval;
    if (bpm <= primaryBpm / 1.6 &&
        bucket.score >= primary.score * 0.6) {
      selected = bucket;
      break;
    }
  }

  final normalizedInterval = _normalizeInterval(selected.interval, context);
  if (normalizedInterval <= 0) {
    return null;
  }

  final multiplier = normalizedInterval / selected.interval;
  final scoreMap = <double, double>{
    for (final bucket in bucketList) 60.0 / bucket.interval: bucket.score,
  };
  final totalScore =
      bucketList.fold<double>(0, (sum, bucket) => sum + bucket.score);

  return _TempoSelection(
    interval: selected.interval,
    normalizedInterval: normalizedInterval,
    score: selected.score,
    totalScore: totalScore,
    supporters: selected.count,
    scoreMap: scoreMap,
    multiplier: multiplier,
    sources: selected.sources.toList(),
  );
}

  double _normalizeInterval(double interval, DetectionContext context) {
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

class _TempoSelection {
  const _TempoSelection({
    required this.interval,
    required this.normalizedInterval,
    required this.score,
    required this.totalScore,
    required this.supporters,
    required this.scoreMap,
    required this.multiplier,
    required this.sources,
  });

  final double interval;
  final double normalizedInterval;
  final double score;
  final double totalScore;
  final int supporters;
  final Map<double, double> scoreMap;
  final double multiplier;
  final List<String> sources;
}

class _HistogramBucket {
  _HistogramBucket({required this.interval});

  final double interval;
  double weight = 0;
  int count = 0;
  final Set<String> sources = <String>{};

  void add({required double weight, required int supporters, required String source}) {
    this.weight += weight;
    count += supporters;
    sources.add(source);
  }

  double get score => weight * interval;
}
