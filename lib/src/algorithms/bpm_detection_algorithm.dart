import 'package:bpm/src/dsp/preprocessing_pipeline.dart';
import 'package:bpm/src/models/bpm_models.dart';

/// Contract for all BPM detection algorithms.
///
/// Algorithms now receive preprocessed signals with shared features computed
/// once in the preprocessing pipeline. This eliminates redundant computations
/// and ensures consistent signal quality across all algorithms.
abstract class BpmDetectionAlgorithm {
  String get id;
  String get label;
  Duration get preferredWindow;

  /// Analyzes preprocessed signal and returns BPM reading.
  ///
  /// [signal] - Preprocessed audio signal with computed features
  ///
  /// Returns a reading or null when insufficient evidence is present.
  Future<BpmReading?> analyze({
    required PreprocessedSignal signal,
  });
}
