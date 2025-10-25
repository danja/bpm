import 'package:bpm/src/algorithms/detection_context.dart';
import 'package:bpm/src/models/bpm_models.dart';

/// Contract for all BPM detection algorithms.
abstract class BpmDetectionAlgorithm {
  String get id;
  String get label;
  Duration get preferredWindow;

  /// Returns a reading or null when insufficient evidence is present.
  Future<BpmReading?> analyze({
    required List<AudioFrame> window,
    required DetectionContext context,
  });
}
