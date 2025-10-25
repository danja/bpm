import 'package:equatable/equatable.dart';

import 'package:bpm/src/models/bpm_models.dart';

class BpmState extends Equatable {
  const BpmState({
    required this.status,
    required this.readings,
    this.consensus,
    this.message,
  });

  final DetectionStatus status;
  final List<BpmReading> readings;
  final ConsensusResult? consensus;
  final String? message;

  factory BpmState.initial() => const BpmState(
        status: DetectionStatus.idle,
        readings: [],
      );

  BpmState copyWith({
    DetectionStatus? status,
    List<BpmReading>? readings,
    ConsensusResult? consensus,
    bool clearConsensus = false,
    String? message,
  }) {
    return BpmState(
      status: status ?? this.status,
      readings: readings ?? this.readings,
      consensus: clearConsensus ? null : (consensus ?? this.consensus),
      message: message ?? this.message,
    );
  }

  @override
  List<Object?> get props => [status, readings, consensus, message];
}
