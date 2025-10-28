import 'dart:async';
import 'dart:collection';

import 'package:bpm/src/algorithms/algorithm_registry.dart';
import 'package:bpm/src/algorithms/autocorrelation_algorithm.dart';
import 'package:bpm/src/algorithms/bpm_detection_algorithm.dart';
import 'package:bpm/src/algorithms/detection_context.dart';
import 'package:bpm/src/algorithms/fft_spectrum_algorithm.dart';
import 'package:bpm/src/algorithms/simple_onset_algorithm.dart';
import 'package:bpm/src/algorithms/wavelet_energy_algorithm.dart';
import 'package:bpm/src/audio/audio_stream_source.dart';
import 'package:bpm/src/core/consensus_engine.dart';
import 'package:bpm/src/models/bpm_models.dart';
import 'package:bpm/src/utils/app_logger.dart';
import 'package:flutter/foundation.dart';

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
    _logger.info('BpmDetectorCoordinator.start() called',
        source: 'Coordinator');
    _logger.info(
        'Stream config: ${streamConfig.sampleRate}Hz, ${streamConfig.channels} channels',
        source: 'Coordinator');

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
    var bufferReady = false; // Track if buffer has ever been filled

    // Add a gentle timeout check to detect if audio stream isn't flowing
    Timer? timeoutTimer;
    timeoutTimer = Timer(const Duration(seconds: 3), () {
      if (!receivedFirstFrame) {
        _logger.warning(
          'No audio data received after 3 seconds (continuing to wait)',
          source: 'Coordinator',
        );
        controller.add(
          const BpmSummary(
            status: DetectionStatus.listening,
            readings: [],
            previewSamples: [],
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
          final durationMs =
              (frame.samples.length / frame.sampleRate * 1000).round();
          _logger.info(
              'First audio frame received: ${frame.samples.length} samples @ ${frame.sampleRate}Hz = ${durationMs}ms',
              source: 'Coordinator');
        }

        final frameDuration = Duration(
          microseconds: (frame.samples.length /
                  frame.sampleRate *
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

        // Check if buffer is full for the first time
        if (!bufferReady && bufferDuration >= bufferWindow) {
          bufferReady = true;
          _logger.info(
              'Buffer ready! ${bufferDuration.inSeconds}s of audio collected',
              source: 'Coordinator');
        }

        // Remove old frames to maintain sliding window (only after buffer is ready)
        if (bufferReady) {
          while (bufferDuration > bufferWindow && buffer.isNotEmpty) {
            final removed = buffer.removeFirst();
            bufferDuration -= removed.duration;
          }
        }

        if (elapsedSincePreview >= _scopePreviewInterval) {
          elapsedSincePreview = Duration.zero;
          final previewStatus =
              !bufferReady ? DetectionStatus.buffering : currentStatus;
          controller.add(
            BpmSummary(
              status: previewStatus,
              readings: latestReadings,
              consensus: latestConsensus,
              previewSamples: _waveformSnapshot(waveform),
            ),
          );
        }

        if (!bufferReady) {
          final prevStatus = currentStatus;
          currentStatus = DetectionStatus.buffering;

          // Log progress every second
          final secondsBuffered = bufferDuration.inSeconds;
          final totalSeconds = bufferWindow.inSeconds;
          if (prevStatus != DetectionStatus.buffering ||
              frame.sequence % 10 == 0) {
            _logger.info(
                'Buffering: ${secondsBuffered}s / ${totalSeconds}s (${buffer.length} frames)',
                source: 'Coordinator');
          }
          return;
        }

        if (elapsedSinceLastAnalysis < analysisInterval) {
          return;
        }
        elapsedSinceLastAnalysis = Duration.zero;

        if (currentStatus != DetectionStatus.analyzing) {
          _logger.info('Buffer full! Starting analysis...',
              source: 'Coordinator');
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

        // Debug: Log audio data stats
        final totalSamples = windowFrames.fold<int>(
            0, (sum, frame) => sum + frame.samples.length);
        final totalDuration =
            (totalSamples / streamConfig.sampleRate).toStringAsFixed(1);
        _logger.info(
          'Audio buffer: ${windowFrames.length} frames, $totalSamples samples ($totalDuration s)',
          source: 'Coordinator',
        );

        // Run algorithms in background with timeout to avoid hanging
        _logger.info('Starting background analysis...', source: 'Coordinator');

        List<BpmReading> readings = [];
        try {
          readings = await compute(
            _runAlgorithmsInIsolate,
            _AlgorithmParams(
              frames: windowFrames,
              context: context,
              algorithmIds: registry.algorithms.map((a) => a.id).toList(),
            ),
          ).timeout(
            const Duration(seconds: 5),
            onTimeout: () {
              _logger.warning(
                  'Algorithm timeout after 5s, using partial results',
                  source: 'Coordinator');
              return <BpmReading>[];
            },
          );
        } catch (e) {
          _logger.error('Algorithm error: $e', source: 'Coordinator');
          readings = [];
        }

        _logger.info(
            'Background analysis complete: ${readings.length} readings',
            source: 'Coordinator');

        if (readings.isEmpty) {
          _logger.warning('No readings returned from algorithms!',
              source: 'Coordinator');
        } else {
          for (final reading in readings) {
            _logger.info(
                '${reading.algorithmName} -> ${reading.bpm.toStringAsFixed(1)} BPM (confidence: ${reading.confidence.toStringAsFixed(2)})',
                source: 'Coordinator');
          }
        }

        final filtered = readings.whereType<BpmReading>().toList();
        final consensus = consensusEngine.combine(filtered);
        latestReadings = filtered;
        latestConsensus = consensus;

        if (consensus != null) {
          _logger.info(
              '✓ CONSENSUS: ${consensus.bpm.toStringAsFixed(1)} BPM (confidence: ${consensus.confidence.toStringAsFixed(2)})',
              source: 'Coordinator');
        } else {
          _logger.warning(
              'No consensus - need more readings (have ${filtered.length})',
              source: 'Coordinator');
        }
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

// Isolate support for background algorithm execution
class _AlgorithmParams {
  const _AlgorithmParams({
    required this.frames,
    required this.context,
    required this.algorithmIds,
  });

  final List<AudioFrame> frames;
  final DetectionContext context;
  final List<String> algorithmIds;
}

// Top-level function for isolate (must be top-level or static)
Future<List<BpmReading>> _runAlgorithmsInIsolate(
    _AlgorithmParams params) async {
  final results = <BpmReading>[];

  // Debug: Check if we have audio data
  final totalSamples =
      params.frames.fold<int>(0, (sum, frame) => sum + frame.samples.length);
  if (totalSamples == 0) {
    return results; // No audio data
  }

  for (final algorithmId in params.algorithmIds) {
    try {
      BpmDetectionAlgorithm? algorithm;

      // Instantiate algorithm based on ID
      switch (algorithmId) {
        case 'simple_onset':
          algorithm = SimpleOnsetAlgorithm();
          break;
        case 'autocorrelation':
          algorithm = AutocorrelationAlgorithm();
          break;
        case 'fft_spectrum':
          algorithm = FftSpectrumAlgorithm();
          break;
        case 'wavelet_energy':
          algorithm = WaveletEnergyAlgorithm();
          break;
        default:
          continue;
      }

      final reading = await algorithm.analyze(
        window: params.frames,
        context: params.context,
      );

      if (reading != null) {
        results.add(reading);
      }
    } catch (e) {
      // Skip failed algorithms - can't log in isolate
      continue;
    }
  }

  return results;
}
