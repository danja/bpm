import 'package:bpm/src/models/bpm_models.dart';

class ConsensusEngine {
  const ConsensusEngine({this.minConfidence = 0.1});

  final double minConfidence;

  ConsensusResult? combine(List<BpmReading> readings) {
    if (readings.isEmpty) return null;

    final filtered =
        readings.where((reading) => reading.confidence >= minConfidence).toList();
    if (filtered.isEmpty) return null;

    final totalWeight =
        filtered.fold<double>(0, (sum, reading) => sum + reading.confidence);
    final bpm =
        filtered.fold<double>(0, (sum, reading) => sum + reading.bpm * reading.confidence) /
            totalWeight;

    final weights = <String, double>{
      for (final reading in filtered) reading.algorithmId: reading.confidence / totalWeight
    };

    return ConsensusResult(
      bpm: bpm,
      confidence: (totalWeight / filtered.length).clamp(0.0, 1.0),
      weights: weights,
    );
  }
}
