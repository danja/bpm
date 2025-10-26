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
      previewSamples: const [],
    );

    final controller = StreamController<BpmSummary>();
    final buffer = Queue<_BufferedFrame>();
    final waveform = Queue<double>();
    var bufferDuration = Duration.zero;
    var elapsedSinceLastAnalysis = Duration.zero;
    var elapsedSincePreview = Duration.zero;
    var currentStatus = DetectionStatus.listening;
    var latestReadings = const <BpmReading>[];
    ConsensusResult? latestConsensus;

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
        elapsedSincePreview += frameDuration;
        _accumulateWaveform(waveform, frame.samples, _scopeSampleLimit);

        while (bufferDuration > bufferWindow && buffer.isNotEmpty) {
          final removed = buffer.removeFirst();
          bufferDuration -= removed.duration;
        }

        if (elapsedSincePreview >= _scopePreviewInterval) {
          elapsedSincePreview = Duration.zero;
          final previewStatus = bufferDuration < bufferWindow
              ? DetectionStatus.buffering
              : currentStatus;
          controller.add(
            BpmSummary(
              status: previewStatus,
              readings: latestReadings,
              consensus: latestConsensus,
              previewSamples: _waveformSnapshot(waveform),
            ),
          );
        }

        if (bufferDuration < bufferWindow) {
          currentStatus = DetectionStatus.buffering;
          return;
        }

        if (elapsedSinceLastAnalysis < analysisInterval) {
          return;
        }
        elapsedSinceLastAnalysis = Duration.zero;
        currentStatus = DetectionStatus.analyzing;
        controller.add(
          BpmSummary(
            status: DetectionStatus.analyzing,
            readings: latestReadings,
            consensus: latestConsensus,
            previewSamples: _waveformSnapshot(waveform),
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
        latestReadings = filtered;
        latestConsensus = consensus;

        currentStatus = DetectionStatus.streamingResults;
        controller.add(
          BpmSummary(
            status: DetectionStatus.streamingResults,
            readings: filtered,
            consensus: consensus,
            previewSamples: _waveformSnapshot(waveform),
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

const int _scopeSampleLimit = 2048;
const Duration _scopePreviewInterval = Duration(milliseconds: 120);

void _accumulateWaveform(
  Queue<double> target,
  List<double> samples,
  int maxLength,
) {
  for (final sample in samples) {
    target.addLast(sample);
    if (target.length > maxLength) {
      target.removeFirst();
    }
  }
}

List<double> _waveformSnapshot(Queue<double> source) {
  if (source.isEmpty) {
    return const [];
  }
  return List<double>.from(source);
}
