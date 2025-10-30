import 'dart:math' as math;

import 'package:bpm/src/core/consensus_interface.dart';
import 'package:bpm/src/models/bpm_models.dart';

class ConsensusEngine implements ConsensusInterface {
  ConsensusEngine({
    this.minConfidence = 0.05,
    this.halfTempoTolerance = 0.03,
    this.clusterToleranceBpm = 1.5,
    this.clusterMinWeight = 0.25,
    this.smoothingFactor = 0.2,
  });

  final double minConfidence;
  final double halfTempoTolerance;
  final double clusterToleranceBpm;
  final double clusterMinWeight;
  final double smoothingFactor;

  double? _previousBpm;

  @override
  ConsensusResult? combine(List<BpmReading> readings) {
    if (readings.isEmpty) return _fallback();

    final normalized = _normalizeTempos(readings);
    final eligible = normalized
        .where((reading) => reading.confidence >= minConfidence)
        .toList();
    if (eligible.isEmpty) {
      return _fallback();
    }

    final initialWeights = {
      for (final reading in eligible) reading.algorithmId: _heuristicWeight(reading)
    };

    final cluster = _selectCluster(eligible, initialWeights);

    Map<String, double> finalWeights;
    double consensusBpm;
    if (cluster != null && cluster.totalWeight >= clusterMinWeight) {
      finalWeights = cluster.weights;
      consensusBpm = _weightedMean(cluster.members, cluster.weights);
    } else {
      final reweighted = _reweightOutliers(
        eligible,
        initialWeights,
        _weightedMean(eligible, initialWeights),
      );
      finalWeights = reweighted;
      consensusBpm = _weightedMean(eligible, reweighted);
    }

    final smoothedBpm = _smooth(consensusBpm);
    final aggregateConfidence = _aggregateConfidence(finalWeights);

    _previousBpm = smoothedBpm;

    return ConsensusResult(
      bpm: smoothedBpm,
      confidence: aggregateConfidence,
      weights: finalWeights,
    );
  }

  ConsensusResult? _fallback() {
    if (_previousBpm == null) {
      return null;
    }
    return ConsensusResult(
      bpm: _previousBpm!,
      confidence: 0,
      weights: const {},
    );
  }

  List<BpmReading> _normalizeTempos(List<BpmReading> readings) {
    final result = <BpmReading>[];
    for (final reading in readings) {
      var bpm = reading.bpm;
      if (_previousBpm != null) {
        final ratio = bpm / _previousBpm!;
        if ((ratio - 0.5).abs() <= halfTempoTolerance) {
          bpm *= 2;
        } else if ((ratio - 2).abs() <= halfTempoTolerance) {
          bpm /= 2;
        }
      }
      result.add(
        BpmReading(
          algorithmId: reading.algorithmId,
          algorithmName: reading.algorithmName,
          bpm: bpm,
          confidence: reading.confidence,
          timestamp: reading.timestamp,
          metadata: reading.metadata,
        ),
      );
    }
    return result;
  }

  double _heuristicWeight(BpmReading reading) {
    var weight = reading.confidence.clamp(0.0, 1.0);
    switch (reading.algorithmId) {
      case 'wavelet_energy':
        weight += 0.1;
        break;
      case 'fft_spectrum':
        weight += 0.05;
        break;
      case 'autocorrelation':
        weight += 0.02;
        break;
      default:
        break;
    }
    return weight.clamp(0.0, 1.0);
  }

  double _weightedMean(
    List<BpmReading> readings,
    Map<String, double> weights,
  ) {
    var total = 0.0;
    var weightSum = 0.0;
    for (final reading in readings) {
      final weight = weights[reading.algorithmId] ?? 0;
      total += reading.bpm * weight;
      weightSum += weight;
    }
    if (weightSum == 0) {
      return readings.first.bpm;
    }
    return total / weightSum;
  }

  Map<String, double> _reweightOutliers(
    List<BpmReading> readings,
    Map<String, double> weights,
    double mean,
  ) {
    final result = Map<String, double>.from(weights);
    for (final reading in readings) {
      final deviation = (reading.bpm - mean).abs();
      if (deviation > 8) {
        result.update(reading.algorithmId, (value) => value * 0.3);
      } else if (deviation > 5) {
        result.update(reading.algorithmId, (value) => value * 0.6);
      }
    }
    return result;
  }

  double _smooth(double current) {
    if (_previousBpm == null) {
      return current;
    }
    return _previousBpm! + smoothingFactor * (current - _previousBpm!);
  }

  double _aggregateConfidence(Map<String, double> weights) {
    if (weights.isEmpty) {
      return 0;
    }
    final total = weights.values.fold<double>(0, (sum, value) => sum + value);
    return total.clamp(0.0, 1.0);
  }

  _Cluster? _selectCluster(
    List<BpmReading> readings,
    Map<String, double> weights,
  ) {
    _Cluster? bestCluster;
    for (var i = 0; i < readings.length; i++) {
      final anchor = readings[i];
      final tolerance = math.max(clusterToleranceBpm, anchor.bpm * halfTempoTolerance);
      final members = <BpmReading>[];
      final clusterWeights = <String, double>{};
      var totalWeight = 0.0;
      for (var j = 0; j < readings.length; j++) {
        final candidate = readings[j];
        final diff = (candidate.bpm - anchor.bpm).abs();
        if (diff <= tolerance) {
          final weight = weights[candidate.algorithmId] ?? 0;
          members.add(candidate);
          clusterWeights[candidate.algorithmId] = weight;
          totalWeight += weight;
        }
      }
      if (members.length < 2) {
        continue;
      }
      final cluster = _Cluster(
        members: members,
        weights: clusterWeights,
        totalWeight: totalWeight,
      );
      if (bestCluster == null || cluster.totalWeight > bestCluster.totalWeight) {
        bestCluster = cluster;
      }
    }
    if (bestCluster == null) {
      return null;
    }
    final normalizedWeights = _normalizeWeights(bestCluster.weights);
    return _Cluster(
      members: bestCluster.members,
      weights: normalizedWeights,
      totalWeight: bestCluster.totalWeight,
    );
  }

  Map<String, double> _normalizeWeights(Map<String, double> weights) {
    final total = weights.values.fold<double>(0, (sum, value) => sum + value);
    if (total == 0) {
      return weights;
    }
    return {
      for (final entry in weights.entries) entry.key: (entry.value / total).clamp(0.0, 1.0),
    };
  }
}

class _Cluster {
  const _Cluster({
    required this.members,
    required this.weights,
    required this.totalWeight,
  });

  final List<BpmReading> members;
  final Map<String, double> weights;
  final double totalWeight;
}
