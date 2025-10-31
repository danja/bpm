import 'dart:typed_data';

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

class TempogramSnapshot extends Equatable {
  const TempogramSnapshot({
    required this.matrix,
    required this.tempoAxis,
    required this.times,
    required this.dominantTempo,
    required this.dominantStrength,
  });

  final List<Float32List> matrix;
  final Float32List tempoAxis;
  final Float32List times;
  final Float32List dominantTempo;
  final Float32List dominantStrength;

  double? get latestTempo =>
      dominantTempo.isEmpty ? null : dominantTempo[dominantTempo.length - 1];

  double? get latestStrength => dominantStrength.isEmpty
      ? null
      : dominantStrength[dominantStrength.length - 1];

  bool get isEmpty => matrix.isEmpty || tempoAxis.isEmpty || times.isEmpty;

  @override
  List<Object?> get props =>
      [matrix, tempoAxis, times, dominantTempo, dominantStrength];
}

/// Snapshot of the detection pipeline for presentation/state management.
class BpmSummary extends Equatable {
  const BpmSummary({
    required this.status,
    required this.readings,
    this.consensus,
    this.message,
    this.previewSamples = const [],
    this.plpBpm,
    this.plpStrength,
    this.plpTrace = const <double>[],
    this.tempogram,
  });

  final DetectionStatus status;
  final List<BpmReading> readings;
  final ConsensusResult? consensus;
  final String? message;
  final List<double> previewSamples;
  final double? plpBpm;
  final double? plpStrength;
  final List<double> plpTrace;
  final TempogramSnapshot? tempogram;

  @override
  List<Object?> get props => [
        status,
        readings,
        consensus,
        message,
        previewSamples,
        plpBpm,
        plpStrength,
        plpTrace,
        tempogram,
      ];

  factory BpmSummary.idle() => const BpmSummary(
        status: DetectionStatus.idle,
        readings: [],
        previewSamples: [],
        plpTrace: const <double>[],
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
