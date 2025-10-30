import 'dart:math';

import 'package:bpm/src/algorithms/bpm_detection_algorithm.dart';
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

    final medianIntervalSec = _median(intervals);
    if (medianIntervalSec == 0) {
      return null;
    }

    var bpm = 60.0 / medianIntervalSec;

    // Handle harmonic detection - if BPM is too high, try dividing by 2, 3, or 4
    if (bpm > signal.context.maxBpm) {
      for (var divisor in [2, 3, 4]) {
        final adjusted = bpm / divisor;
        if (adjusted >= signal.context.minBpm && adjusted <= signal.context.maxBpm) {
          bpm = adjusted;
          break;
        }
      }
    }

    if (bpm < signal.context.minBpm || bpm > signal.context.maxBpm) {
      return null;
    }

    // Calculate variance of intervals (now in seconds)
    final variance = _variance(intervals, medianIntervalSec);
    // Adjust confidence calculation for seconds (variance will be smaller)
    final confidence = (1 / (1 + variance / 0.5)).clamp(0.0, 1.0);

    return BpmReading(
      algorithmId: id,
      algorithmName: label,
      bpm: bpm,
      confidence: confidence,
      timestamp: DateTime.now().toUtc(),
      metadata: {
        'intervalVariance': variance,
        'peakCount': peaks.length,
      },
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
}
