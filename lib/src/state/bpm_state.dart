import 'package:equatable/equatable.dart';

import 'package:bpm/src/models/bpm_models.dart';

class BpmState extends Equatable {
  const BpmState({
    required this.status,
    required this.readings,
    this.consensus,
    this.message,
    this.history = const <BpmHistoryPoint>[],
  });

  final DetectionStatus status;
  final List<BpmReading> readings;
  final ConsensusResult? consensus;
  final String? message;
  final List<BpmHistoryPoint> history;

  factory BpmState.initial() => const BpmState(
        status: DetectionStatus.idle,
        readings: [],
        history: [],
      );

  BpmState copyWith({
    DetectionStatus? status,
    List<BpmReading>? readings,
    ConsensusResult? consensus,
    bool clearConsensus = false,
    String? message,
    List<BpmHistoryPoint>? history,
  }) {
    return BpmState(
      status: status ?? this.status,
      readings: readings ?? this.readings,
      consensus: clearConsensus ? null : (consensus ?? this.consensus),
      message: message ?? this.message,
      history: history ?? this.history,
    );
  }

  @override
  List<Object?> get props => [status, readings, consensus, message, history];
}
