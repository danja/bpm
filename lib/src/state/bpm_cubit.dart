import 'dart:async';

import 'package:bpm/src/models/bpm_models.dart';
import 'package:bpm/src/repository/bpm_repository.dart';
import 'package:bpm/src/state/bpm_state.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

class BpmCubit extends Cubit<BpmState> {
  BpmCubit(this._repository) : super(BpmState.initial());

  final BpmRepository _repository;
  StreamSubscription<BpmSummary>? _subscription;

  Future<void> start() async {
    if (_subscription != null) {
      return;
    }

    emit(
      state.copyWith(
        status: DetectionStatus.listening,
        readings: const [],
        clearConsensus: true,
      ),
    );

    _subscription = _repository.listen().listen(
          (summary) => emit(
            state.copyWith(
              status: summary.status,
              readings: summary.readings,
              consensus: summary.consensus,
              message: summary.message,
            ),
          ),
          onError: (error, stackTrace) {
            emit(
              state.copyWith(
                status: DetectionStatus.error,
                message: error.toString(),
              ),
            );
          },
        );
  }

  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    await _repository.stop();
    emit(BpmState.initial());
  }

  @override
  Future<void> close() async {
    await stop();
    return super.close();
  }
}
