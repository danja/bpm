import 'package:equatable/equatable.dart';

/// Operational status for BPM detection flow.
enum DetectionStatus {
  idle,
  listening,
  buffering,
  analyzing,
  streamingResults,
  error,
}

/// PCM audio segment passed into the DSP pipeline.
class AudioFrame extends Equatable {
  const AudioFrame({
    required this.samples,
    required this.sampleRate,
    required this.channels,
    required this.sequence,
  });

  final List<double> samples;
  final int sampleRate;
  final int channels;
  final int sequence;

  @override
  List<Object?> get props => [sequence];
}

/// Single algorithm reading emitted during processing.
class BpmReading extends Equatable {
  const BpmReading({
    required this.algorithmId,
    required this.algorithmName,
    required this.bpm,
    required this.confidence,
    required this.timestamp,
    this.metadata = const {},
  });

  final String algorithmId;
  final String algorithmName;
  final double bpm;
  final double confidence;
  final DateTime timestamp;
  final Map<String, Object?> metadata;

  @override
  List<Object?> get props => [algorithmId, bpm, confidence, timestamp];
}

/// Aggregated consensus result based on multiple readings.
class ConsensusResult extends Equatable {
  const ConsensusResult({
    required this.bpm,
    required this.confidence,
    required this.weights,
  });

  final double bpm;
  final double confidence;
  final Map<String, double> weights;

  @override
  List<Object?> get props => [bpm, confidence];
}

/// Snapshot of the detection pipeline for presentation/state management.
class BpmSummary extends Equatable {
  const BpmSummary({
    required this.status,
    required this.readings,
    this.consensus,
    this.message,
    this.previewSamples = const [],
  });

  final DetectionStatus status;
  final List<BpmReading> readings;
  final ConsensusResult? consensus;
  final String? message;
  final List<double> previewSamples;

  @override
  List<Object?> get props => [status, readings, consensus, message, previewSamples];

  factory BpmSummary.idle() => const BpmSummary(
        status: DetectionStatus.idle,
        readings: [],
        previewSamples: [],
      );
}

class BpmHistoryPoint extends Equatable {
  const BpmHistoryPoint({
    required this.bpm,
    required this.confidence,
    required this.timestamp,
  });

  final double bpm;
  final double confidence;
  final DateTime timestamp;

  factory BpmHistoryPoint.fromConsensus(ConsensusResult consensus) =>
      BpmHistoryPoint(
        bpm: consensus.bpm,
        confidence: consensus.confidence,
        timestamp: DateTime.now().toUtc(),
      );

  @override
  List<Object?> get props => [bpm, confidence, timestamp];
}
