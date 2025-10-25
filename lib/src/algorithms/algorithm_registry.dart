import 'package:bpm/src/algorithms/bpm_detection_algorithm.dart';

class AlgorithmRegistry {
  AlgorithmRegistry(this._algorithms) {
    if (_algorithms.isEmpty) {
      throw ArgumentError('At least one BPM algorithm must be registered.');
    }
  }

  final List<BpmDetectionAlgorithm> _algorithms;

  List<BpmDetectionAlgorithm> get algorithms => List.unmodifiable(_algorithms);

  BpmDetectionAlgorithm byId(String id) =>
      _algorithms.firstWhere((algo) => algo.id == id);
}
