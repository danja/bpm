import 'dart:math' as math;

import 'package:bpm/src/models/bpm_models.dart';

class ConsensusEngine {
  ConsensusEngine({
    this.minConfidence = 0.05,
    this.halfTempoTolerance = 0.03,
    this.smoothingFactor = 0.3,
  });

  final double minConfidence;
  final double halfTempoTolerance;
  final double smoothingFactor;

  double? _previousBpm;

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

    final provisional = _weightedMean(eligible, initialWeights);
    final refinedWeights = _reweightOutliers(eligible, initialWeights, provisional);
    final consensusBpm = _weightedMean(eligible, refinedWeights);

    final smoothedBpm = _smooth(consensusBpm);
    final aggregateConfidence = _aggregateConfidence(refinedWeights);

    _previousBpm = smoothedBpm;

    return ConsensusResult(
      bpm: smoothedBpm,
      confidence: aggregateConfidence,
      weights: refinedWeights,
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
    final deviations = readings.map((reading) => (reading.bpm - mean).abs()).toList();
    final maxDeviation = deviations.isEmpty ? 0 : deviations.reduce(math.max);
    if (maxDeviation <= 3) {
      return result;
    }
    for (var i = 0; i < readings.length; i++) {
      final reading = readings[i];
      final deviation = deviations[i];
      if (deviation > 6) {
        result.update(reading.algorithmId, (value) => value * 0.4);
      } else if (deviation > 4) {
        result.update(reading.algorithmId, (value) => value * 0.7);
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
    final normalized = total / weights.length;
    return normalized.clamp(0.0, 1.0);
  }
}
