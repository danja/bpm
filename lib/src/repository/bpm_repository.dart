import 'package:bpm/src/algorithms/detection_context.dart';
import 'package:bpm/src/audio/audio_stream_source.dart';
import 'package:bpm/src/core/bpm_detector_coordinator.dart';
import 'package:bpm/src/models/bpm_models.dart';

class BpmRepository {
  BpmRepository({
    required this.coordinator,
    required this.streamConfig,
    required this.context,
  });

  final BpmDetectorCoordinator coordinator;
  final AudioStreamConfig streamConfig;
  final DetectionContext context;

  Stream<BpmSummary> listen() {
    return coordinator.start(
      streamConfig: streamConfig,
      context: context,
    );
  }

  Future<void> stop() => coordinator.audioSource.stop();
}
