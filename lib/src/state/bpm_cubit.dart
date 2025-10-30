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
  static const _consensusBlendAlpha = 0.35;
  static const _historySmoothingWindow = 3;

  Future<void> start() async {
    _logger.info('User pressed Start button', source: 'App');
    if (_subscription != null) {
      _logger.warning('Already subscribed, ignoring start request', source: 'App');
      return;
    }

    emit(
      BpmState.initial().copyWith(
        status: DetectionStatus.listening,
        readings: const [],
        clearConsensus: true,
      ),
    );

    _subscription = _repository.listen().listen(
          (summary) {
            final blendedConsensus = summary.consensus != null
                ? _smoothedConsensus(state.consensus, summary.consensus!)
                : state.consensus;
            emit(
              state.copyWith(
                status: summary.status,
                readings: summary.readings,
                consensus: blendedConsensus,
                message: summary.message,
                history: _updatedHistory(
                  state.history,
                  summary.status,
                  summary.consensus != null ? blendedConsensus : null,
                ),
                previewSamples: summary.previewSamples,
              ),
            );
          },
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
    DetectionStatus status,
    ConsensusResult? consensus,
  ) {
    if (consensus == null || status != DetectionStatus.streamingResults) {
      return current;
    }

    final smoothedBpm = _smoothedBpm(current, consensus.bpm);
    final smoothedConfidence = _smoothedConfidence(current, consensus.confidence);

    final next = List<BpmHistoryPoint>.from(current)
      ..add(
        BpmHistoryPoint(
          bpm: smoothedBpm,
          confidence: smoothedConfidence,
          timestamp: DateTime.now().toUtc(),
        ),
      );
    if (next.length > _maxHistoryPoints) {
      next.removeRange(0, next.length - _maxHistoryPoints);
    }
    return next;
  }

  ConsensusResult _smoothedConsensus(
    ConsensusResult? previous,
    ConsensusResult incoming,
  ) {
    if (previous == null) {
      return incoming;
    }
    final alpha = _consensusBlendAlpha;
    final bpm = previous.bpm + alpha * (incoming.bpm - previous.bpm);
    final confidence =
        previous.confidence + alpha * (incoming.confidence - previous.confidence);
    final clampedConfidence = confidence.clamp(0.0, 1.0).toDouble();
    return ConsensusResult(
      bpm: bpm,
      confidence: clampedConfidence,
      weights: incoming.weights,
    );
  }

  double _smoothedBpm(List<BpmHistoryPoint> history, double candidate) {
    final recentCount = _historySmoothingWindow - 1;
    final startIndex = history.length > recentCount ? history.length - recentCount : 0;
    final values = history.isEmpty
        ? <double>[]
        : history.sublist(startIndex).map((point) => point.bpm).toList();
    values.add(candidate);
    final total = values.fold<double>(0, (sum, value) => sum + value);
    return total / values.length;
  }

  double _smoothedConfidence(List<BpmHistoryPoint> history, double candidate) {
    final recentCount = _historySmoothingWindow - 1;
    final startIndex = history.length > recentCount ? history.length - recentCount : 0;
    final values = history.isEmpty
        ? <double>[]
        : history.sublist(startIndex).map((point) => point.confidence).toList();
    values.add(candidate);
    final total = values.fold<double>(0, (sum, value) => sum + value);
    return (total / values.length).clamp(0.0, 1.0).toDouble();
  }
}
