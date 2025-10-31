import 'dart:math';

import 'package:bpm/src/algorithms/bpm_detection_algorithm.dart';
import 'package:bpm/src/algorithms/detection_context.dart';
import 'package:bpm/src/algorithms/interval_histogram.dart';
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
      'suppressedBuckets': selection.suppressedBpms,
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

  HistogramSelection? _selectTempoCandidate({
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

    final startIndex =
        (sorted.length * 0.4).floor().clamp(0, sorted.length - 1);
    final dominantIntervals = sorted.sublist(startIndex);

    final histogram = IntervalHistogram(
      context: context,
      binSize: binSize,
    );

    for (final interval in dominantIntervals) {
      final baseWeight = interval * interval;
      histogram.accumulate(
        interval: interval,
        weight: baseWeight,
        supporters: 1,
        source: 'interval',
      );
      histogram.accumulate(
        interval: interval * 2,
        weight: baseWeight * 0.18,
        supporters: 0,
        source: 'double_interval',
      );
      histogram.accumulate(
        interval: interval * 3,
        weight: baseWeight * 0.1,
        supporters: 0,
        source: 'triple_interval',
      );
      histogram.accumulate(
        interval: interval / 2,
        weight: baseWeight * 0.05,
        supporters: 0,
        source: 'half_interval',
      );
    }

    histogram.applyLengthBoost();
    histogram.suppressShorterHarmonics(minShare: 0.22);

    return histogram.select();
  }
}
