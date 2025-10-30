import 'dart:collection';
import 'dart:math' as math;

import 'package:bpm/src/core/consensus_interface.dart';
import 'package:bpm/src/models/bpm_models.dart';

/// Enhanced consensus engine with temporal tracking and outlier rejection.
///
/// Features:
/// - Multi-reading history (tracks last N consensus values)
/// - Progressive convergence (adapts smoothing based on stability)
/// - Outlier detection using MAD (Median Absolute Deviation)
/// - Trend detection from historical patterns
/// - Confidence boosting for recurring values
class EnhancedConsensusEngine implements ConsensusInterface {
  EnhancedConsensusEngine({
    this.historySize = 15,
    this.minConfidence = 0.05,
    this.outlierThresholdMAD = 2.5,
    this.convergenceThreshold = 2.0,
    this.minSmoothingFactor = 0.15,
    this.maxSmoothingFactor = 0.5,
    this.clusterToleranceBpm = 1.5,
  });

  final int historySize;
  final double minConfidence;
  final double outlierThresholdMAD; // Threshold in MAD units
  final double convergenceThreshold; // BPM difference for "converged" state
  final double minSmoothingFactor; // When stable
  final double maxSmoothingFactor; // When changing
  final double clusterToleranceBpm;

  // Temporal state
  final _history = Queue<double>();
  double? _currentConsensus;
  double _currentSmoothingFactor = 0.3;
  int _stableCount = 0;

  @override
  ConsensusResult? combine(List<BpmReading> readings) {
    if (readings.isEmpty) {
      return _fallback();
    }

    // Step 1: Filter by minimum confidence
    final eligible = readings
        .where((r) => r.confidence >= minConfidence)
        .toList();

    if (eligible.isEmpty) {
      return _fallback();
    }

    // Step 2: Normalize octave errors against historical consensus
    final normalized = _normalizeTempos(eligible);

    // Step 3: Detect and reject outliers using MAD
    final cleaned = _rejectOutliers(normalized);

    if (cleaned.isEmpty) {
      return _fallback();
    }

    // Step 4: Calculate weighted consensus from current readings
    final weights = _calculateWeights(cleaned);
    final rawConsensus = _weightedMean(cleaned, weights);

    // Step 5: Check against historical trend
    final trendAdjusted = _adjustForTrend(rawConsensus);

    // Step 6: Apply adaptive smoothing
    final smoothed = _adaptiveSmooth(trendAdjusted);

    // Step 7: Update history
    _updateHistory(smoothed);

    // Step 8: Calculate confidence based on agreement and stability
    final confidence = _calculateConfidence(cleaned, weights, smoothed);

    _currentConsensus = smoothed;

    return ConsensusResult(
      bpm: smoothed,
      confidence: confidence,
      weights: weights,
    );
  }

  /// Reset the consensus state (e.g., when starting new analysis)
  @override
  void reset() {
    _history.clear();
    _currentConsensus = null;
    _currentSmoothingFactor = 0.3;
    _stableCount = 0;
  }

  ConsensusResult? _fallback() {
    if (_currentConsensus == null) {
      return null;
    }
    return ConsensusResult(
      bpm: _currentConsensus!,
      confidence: 0.3, // Reduced confidence for fallback
      weights: const {},
    );
  }

  List<BpmReading> _normalizeTempos(List<BpmReading> readings) {
    if (_currentConsensus == null) {
      return readings;
    }

    final result = <BpmReading>[];
    for (final reading in readings) {
      var bpm = reading.bpm;
      final ratio = bpm / _currentConsensus!;

      // Detect octave errors (half or double tempo)
      if ((ratio - 0.5).abs() < 0.05) {
        bpm *= 2; // Was detecting half tempo
      } else if ((ratio - 2.0).abs() < 0.05) {
        bpm /= 2; // Was detecting double tempo
      } else if ((ratio - 0.33).abs() < 0.05) {
        bpm *= 3; // Was detecting third tempo
      } else if ((ratio - 3.0).abs() < 0.05) {
        bpm /= 3; // Was detecting triple tempo
      }

      result.add(BpmReading(
        algorithmId: reading.algorithmId,
        algorithmName: reading.algorithmName,
        bpm: bpm,
        confidence: reading.confidence,
        timestamp: reading.timestamp,
        metadata: reading.metadata,
      ));
    }

    return result;
  }

  /// Reject outliers using Median Absolute Deviation (MAD)
  List<BpmReading> _rejectOutliers(List<BpmReading> readings) {
    if (readings.length < 3) {
      return readings; // Need at least 3 for statistical outlier detection
    }

    // Calculate median
    final bpms = readings.map((r) => r.bpm).toList()..sort();
    final median = _calculateMedian(bpms);

    // Calculate MAD (Median Absolute Deviation)
    final deviations = bpms.map((bpm) => (bpm - median).abs()).toList()..sort();
    final mad = _calculateMedian(deviations);

    if (mad < 0.1) {
      // All values very close, no outliers
      return readings;
    }

    // Reject readings beyond threshold MAD units
    final result = <BpmReading>[];
    for (final reading in readings) {
      final madScore = (reading.bpm - median).abs() / mad;
      if (madScore <= outlierThresholdMAD) {
        result.add(reading);
      }
    }

    return result.isNotEmpty ? result : readings; // Fallback if all rejected
  }

  double _calculateMedian(List<double> sorted) {
    if (sorted.isEmpty) return 0.0;
    final mid = sorted.length ~/ 2;
    if (sorted.length.isOdd) {
      return sorted[mid];
    }
    return (sorted[mid - 1] + sorted[mid]) / 2;
  }

  Map<String, double> _calculateWeights(List<BpmReading> readings) {
    final weights = <String, double>{};

    for (final reading in readings) {
      var weight = reading.confidence;

      // Heuristic bonuses based on algorithm type
      switch (reading.algorithmId) {
        case 'wavelet_energy':
          weight += 0.1;
          break;
        case 'autocorrelation':
          weight += 0.08; // Increased from 0.02
          break;
        case 'fft_spectrum':
          weight += 0.05;
          break;
        case 'simple_onset':
          weight += 0.03;
          break;
      }

      // Boost weight if value appears in history
      if (_history.isNotEmpty) {
        final historicalMatch = _history.any((h) =>
            (reading.bpm - h).abs() < clusterToleranceBpm);
        if (historicalMatch) {
          weight *= 1.3; // 30% bonus for recurring values
        }
      }

      weights[reading.algorithmId] = weight.clamp(0.0, 1.5);
    }

    return weights;
  }

  double _weightedMean(
    List<BpmReading> readings,
    Map<String, double> weights,
  ) {
    var total = 0.0;
    var weightSum = 0.0;

    for (final reading in readings) {
      final weight = weights[reading.algorithmId] ?? 0.0;
      total += reading.bpm * weight;
      weightSum += weight;
    }

    return weightSum > 0 ? total / weightSum : readings.first.bpm;
  }

  /// Adjust raw consensus based on historical trend
  double _adjustForTrend(double raw) {
    if (_history.length < 5) {
      return raw; // Not enough history for trend analysis
    }

    // Find mode (most common value) in recent history
    final histogram = <int, int>{}; // BPM bucket -> count
    for (final bpm in _history) {
      final bucket = bpm.round();
      histogram[bucket] = (histogram[bucket] ?? 0) + 1;
    }

    // Find most frequent bucket
    var modeBucket = histogram.keys.first;
    var maxCount = histogram[modeBucket]!;
    for (final entry in histogram.entries) {
      if (entry.value > maxCount) {
        modeBucket = entry.key;
        maxCount = entry.value;
      }
    }

    final mode = modeBucket.toDouble();
    final modeRatio = maxCount / _history.length;

    // If mode is strong (>40% of history), pull towards it
    if (modeRatio > 0.4) {
      final pull = 0.3 * modeRatio; // Up to 30% pull
      return raw * (1 - pull) + mode * pull;
    }

    return raw;
  }

  /// Apply adaptive smoothing - more smoothing when stable, less when changing
  double _adaptiveSmooth(double current) {
    if (_currentConsensus == null) {
      return current;
    }

    final deviation = (current - _currentConsensus!).abs();

    // Adjust smoothing factor based on stability
    if (deviation < convergenceThreshold) {
      _stableCount++;
      // Gradually increase smoothing when stable (converge)
      _currentSmoothingFactor = math.max(
        minSmoothingFactor,
        _currentSmoothingFactor * 0.95,
      );
    } else {
      _stableCount = 0;
      // Increase responsiveness when changing
      _currentSmoothingFactor = math.min(
        maxSmoothingFactor,
        _currentSmoothingFactor * 1.1,
      );
    }

    // Apply exponential smoothing
    return _currentConsensus! +
        _currentSmoothingFactor * (current - _currentConsensus!);
  }

  void _updateHistory(double bpm) {
    _history.add(bpm);
    while (_history.length > historySize) {
      _history.removeFirst();
    }
  }

  double _calculateConfidence(
    List<BpmReading> readings,
    Map<String, double> weights,
    double consensus,
  ) {
    // Base confidence from weights
    var confidence = weights.values.fold<double>(0.0, (sum, w) => sum + w);
    confidence = confidence.clamp(0.0, 1.0);

    // Boost confidence based on agreement
    final deviations = readings.map((r) => (r.bpm - consensus).abs());
    final avgDeviation = deviations.fold<double>(0.0, (sum, d) => sum + d) /
        readings.length;
    if (avgDeviation < 2.0) {
      confidence *= 1.2; // Tight agreement
    } else if (avgDeviation > 5.0) {
      confidence *= 0.8; // Poor agreement
    }

    // Boost confidence when stable
    if (_stableCount > 5) {
      confidence *= 1.15;
    }

    return confidence.clamp(0.0, 1.0);
  }
}
