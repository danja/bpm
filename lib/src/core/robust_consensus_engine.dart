import 'dart:collection';
import 'dart:math' as math;

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
  });

  final int historySize;
  final int minReadingsForOutlierDetection;
  final double algorithmOutlierThreshold;
  final double clusterTolerance;
  final int minClusterSize;
  final double smoothingFactor;

  // Per-algorithm history: algorithmId -> queue of BPM values
  final _algorithmHistories = <String, Queue<double>>{};

  // Current consensus value
  double? _currentConsensus;

  // Count of stable readings
  int _stableCount = 0;

  @override
  ConsensusResult? combine(List<BpmReading> readings) {
    if (readings.isEmpty) {
      return _fallback();
    }

    // Step 1: Update per-algorithm histories and filter outliers
    final cleanedReadings = <BpmReading>[];
    for (final reading in readings) {
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

    // Step 4: Calculate consensus from winning cluster
    final rawConsensus = _calculateClusterMean(winningCluster);

    // Step 5: Apply smoothing
    final smoothed = _smooth(rawConsensus);

    // Step 6: Update state
    _currentConsensus = smoothed;

    // Check stability
    if (_currentConsensus != null &&
        (rawConsensus - _currentConsensus!).abs() < 2.0) {
      _stableCount++;
    } else {
      _stableCount = 0;
    }

    // Step 7: Calculate confidence
    final confidence = _calculateConfidence(winningCluster, cleanedReadings.length);

    // Step 8: Build weights map for debugging
    final weights = <String, double>{};
    for (final reading in winningCluster.members) {
      weights[reading.algorithmId] = 1.0 / winningCluster.members.length;
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
    // Sort by cluster size (number of algorithms agreeing)
    clusters.sort((a, b) => b.members.length.compareTo(a.members.length));

    var bestCluster = clusters.first;

    // If tied, prefer cluster closer to current consensus
    if (_currentConsensus != null && clusters.length > 1) {
      final topSize = clusters.first.members.length;
      final tiedClusters = clusters.where((c) => c.members.length == topSize).toList();

      if (tiedClusters.length > 1) {
        // Find cluster closest to current consensus
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

    final sum = cluster.members.fold<double>(0.0, (sum, r) => sum + r.bpm);
    return sum / cluster.members.length;
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

  double _calculateConfidence(_Cluster winningCluster, int totalReadings) {
    // Base confidence from cluster size (majority strength)
    final majorityRatio = winningCluster.members.length / totalReadings;
    var confidence = majorityRatio;

    // Boost for tight agreement within cluster
    final clusterBpms = winningCluster.members.map((r) => r.bpm).toList();
    final clusterMean = _calculateClusterMean(winningCluster);
    final avgDeviation = clusterBpms
        .map((bpm) => (bpm - clusterMean).abs())
        .fold<double>(0.0, (sum, d) => sum + d) / clusterBpms.length;

    if (avgDeviation < 1.5) {
      confidence *= 1.3; // Very tight agreement
    } else if (avgDeviation < 3.0) {
      confidence *= 1.1; // Good agreement
    }

    // Boost for stability over time
    if (_stableCount > 5) {
      confidence *= 1.2;
    }

    // Consider individual algorithm confidences
    final avgAlgorithmConfidence = winningCluster.members
        .map((r) => r.confidence)
        .fold<double>(0.0, (sum, c) => sum + c) / winningCluster.members.length;

    confidence = (confidence + avgAlgorithmConfidence) / 2;

    return confidence.clamp(0.0, 1.0);
  }

  ConsensusResult? _fallback() {
    if (_currentConsensus == null) {
      return null;
    }

    return ConsensusResult(
      bpm: _currentConsensus!,
      confidence: math.max(0.2, 0.8 - _stableCount * 0.1), // Decay confidence without new readings
      weights: const {},
    );
  }
}

class _Cluster {
  const _Cluster({required this.members});

  final List<BpmReading> members;
}
