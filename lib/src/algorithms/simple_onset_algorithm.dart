import 'dart:math';

import 'package:bpm/src/algorithms/bpm_detection_algorithm.dart';
import 'package:bpm/src/algorithms/detection_context.dart';
import 'package:bpm/src/models/bpm_models.dart';

/// Energy-based transient detection translated into BPM.
class SimpleOnsetAlgorithm extends BpmDetectionAlgorithm {
  SimpleOnsetAlgorithm({this.frameMillis = 30}); // Smaller frames for better transient detection

  final int frameMillis;

  @override
  String get id => 'simple_onset';

  @override
  String get label => 'Onset Energy';

  @override
  Duration get preferredWindow => const Duration(seconds: 6);

  @override
  Future<BpmReading?> analyze({
    required List<AudioFrame> window,
    required DetectionContext context,
  }) async {
    if (window.isEmpty) {
      return null;
    }

    final flattened = window.expand((frame) => frame.samples).toList();
    if (flattened.isEmpty) {
      return null;
    }

    final frameSize =
        max(1, (context.sampleRate * (frameMillis / 1000)).round());
    final envelope = _shortTimeEnergy(flattened, frameSize);
    if (envelope.length < 4) {
      return null;
    }

    final peaks = _detectPeaks(envelope);
    if (peaks.length < 2) {
      return null;
    }

    final intervals = <double>[];
    for (var i = 1; i < peaks.length; i++) {
      intervals.add((peaks[i] - peaks[i - 1]) * frameMillis.toDouble());
    }
    if (intervals.isEmpty) {
      return null;
    }

    final medianIntervalMs = _median(intervals);
    if (medianIntervalMs == 0) {
      return null;
    }

    var bpm = 60000 / medianIntervalMs;

    // Handle harmonic detection - if BPM is too high, try dividing by 2, 3, or 4
    if (bpm > context.maxBpm) {
      for (var divisor in [2, 3, 4]) {
        final adjusted = bpm / divisor;
        if (adjusted >= context.minBpm && adjusted <= context.maxBpm) {
          bpm = adjusted;
          break;
        }
      }
    }

    if (bpm < context.minBpm || bpm > context.maxBpm) {
      return null;
    }

    final variance = _variance(intervals, medianIntervalMs);
    final confidence = (1 / (1 + variance / 500)).clamp(0.0, 1.0);

    return BpmReading(
      algorithmId: id,
      algorithmName: label,
      bpm: bpm,
      confidence: confidence,
      timestamp: DateTime.now().toUtc(),
      metadata: {'intervalVariance': variance},
    );
  }

  List<double> _shortTimeEnergy(List<double> samples, int frameSize) {
    final energies = <double>[];
    for (var i = 0; i < samples.length; i += frameSize) {
      final slice = samples.sublist(
        i,
        min(i + frameSize, samples.length),
      );
      final energy =
          slice.fold<double>(0, (sum, sample) => sum + sample * sample);
      energies.add(energy);
    }
    return _normalize(energies);
  }

  List<int> _detectPeaks(List<double> envelope) {
    final peaks = <int>[];
    // Very low threshold for maximum sensitivity
    const threshold = 0.25; // Was 0.6, then 0.4

    for (var i = 1; i < envelope.length - 1; i++) {
      if (envelope[i] > envelope[i - 1] &&
          envelope[i] > envelope[i + 1] &&
          envelope[i] > threshold) {
        peaks.add(i);
      }
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
}
