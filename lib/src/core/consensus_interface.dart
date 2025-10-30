import 'package:bpm/src/models/bpm_models.dart';

/// Interface for consensus engines that combine multiple BPM readings.
abstract class ConsensusInterface {
  /// Combines multiple BPM readings into a single consensus result.
  ConsensusResult? combine(List<BpmReading> readings);

  /// Resets the consensus state (history, cached values, etc.).
  /// Should be called when starting a new detection session.
  void reset();
}
