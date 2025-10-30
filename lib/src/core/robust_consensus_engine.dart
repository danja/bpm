import 'dart:collection';
import 'dart:math' as math;

import 'package:bpm/src/algorithms/algorithm_utils.dart';
import 'package:bpm/src/core/consensus_interface.dart';
import 'package:bpm/src/models/bpm_models.dart';

/// Robust consensus engine with per-algorithm tracking and majority voting.
///
/// Strategy:
/// 1. Track each algorithm's reading history separately
/// 2. Reject outliers within each algorithm's own stream
/// 3. Find clusters of agreement across algorithms
/// 4. Use majority voting (largest cluster) for consensus
/// 5. Progressive convergence within winning cluster
class RobustConsensusEngine implements ConsensusInterface {
  RobustConsensusEngine({
    this.historySize = 10,
    this.minReadingsForOutlierDetection = 3,
    this.algorithmOutlierThreshold = 8.0, // BPM deviation for per-algorithm outlier
    this.clusterTolerance = 3.0, // BPM tolerance for clustering
    this.minClusterSize = 2, // Minimum algorithms to form valid cluster
    this.smoothingFactor = 0.25,
    this.consensusHistoryLimit = 20,
    this.minBpm = 50,
    this.maxBpm = 250,
  });

  final int historySize;
  final int minReadingsForOutlierDetection;
  final double algorithmOutlierThreshold;
  final double clusterTolerance;
  final int minClusterSize;
  final double smoothingFactor;
  final int consensusHistoryLimit;
  final double minBpm;
  final double maxBpm;

  // Per-algorithm history: algorithmId -> queue of BPM values
  final _algorithmHistories = <String, Queue<double>>{};

  // Current consensus value
  double? _currentConsensus;

  // Count of stable readings
  int _stableCount = 0;

  // History of consensus outputs for stability scoring
  final _consensusHistory = Queue<double>();

  @override
  ConsensusResult? combine(List<BpmReading> readings) {
    if (readings.isEmpty) {
      return _fallback();
    }

    // Step 0: Normalize octave errors against consensus
    final normalized = _normalizeOctaveErrors(readings);

    // Step 1: Update per-algorithm histories and filter outliers
    final cleanedReadings = <BpmReading>[];
    for (final reading in normalized) {
      final cleaned = _updateAndFilterAlgorithm(reading);
      if (cleaned != null) {
        cleanedReadings.add(cleaned);
      }
    }

    if (cleanedReadings.isEmpty) {
      return _fallback();
    }

    // Step 2: Find clusters of agreement
    final clusters = _findClusters(cleanedReadings);

    if (clusters.isEmpty) {
      return _fallback();
    }

    // Step 3: Select winning cluster (majority vote)
    final winningCluster = _selectWinningCluster(clusters);
    final totalWeightAll = cleanedReadings.fold<double>(
      0,
      (sum, reading) => sum + _readingWeight(reading),
    );

    // Step 4: Calculate consensus from winning cluster
    final rawConsensus = _calculateClusterMean(winningCluster);

    // Step 5: Apply smoothing
    final smoothed = _smooth(rawConsensus);

    // Step 6: Update state
    _currentConsensus = smoothed;
    _updateConsensusHistory(smoothed);

    // Check stability
    if (_currentConsensus != null &&
        (rawConsensus - _currentConsensus!).abs() < 2.0) {
      _stableCount++;
    } else {
      _stableCount = 0;
    }

    // Step 7: Calculate confidence
    final confidence = _calculateConfidence(
      winningCluster: winningCluster,
      totalReadings: cleanedReadings.length,
      totalReadingsWeight: totalWeightAll,
      rawConsensus: rawConsensus,
      smoothedConsensus: smoothed,
    );

    // Step 8: Build weights map for debugging
    final weights = <String, double>{};
    final clusterWeight = winningCluster.members.fold<double>(
      0,
      (sum, reading) => sum + _readingWeight(reading),
    );
    for (final reading in winningCluster.members) {
      final weight = _readingWeight(reading);
      weights[reading.algorithmId] = clusterWeight == 0
          ? 1.0 / winningCluster.members.length
          : (weight / clusterWeight);
    }

    return ConsensusResult(
      bpm: smoothed,
      confidence: confidence,
      weights: weights,
    );
  }

  /// Reset the consensus state
  @override
  void reset() {
    _algorithmHistories.clear();
    _currentConsensus = null;
    _stableCount = 0;
    _consensusHistory.clear();
  }

  /// Normalize octave errors against evolving reference (current consensus or median).
  List<BpmReading> _normalizeOctaveErrors(List<BpmReading> readings) {
    if (readings.isEmpty) {
      return readings;
    }

    var reference = _currentConsensus;
    if (reference == null || reference <= 0) {
      final bpms = readings.map((r) => r.bpm).toList();
      reference = _calculateMedian(bpms);
      if (reference <= 0) {
        reference = (minBpm + maxBpm) / 2;
      }
    }

    final normalized = <BpmReading>[];
    for (final reading in readings) {
      final adjustedBpm = AlgorithmUtils.normalizeToReference(
        reading.bpm,
        reference,
        minBpm: minBpm,
        maxBpm: maxBpm,
      );

      final metadata = Map<String, Object?>.from(reading.metadata);
      final factor =
          reading.bpm == 0 ? 1.0 : (adjustedBpm / reading.bpm).abs();
      if ((factor - 1.0).abs() > 0.05) {
        metadata['octaveNormalized'] = true;
        metadata['octaveFactor'] = adjustedBpm / reading.bpm;
      }

      normalized.add(
        BpmReading(
          algorithmId: reading.algorithmId,
          algorithmName: reading.algorithmName,
          bpm: adjustedBpm,
          confidence: reading.confidence,
          timestamp: reading.timestamp,
          metadata: metadata,
        ),
      );
    }

    return normalized;
  }

  /// Update algorithm history and filter outliers within that algorithm's stream
  BpmReading? _updateAndFilterAlgorithm(BpmReading reading) {
    final algorithmId = reading.algorithmId;

    // Get or create history for this algorithm
    final history = _algorithmHistories.putIfAbsent(
      algorithmId,
      () => Queue<double>(),
    );

    // Check if this reading is an outlier compared to this algorithm's own history
    if (history.length >= minReadingsForOutlierDetection) {
      final median = _calculateMedian(List<double>.from(history));
      final deviation = (reading.bpm - median).abs();

      if (deviation > algorithmOutlierThreshold) {
        // Outlier within this algorithm's stream - reject it
        return null;
      }
    }

    // Add to history
    history.add(reading.bpm);
    while (history.length > historySize) {
      history.removeFirst();
    }

    return reading;
  }

  /// Find clusters of readings that agree with each other
  List<_Cluster> _findClusters(List<BpmReading> readings) {
    if (readings.length < minClusterSize) {
      return [];
    }

    final clusters = <_Cluster>[];
    final used = <int>{};

    for (int i = 0; i < readings.length; i++) {
      if (used.contains(i)) continue;

      final anchor = readings[i];
      final members = <BpmReading>[anchor];
      used.add(i);

      // Find all readings within tolerance of anchor
      for (int j = i + 1; j < readings.length; j++) {
        if (used.contains(j)) continue;

        final candidate = readings[j];
        final deviation = (candidate.bpm - anchor.bpm).abs();

        if (deviation <= clusterTolerance) {
          members.add(candidate);
          used.add(j);
        }
      }

      // Only create cluster if it has enough members
      if (members.length >= minClusterSize) {
        clusters.add(_Cluster(members: members));
      }
    }

    return clusters;
  }

  /// Select the winning cluster using majority vote
  _Cluster _selectWinningCluster(List<_Cluster> clusters) {
    clusters.sort((a, b) {
      final weightDiff = _clusterWeight(b).compareTo(_clusterWeight(a));
      if (weightDiff != 0) {
        return weightDiff;
      }
      return b.members.length.compareTo(a.members.length);
    });

    var bestCluster = clusters.first;

    if (_currentConsensus != null && clusters.length > 1) {
      final topWeight = _clusterWeight(clusters.first);
      final tiedClusters = clusters
          .where((cluster) => (_clusterWeight(cluster) - topWeight).abs() < 1e-6)
          .toList();

      if (tiedClusters.length > 1) {
        var minDist = double.infinity;
        for (final cluster in tiedClusters) {
          final mean = _calculateClusterMean(cluster);
          final dist = (mean - _currentConsensus!).abs();
          if (dist < minDist) {
            minDist = dist;
            bestCluster = cluster;
          }
        }
      }
    }

    return bestCluster;
  }

  double _calculateClusterMean(_Cluster cluster) {
    if (cluster.members.isEmpty) return 0.0;

    double weightedSum = 0;
    double totalWeight = 0;
    for (final reading in cluster.members) {
      final weight = _readingWeight(reading);
      weightedSum += reading.bpm * weight;
      totalWeight += weight;
    }

    if (totalWeight <= 0) {
      final sum = cluster.members.fold<double>(0.0, (sum, r) => sum + r.bpm);
      return sum / cluster.members.length;
    }

    return weightedSum / totalWeight;
  }

  double _calculateMedian(List<double> values) {
    if (values.isEmpty) return 0.0;

    final sorted = List<double>.from(values)..sort();
    final mid = sorted.length ~/ 2;

    if (sorted.length.isOdd) {
      return sorted[mid];
    }
    return (sorted[mid - 1] + sorted[mid]) / 2;
  }

  double _smooth(double current) {
    if (_currentConsensus == null) {
      return current;
    }

    // Adaptive smoothing based on stability
    var factor = smoothingFactor;
    if (_stableCount > 5) {
      factor = smoothingFactor * 0.5; // More smoothing when stable
    }

    return _currentConsensus! + factor * (current - _currentConsensus!);
  }

  void _updateConsensusHistory(double value) {
    _consensusHistory.add(value);
    while (_consensusHistory.length > consensusHistoryLimit) {
      _consensusHistory.removeFirst();
    }
  }

  double _calculateConfidence({
    required _Cluster winningCluster,
    required int totalReadings,
    required double totalReadingsWeight,
    required double rawConsensus,
    required double smoothedConsensus,
  }) {
    if (totalReadings <= 0) {
      return 0.0;
    }

    final clusterWeight = _clusterWeight(winningCluster);
    final majorityScore = totalReadingsWeight <= 0
        ? winningCluster.members.length / totalReadings.toDouble()
        : (clusterWeight / totalReadingsWeight).clamp(0.0, 1.0);

    final clusterMean = _calculateClusterMean(winningCluster);
    double variance = 0;
    double weightSum = 0;
    double consistencySum = 0;
    double multiplierDeviationSum = 0;
    for (final reading in winningCluster.members) {
      final weight = _readingWeight(reading);
      variance += weight * math.pow(reading.bpm - clusterMean, 2);
      weightSum += weight;
      final consistency =
          (reading.metadata['clusterConsistency'] as num?)?.toDouble() ?? 1.0;
      consistencySum += weight * consistency.clamp(0.0, 1.0);
      final multiplier =
          (reading.metadata['rangeMultiplier'] as num?)?.toDouble() ?? 1.0;
      final clamped = reading.metadata['rangeClamped'] == true;
      multiplierDeviationSum += weight * (multiplier - 1.0).abs();
    }

    final clusterStd = weightSum <= 0 ? 0 : math.sqrt(variance / weightSum);
    final clusterStdScore = (1.0 / (1.0 + clusterStd / 3.0)).clamp(0.0, 1.0);
    final avgConsistency = weightSum <= 0
        ? 1.0
        : (consistencySum / weightSum).clamp(0.0, 1.0);
    final avgMultiplierDeviation = weightSum <= 0
        ? 0.0
        : (multiplierDeviationSum / weightSum).clamp(0.0, 2.0);
    final harmonicScore =
        (1.0 - math.min(0.4, avgMultiplierDeviation * 0.6)).clamp(0.4, 1.0);

    final stabilityScore = _consensusStabilityScore();
    final drift = (rawConsensus - smoothedConsensus).abs();
    final driftScore = (1.0 - drift / 6.0).clamp(0.0, 1.0);

    var confidence = (majorityScore * 0.35) +
        (clusterStdScore * 0.2) +
        (avgConsistency * 0.15) +
        (harmonicScore * 0.1) +
        (stabilityScore * 0.1) +
        (driftScore * 0.1);

    if (_stableCount > 8) {
      confidence = math.min(confidence + 0.05, 1.0);
    }

    return confidence.clamp(0.0, 1.0);
  }

  ConsensusResult? _fallback() {
    if (_currentConsensus == null) {
      return null;
    }

    final stability = _consensusStabilityScore();
    final fallbackConfidence = math.max(
      0.15,
      stability * 0.7,
    );

    return ConsensusResult(
      bpm: _currentConsensus!,
      confidence: fallbackConfidence,
      weights: const {},
    );
  }

  double _clusterWeight(_Cluster cluster) {
    return cluster.members.fold<double>(
      0,
      (sum, reading) => sum + _readingWeight(reading),
    );
  }

  double _readingWeight(BpmReading reading) {
    final base = reading.confidence.clamp(0.0, 1.0);
    final consistency =
        (reading.metadata['clusterConsistency'] as num?)?.toDouble() ?? 1.0;
    final multiplier =
        (reading.metadata['rangeMultiplier'] as num?)?.toDouble() ?? 1.0;
    final clamped = reading.metadata['rangeClamped'] == true;
    final multiplierWeight = _multiplierWeight(multiplier, clamped);
    final octavePenalty = reading.metadata['octaveNormalized'] == true ? 0.85 : 1.0;
    final weight = base * (0.6 + 0.4 * consistency.clamp(0.0, 1.0)) * multiplierWeight * octavePenalty;
    if (weight.isNaN || weight.isInfinite) {
      return 0.1;
    }
    return weight.clamp(0.05, 1.0);
  }

  double _multiplierWeight(double multiplier, bool clamped) {
    var penalty = 1.0 - (multiplier - 1.0).abs() * 0.35;
    penalty = penalty.clamp(0.4, 1.0);
    if (clamped) {
      penalty *= 0.75;
    }
    return penalty.clamp(0.3, 1.0);
  }

  double _consensusStabilityScore() {
    if (_consensusHistory.length < 2) {
      return 0.5;
    }
    final values = _consensusHistory.toList(growable: false);
    final mean =
        values.reduce((sum, value) => sum + value) / values.length.toDouble();
    var variance = 0.0;
    for (final value in values) {
      variance += math.pow(value - mean, 2).toDouble();
    }
    variance /= values.length;
    final stdDev = math.sqrt(variance);
    return (1.0 - (stdDev / 6.0)).clamp(0.0, 1.0);
  }
}

class _Cluster {
  const _Cluster({required this.members});

  final List<BpmReading> members;
}
