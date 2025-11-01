import 'package:equatable/equatable.dart';

import 'package:bpm/src/models/bpm_models.dart';

class BpmState extends Equatable {
  const BpmState({
    required this.status,
    required this.readings,
    this.consensus,
    this.message,
    this.history = const <BpmHistoryPoint>[],
    this.previewSamples = const [],
    this.startedAt,
    this.elapsed = Duration.zero,
    this.plpBpm,
    this.plpStrength,
    this.plpTrace = const <double>[],
    this.tempogram,
  });

  final DetectionStatus status;
  final List<BpmReading> readings;
  final ConsensusResult? consensus;
  final String? message;
  final List<BpmHistoryPoint> history;
  final List<double> previewSamples;
  final DateTime? startedAt;
  final Duration elapsed;
  final double? plpBpm;
  final double? plpStrength;
  final List<double> plpTrace;
  final TempogramSnapshot? tempogram;

  factory BpmState.initial() => const BpmState(
        status: DetectionStatus.idle,
        readings: [],
        history: [],
        previewSamples: [],
        startedAt: null,
        elapsed: Duration.zero,
      );

  BpmState copyWith({
    DetectionStatus? status,
    List<BpmReading>? readings,
    ConsensusResult? consensus,
    bool clearConsensus = false,
    String? message,
    List<BpmHistoryPoint>? history,
    List<double>? previewSamples,
    DateTime? startedAt,
    bool resetStartTime = false,
    Duration? elapsed,
    double? plpBpm,
    double? plpStrength,
    List<double>? plpTrace,
    TempogramSnapshot? tempogram,
    bool clearTempogram = false,
  }) {
    return BpmState(
      status: status ?? this.status,
      readings: readings ?? this.readings,
      consensus: clearConsensus ? null : (consensus ?? this.consensus),
      message: message ?? this.message,
      history: history ?? this.history,
      previewSamples: previewSamples ?? this.previewSamples,
      startedAt: resetStartTime ? null : (startedAt ?? this.startedAt),
      elapsed: resetStartTime
          ? Duration.zero
          : (elapsed ?? this.elapsed),
      plpBpm: plpBpm ?? this.plpBpm,
      plpStrength: plpStrength ?? this.plpStrength,
      plpTrace: plpTrace ?? this.plpTrace,
      tempogram: clearTempogram ? null : (tempogram ?? this.tempogram),
    );
  }

  @override
  List<Object?> get props =>
      [
        status,
        readings,
        consensus,
        message,
        history,
        previewSamples,
        startedAt,
        elapsed,
        plpBpm,
        plpStrength,
        plpTrace,
        tempogram,
      ];
}
