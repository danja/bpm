import 'package:bpm/src/models/bpm_models.dart';

/// Interface for consensus engines that combine multiple BPM readings.
abstract class ConsensusInterface {
  /// Combines multiple BPM readings into a single consensus result.
  ConsensusResult? combine(List<BpmReading> readings);
}
