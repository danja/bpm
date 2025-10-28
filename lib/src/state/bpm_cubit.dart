import 'dart:async';

import 'package:bpm/src/models/bpm_models.dart';
import 'package:bpm/src/repository/bpm_repository.dart';
import 'package:bpm/src/state/bpm_state.dart';
import 'package:bpm/src/utils/app_logger.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

class BpmCubit extends Cubit<BpmState> {
  BpmCubit(this._repository) : super(BpmState.initial());

  final BpmRepository _repository;
  final _logger = AppLogger();
  StreamSubscription<BpmSummary>? _subscription;
  static const _maxHistoryPoints = 12;

  Future<void> start() async {
    _logger.info('User pressed Start button', source: 'App');
    if (_subscription != null) {
      _logger.warning('Already subscribed, ignoring start request', source: 'App');
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
              consensus: summary.consensus ?? state.consensus, // Keep previous if null
              message: summary.message,
              history: _updatedHistory(state.history, summary),
              previewSamples: summary.previewSamples,
            ),
          ),
          onError: (error, stackTrace) {
            _logger.error('BPM detection error: $error', source: 'App');
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
    _logger.info('User pressed Stop button', source: 'App');
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

  List<BpmHistoryPoint> _updatedHistory(
    List<BpmHistoryPoint> current,
    BpmSummary summary,
  ) {
    final consensus = summary.consensus;
    if (consensus == null ||
        summary.status != DetectionStatus.streamingResults) {
      return current;
    }

    final next = List<BpmHistoryPoint>.from(current)
      ..add(BpmHistoryPoint.fromConsensus(consensus));
    if (next.length > _maxHistoryPoints) {
      next.removeRange(0, next.length - _maxHistoryPoints);
    }
    return next;
  }
}
