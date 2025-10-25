import 'dart:async';

import 'package:bpm/src/algorithms/algorithm_registry.dart';
import 'package:bpm/src/algorithms/detection_context.dart';
import 'package:bpm/src/audio/audio_stream_source.dart';
import 'package:bpm/src/core/consensus_engine.dart';
import 'package:bpm/src/models/bpm_models.dart';

class BpmDetectorCoordinator {
  BpmDetectorCoordinator({
    required this.audioSource,
    required this.registry,
    required this.consensusEngine,
    this.bufferWindow = const Duration(seconds: 10),
  });

  final AudioStreamSource audioSource;
  final AlgorithmRegistry registry;
  final ConsensusEngine consensusEngine;
  final Duration bufferWindow;

  Stream<BpmSummary> start({
    required AudioStreamConfig streamConfig,
    required DetectionContext context,
  }) async* {
    await audioSource.start(streamConfig);
    yield BpmSummary(
      status: DetectionStatus.listening,
      readings: const [],
    );

    final controller = StreamController<BpmSummary>();
    final buffer = <AudioFrame>[];
    var bufferDuration = Duration.zero;

    final frameSub = audioSource.frames(streamConfig).listen(
      (frame) async {
        buffer.add(frame);
        final frameDuration = Duration(
          microseconds:
              (frame.samples.length / frame.sampleRate * Duration.microsecondsPerSecond)
                  .round(),
        );
        bufferDuration += frameDuration;

        if (bufferDuration >= bufferWindow) {
          controller.add(
            BpmSummary(
              status: DetectionStatus.analyzing,
              readings: const [],
            ),
          );

          final readings = await Future.wait(
            registry.algorithms.map(
              (algorithm) => algorithm.analyze(
                window: List.of(buffer),
                context: context,
              ),
            ),
          );

          buffer.clear();
          bufferDuration = Duration.zero;

          final filtered = readings.whereType<BpmReading>().toList();
          final consensus = consensusEngine.combine(filtered);

          controller.add(
            BpmSummary(
              status: DetectionStatus.streamingResults,
              readings: filtered,
              consensus: consensus,
            ),
          );
        }
      },
      onError: controller.addError,
      cancelOnError: true,
    );

    yield* controller.stream;
    await frameSub.cancel();
  }
}
