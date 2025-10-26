import 'dart:async';
import 'dart:collection';

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
    this.analysisInterval = const Duration(seconds: 1),
  });

  final AudioStreamSource audioSource;
  final AlgorithmRegistry registry;
  final ConsensusEngine consensusEngine;
  final Duration bufferWindow;
  final Duration analysisInterval;

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
    final buffer = Queue<_BufferedFrame>();
    var bufferDuration = Duration.zero;
    var elapsedSinceLastAnalysis = Duration.zero;
    var hasReportedBuffering = false;

    final frameSub = audioSource.frames(streamConfig).listen(
      (frame) async {
        final frameDuration = Duration(
          microseconds: (frame.samples.length / frame.sampleRate *
                  Duration.microsecondsPerSecond)
              .round(),
        );
        buffer.add(
          _BufferedFrame(
            frame: frame,
            duration: frameDuration,
          ),
        );
        bufferDuration += frameDuration;
        elapsedSinceLastAnalysis += frameDuration;

        while (bufferDuration > bufferWindow && buffer.isNotEmpty) {
          final removed = buffer.removeFirst();
          bufferDuration -= removed.duration;
        }

        if (bufferDuration < bufferWindow) {
          if (!hasReportedBuffering) {
            controller.add(
              BpmSummary(
                status: DetectionStatus.buffering,
                readings: const [],
              ),
            );
            hasReportedBuffering = true;
          }
          return;
        }

        if (elapsedSinceLastAnalysis < analysisInterval) {
          return;
        }
        elapsedSinceLastAnalysis = Duration.zero;
        hasReportedBuffering = false;

        controller.add(
          BpmSummary(
            status: DetectionStatus.analyzing,
            readings: const [],
          ),
        );

        final windowFrames =
            buffer.map((entry) => entry.frame).toList(growable: false);
        final readings = await Future.wait(
          registry.algorithms.map(
            (algorithm) => algorithm.analyze(
              window: windowFrames,
              context: context,
            ),
          ),
        );

        final filtered = readings.whereType<BpmReading>().toList();
        final consensus = consensusEngine.combine(filtered);

        controller.add(
          BpmSummary(
            status: DetectionStatus.streamingResults,
            readings: filtered,
            consensus: consensus,
          ),
        );
      },
      onError: controller.addError,
      cancelOnError: true,
    );

    yield* controller.stream;
    await frameSub.cancel();
  }
}

class _BufferedFrame {
  const _BufferedFrame({required this.frame, required this.duration});

  final AudioFrame frame;
  final Duration duration;
}
