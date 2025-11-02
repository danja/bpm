import 'dart:math';

import 'package:bpm/src/algorithms/algorithm_utils.dart';
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
    final timeScale = signal.onsetTimeScale;
    final minSeparationSeconds =
        (60.0 / signal.context.maxBpm).clamp(0.15, 0.8) * 0.85;
    final minSeparationSamples =
        max(2, (minSeparationSeconds / timeScale).round());
    final peaks = _detectPeaks(
      smoothed,
      minSeparation: minSeparationSamples,
    );
    if (peaks.length < 8 && minSeparationSamples > 2) {
      final relaxedSeparation =
          max(2, (minSeparationSamples * 0.6).round());
      if (relaxedSeparation < minSeparationSamples) {
        final relaxedPeaks = _detectPeaks(
          smoothed,
          minSeparation: relaxedSeparation,
        );
        if (relaxedPeaks.length >= 2) {
          peaks
            ..clear()
            ..addAll(relaxedPeaks);
        }
      }
    }
    if (peaks.length < 2) {
      return null;
    }

    // Calculate inter-peak intervals in seconds
    // Onset envelope is computed with ~10ms hop, so timeScale is 0.01 seconds per sample
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

    final medianInterval = _median(trimmedIntervals);
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

    var effectiveInterval = selection.normalizedInterval;
    final originalInterval =
        selection.interval <= 0 ? effectiveInterval : selection.interval;
    final sources = List<String>.from(selection.sources);
    var adjustedToMedian = false;
    double? histogramPreferenceMultiplier;

    if (medianInterval > 0 && selection.normalizedInterval > 0) {
      final ratio = medianInterval / selection.normalizedInterval;
      if ((ratio >= 1.35 && ratio <= 1.7) ||
          (ratio >= 0.45 && ratio <= 0.7)) {
        effectiveInterval = medianInterval;
        if (!sources.contains('median_interval')) {
          sources.add('median_interval');
        }
        adjustedToMedian = true;
      }
    }

    final preferredInterval = _preferFasterHistogramInterval(
      selection,
      effectiveInterval,
    );
    if (preferredInterval != null &&
        (preferredInterval - effectiveInterval).abs() > 1e-4) {
      histogramPreferenceMultiplier =
          preferredInterval / (effectiveInterval == 0 ? 1 : effectiveInterval);
      effectiveInterval = preferredInterval;
      if (!sources.contains('histogram_fast_preference')) {
        sources.add('histogram_fast_preference');
      }
    }

    var bpm = 60.0 / effectiveInterval;
    final rangeAdjustment = bpm.isFinite && bpm > 0
        ? AlgorithmUtils.coerceToRange(
            bpm,
            minBpm: signal.context.minBpm,
            maxBpm: signal.context.maxBpm,
          )
        : null;

    var rangeAdjusted = false;
    if (rangeAdjustment != null &&
        rangeAdjustment.bpm > 0 &&
        ((rangeAdjustment.multiplier - 1.0).abs() > 0.01 ||
            rangeAdjustment.clamped)) {
      bpm = rangeAdjustment.bpm;
      effectiveInterval = 60.0 / bpm;
      rangeAdjusted = true;
      if (!sources.contains('range_adjust')) {
        sources.add('range_adjust');
      }
    }

    final rangeMultiplier =
        originalInterval == 0 ? 1.0 : effectiveInterval / originalInterval;
    var rangeClamped =
        rangeAdjusted || (rangeAdjustment?.clamped ?? false) || rangeMultiplier.abs() > 1.05;
    var adjustedRangeMultiplier = rangeMultiplier;
    if (histogramPreferenceMultiplier != null) {
      adjustedRangeMultiplier *= histogramPreferenceMultiplier.abs();
    }

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
      'medianInterval': medianInterval,
      'representativeInterval': representativeInterval,
      'maxInterval': trimmedIntervals.reduce(max),
      'candidateScores': selection.scoreMap,
      'clusterConsistency': clusterConsistency,
      'clusterStrength': clusterStrength,
      'totalScore': selection.totalScore,
      'baseBpm': 60.0 / selection.interval,
      'supporterCount': selection.supporters,
      'rangeMultiplier': adjustedRangeMultiplier,
      'rangeClamped': rangeClamped,
      'sources': sources,
      'suppressedBuckets': selection.suppressedBpms,
      'medianAdjustment': adjustedToMedian,
      'rangeAdjustment': rangeAdjusted,
    };
    if (histogramPreferenceMultiplier != null) {
      metadata['histogramPreferenceMultiplier'] =
          histogramPreferenceMultiplier;
      metadata['histogramPreferenceApplied'] = true;
    }

    return BpmReading(
      algorithmId: id,
      algorithmName: label,
      bpm: bpm,
      confidence: confidence,
      timestamp: DateTime.now().toUtc(),
      metadata: metadata,
    );
  }

  List<int> _detectPeaks(
    List<double> envelope, {
    required int minSeparation,
  }) {
    final peaks = <int>[];
    final avg = envelope.reduce((a, b) => a + b) / envelope.length;
    final variance = envelope.fold<double>(0, (sum, value) => sum + pow(value - avg, 2));
    final std = sqrt((variance / envelope.length).clamp(0.0, double.infinity));
    final threshold = (avg + std * 0.3).clamp(0.15, 0.6);
    int? lastPeak;

    for (var i = 2; i < envelope.length - 2; i++) {
      final current = envelope[i];
      if (current > threshold &&
          current >= envelope[i - 1] &&
          current >= envelope[i + 1] &&
          current > envelope[i - 2] &&
          current > envelope[i + 2]) {
        if (lastPeak != null && (i - lastPeak) < minSeparation) {
          if (current > envelope[lastPeak]) {
            peaks.removeLast();
            peaks.add(i);
            lastPeak = i;
          }
          continue;
        }
        peaks.add(i);
        lastPeak = i;
      }
    }

    if (peaks.length < 2) {
      final indexed = List.generate(envelope.length, (index) => (index, envelope[index]))
        ..sort((a, b) => b.$2.compareTo(a.$2));
      final fallback = <int>[];
      for (final entry in indexed) {
        if (fallback.any((existing) => (entry.$1 - existing).abs() < minSeparation)) {
          continue;
        }
        fallback.add(entry.$1);
        if (fallback.length >= 4) {
          break;
        }
      }
      fallback.sort();
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

    final baseList = candidates.isEmpty ? filtered : candidates;
    final normalized = <double>[];
    for (final value in baseList) {
      var adjusted = value;
      var guard = 0;
      while (adjusted < minInterval * 0.98 && guard < 4) {
        adjusted *= 2;
        guard++;
      }
      while (adjusted > maxInterval * 1.02 && guard > -4) {
        adjusted /= 2;
        guard--;
      }
      normalized.add(adjusted);
    }

    return normalized;
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
        weight: baseWeight * 0.05,
        supporters: 0,
        source: 'triple_interval',
      );
      histogram.accumulate(
        interval: interval / 2,
        weight: baseWeight * 0.05,
        supporters: 0,
        source: 'half_interval',
      );

      for (final adjustment in _onsetHarmonicAdjustments) {
        final scaledInterval = interval * adjustment.scale;
        if (scaledInterval <= 0) {
          continue;
        }
        final scaledBpm = 60.0 / scaledInterval;
        if (scaledBpm.isNaN ||
            scaledBpm.isInfinite ||
            scaledBpm < context.minBpm * 0.8 ||
            scaledBpm > context.maxBpm * 1.25) {
          continue;
        }
        histogram.accumulate(
          interval: scaledInterval,
          weight: baseWeight * adjustment.weight,
          supporters: 0,
          source: adjustment.label,
        );
      }
    }

    final refinement = AlgorithmUtils.refineFromIntervals(
      intervals: intervals,
      minBpm: context.minBpm,
      maxBpm: context.maxBpm,
    );
    if (refinement != null && refinement.consistency >= 0.35) {
      final refinedInterval = 60.0 / refinement.bpm;
      histogram.accumulate(
        interval: refinedInterval,
        weight: refinement.totalWeight *
            (0.35 + 0.25 * refinement.consistency),
        supporters: refinement.clusterSize,
        source: 'refined_interval',
      );
    }

    histogram.applyLengthBoost();
    histogram.suppressShorterHarmonics(minShare: 0.22);
    histogram.suppressLongerHarmonics(minShare: 0.24);

    return histogram.select();
  }
}

class _IntervalAdjustment {
  const _IntervalAdjustment({
    required this.scale,
    required this.weight,
    required this.label,
  });

  final double scale;
  final double weight;
  final String label;
}

double? _preferFasterHistogramInterval(
  HistogramSelection selection,
  double currentInterval,
) {
  if (currentInterval <= 0) {
    return null;
  }
  final currentBpm = 60.0 / currentInterval;
  final currentScore =
          _histogramScoreForBpm(selection, currentBpm) ?? selection.score;
  var bestBpm = currentBpm;
  var bestScoreRatio = 0.0;
  var found = false;

  selection.scoreMap.forEach((candidateBpm, score) {
    if (candidateBpm <= currentBpm) {
      return;
    }
    final ratio = candidateBpm / currentBpm;
    if (ratio < 1.04 || ratio > 1.28) {
      return;
    }
    final relative = currentScore == 0 ? 0.0 : score / currentScore;
    final absolute =
        selection.totalScore == 0 ? 0.0 : score / selection.totalScore;
    if (relative < 0.05 && absolute < 0.05) {
      return;
    }
    final ratioAffinity =
        (1.0 - ((ratio - 1.0).abs() / 0.18)).clamp(0.0, 1.0);
    final scoreRatio =
        relative * 0.5 + absolute * 0.2 + ratioAffinity * 0.3;
    if (!found ||
        scoreRatio > bestScoreRatio + 1e-6 ||
        ((scoreRatio - bestScoreRatio).abs() <= 1e-6 &&
            (candidateBpm - currentBpm) < (bestBpm - currentBpm))) {
      found = true;
      bestScoreRatio = scoreRatio;
      bestBpm = candidateBpm;
    }
  });

  if (!found || (bestBpm - currentBpm).abs() < 0.25) {
    return null;
  }
  return 60.0 / bestBpm;
}

double? _histogramScoreForBpm(HistogramSelection selection, double bpm) {
  double? bestScore;
  var bestDiff = double.infinity;
  selection.scoreMap.forEach((candidateBpm, score) {
    final diff = (candidateBpm - bpm).abs();
    if (diff < bestDiff && diff <= 1.5) {
      bestScore = score;
      bestDiff = diff;
    }
  });
  return bestScore;
}

const List<_IntervalAdjustment> _onsetHarmonicAdjustments = [
  _IntervalAdjustment(
    scale: 2 / 3,
    weight: 0.07,
    label: 'interval_two_thirds',
  ),
  _IntervalAdjustment(
    scale: 0.75,
    weight: 0.06,
    label: 'interval_three_fourths',
  ),
  _IntervalAdjustment(
    scale: 0.8,
    weight: 0.055,
    label: 'interval_four_fifths',
  ),
  _IntervalAdjustment(
    scale: 7 / 8,
    weight: 0.6,
    label: 'interval_seven_eighths',
  ),
  _IntervalAdjustment(
    scale: 15 / 16,
    weight: 0.55,
    label: 'interval_fifteen_sixteenths',
  ),
  _IntervalAdjustment(
    scale: 6 / 7,
    weight: 0.48,
    label: 'interval_six_sevenths',
  ),
  _IntervalAdjustment(
    scale: 4 / 3,
    weight: 0.045,
    label: 'interval_four_thirds',
  ),
  _IntervalAdjustment(
    scale: 5 / 4,
    weight: 0.04,
    label: 'interval_five_fourths',
  ),
  _IntervalAdjustment(
    scale: 3 / 2,
    weight: 0.035,
    label: 'interval_three_halves',
  ),
];
