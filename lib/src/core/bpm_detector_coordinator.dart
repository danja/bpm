import 'dart:async';
import 'dart:collection';

import 'package:bpm/src/algorithms/algorithm_registry.dart';
import 'package:bpm/src/algorithms/detection_context.dart';
import 'package:bpm/src/audio/audio_stream_source.dart';
import 'package:bpm/src/core/consensus_engine.dart';
import 'package:bpm/src/models/bpm_models.dart';
import 'package:bpm/src/utils/app_logger.dart';

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
  final _logger = AppLogger();

  Stream<BpmSummary> start({
    required AudioStreamConfig streamConfig,
    required DetectionContext context,
  }) async* {
    _logger.info('BpmDetectorCoordinator.start() called', source: 'Coordinator');
    _logger.info('Stream config: ${streamConfig.sampleRate}Hz, ${streamConfig.channels} channels', source: 'Coordinator');

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
    var receivedFirstFrame = false;

    // Add a timeout check to detect if audio stream isn't flowing
    Timer? timeoutTimer;
    timeoutTimer = Timer(const Duration(seconds: 3), () {
      if (!receivedFirstFrame) {
        _logger.error('No audio data received after 3 seconds', source: 'Coordinator');
        controller.addError(
          Exception(
            'No audio data received after 3 seconds. '
            'This may indicate a problem with microphone access or audio configuration.',
          ),
        );
      }
    });

    // IMPORTANT: Subscribe to frames BEFORE starting audio to avoid missing data
    _logger.info('Subscribing to audio frames...', source: 'Coordinator');
    final frameSub = audioSource.frames(streamConfig).listen(
      (frame) async {
        // Mark that we've received the first frame
        if (!receivedFirstFrame) {
          receivedFirstFrame = true;
          timeoutTimer?.cancel();
          final durationMs = (frame.samples.length / frame.sampleRate * 1000).round();
          _logger.info('First audio frame received: ${frame.samples.length} samples @ ${frame.sampleRate}Hz = ${durationMs}ms', source: 'Coordinator');
        }

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
          final prevStatus = currentStatus;
          currentStatus = DetectionStatus.buffering;

          // Log every 2 seconds or on status change
          final secondsBuffered = bufferDuration.inSeconds;
          if (prevStatus != DetectionStatus.buffering || secondsBuffered % 2 == 0) {
            _logger.info('Status: buffering (${bufferDuration.inSeconds}s/${bufferWindow.inSeconds}s)', source: 'Coordinator');
          }
          return;
        }

        if (elapsedSinceLastAnalysis < analysisInterval) {
          return;
        }
        elapsedSinceLastAnalysis = Duration.zero;

        if (currentStatus != DetectionStatus.analyzing) {
          _logger.info('Buffer full! Starting analysis...', source: 'Coordinator');
        }
        currentStatus = DetectionStatus.analyzing;
        _logger.info('Status: analyzing', source: 'Coordinator');
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

        // Run algorithms with individual error handling
        final readings = <BpmReading?>[];
        for (final algorithm in registry.algorithms) {
          try {
            _logger.info('Running ${algorithm.label}...', source: 'Coordinator');
            final reading = await algorithm.analyze(
              window: windowFrames,
              context: context,
            );
            if (reading != null) {
              _logger.info('${algorithm.label} -> ${reading.bpm.toStringAsFixed(1)} BPM (confidence: ${reading.confidence.toStringAsFixed(2)})', source: 'Coordinator');
            } else {
              _logger.info('${algorithm.label} -> no result', source: 'Coordinator');
            }
            readings.add(reading);
          } catch (e, stack) {
            _logger.error('${algorithm.label} failed: $e', source: 'Coordinator');
            _logger.debug('Stack trace: $stack', source: 'Coordinator');
            // Continue with other algorithms
          }
        }

        final filtered = readings.whereType<BpmReading>().toList();
        final consensus = consensusEngine.combine(filtered);
        latestReadings = filtered;
        latestConsensus = consensus;

        final bpmStr = consensus != null ? consensus.bpm.toStringAsFixed(1) : 'none';
        _logger.info('Analysis complete: ${filtered.length} readings, consensus=$bpmStr', source: 'Coordinator');
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
      onError: (error) {
        _logger.error('Frame stream error: $error', source: 'Coordinator');
        controller.addError(error);
      },
      cancelOnError: true,
    );

    // Now start the audio source - frames will flow to our listener above
    _logger.info('Starting audio source...', source: 'Coordinator');
    await audioSource.start(streamConfig);
    _logger.info('Audio source started', source: 'Coordinator');

    yield* controller.stream;
    if (timeoutTimer.isActive) {
      timeoutTimer.cancel();
    }
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
