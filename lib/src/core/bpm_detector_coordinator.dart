import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:bpm/src/algorithms/algorithm_registry.dart';
import 'package:bpm/src/algorithms/autocorrelation_algorithm.dart';
import 'package:bpm/src/algorithms/bpm_detection_algorithm.dart';
import 'package:bpm/src/algorithms/detection_context.dart';
import 'package:bpm/src/algorithms/dynamic_programming_beat_tracker.dart';
import 'package:bpm/src/algorithms/fft_spectrum_algorithm.dart';
import 'package:bpm/src/algorithms/simple_onset_algorithm.dart';
import 'package:bpm/src/algorithms/wavelet_energy_algorithm.dart';
import 'package:bpm/src/audio/audio_stream_source.dart';
import 'package:bpm/src/core/consensus_interface.dart';
import 'package:bpm/src/dsp/preprocessing_pipeline.dart';
import 'package:bpm/src/dsp/signal_utils.dart';
import 'package:bpm/src/models/bpm_models.dart';
import 'package:bpm/src/utils/app_logger.dart';
import 'package:flutter/foundation.dart';

final Float32List _emptyFloat32 = Float32List(0);

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
  final ConsensusInterface consensusEngine;
  final Duration bufferWindow;
  final Duration analysisInterval;
  final _logger = AppLogger();
  bool _waveletRunning = false;
  DateTime? _lastWaveletRun;
  List<BpmReading> _latestReadings = const [];
  ConsensusResult? _latestConsensus;
  BpmReading? _lastWaveletReading;
  final Map<String, BpmReading> _readingCache = <String, BpmReading>{};
  double? _latestPlpBpm;
  double? _latestPlpStrength;
  Float32List? _latestPlpTrace;
  Float32List? _latestPlpStrengthTrace;
  Float32List? _latestTempoAxis;
  Float32List? _latestTempogramTimes;
  List<Float32List> _latestTempogramMatrix = const [];

  Stream<BpmSummary> start({
    required AudioStreamConfig streamConfig,
    required DetectionContext context,
  }) async* {
    _logger.info('BpmDetectorCoordinator.start() called',
        source: 'Coordinator');
    _logger.info(
        'Stream config: ${streamConfig.sampleRate}Hz, ${streamConfig.channels} channels',
        source: 'Coordinator');

    // Reset all state for fresh start
    consensusEngine.reset();
    _latestReadings = const <BpmReading>[];
    _latestConsensus = null;
    _lastWaveletReading = null;
    _waveletRunning = false;
    _lastWaveletRun = null;
    _readingCache.clear();
    _latestPlpBpm = null;
    _latestPlpStrength = null;
    _latestPlpTrace = null;
    _latestPlpStrengthTrace = null;
    _latestTempoAxis = null;
    _latestTempogramTimes = null;
    _latestTempogramMatrix = const [];
    _logger.info('Consensus engine and coordinator state reset',
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
              readings: _latestReadings,
              consensus: _latestConsensus,
              previewSamples: _waveformSnapshot(waveform),
              plpBpm: _latestPlpBpm,
              plpStrength: _latestPlpStrength,
              plpTrace: _currentPlpTrace(),
              tempogram: _buildTempogramSnapshot(),
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
            readings: _latestReadings,
            consensus: _latestConsensus,
            previewSamples: _waveformSnapshot(waveform),
            plpBpm: _latestPlpBpm,
            plpStrength: _latestPlpStrength,
            plpTrace: _currentPlpTrace(),
            tempogram: _buildTempogramSnapshot(),
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

        final waveletEnabled = registry.algorithms
            .any((algorithm) => algorithm.id == 'wavelet_energy');
        final algorithmIds = waveletEnabled
            ? registry.algorithms
                .where((algorithm) => algorithm.id != 'wavelet_energy')
                .map((algorithm) => algorithm.id)
                .toList()
            : registry.algorithms.map((algorithm) => algorithm.id).toList();

        Map<String, Object?> isolateResult = const {};
        try {
          isolateResult = await compute(
            _runAlgorithmsInIsolate,
            _AlgorithmParams(
              frames: windowFrames,
              context: context,
              algorithmIds: algorithmIds,
            ),
          ).timeout(
            const Duration(seconds: 5),
            onTimeout: () {
              _logger.warning(
                  'Algorithm timeout after 5s, using partial results',
                  source: 'Coordinator');
              return const <String, Object?>{
                'readings': <BpmReading>[],
              };
            },
          );
        } catch (e) {
          _logger.error('Algorithm error: $e', source: 'Coordinator');
          isolateResult = const {
            'readings': <BpmReading>[],
          };
        }

        final readings = (isolateResult['readings'] as List?)
                ?.whereType<BpmReading>()
                .toList() ??
            <BpmReading>[];
        final plpBpm = isolateResult['plpBpm'] as double?;
        final plpStrength = isolateResult['plpStrength'] as double?;
        final plpTrace = isolateResult['plpTrace'] as Float32List?;
        final plpStrengthTrace =
            isolateResult['plpStrengthTrace'] as Float32List?;
        final tempoAxis = isolateResult['tempoAxis'] as Float32List?;
        final tempogramTimes = isolateResult['tempogramTimes'] as Float32List?;
        final tempogramMatrix =
            isolateResult['tempogramMatrix'] as List<Float32List>?;

        if (tempoAxis != null && tempoAxis.isNotEmpty) {
          _latestTempoAxis = tempoAxis;
        }
        if (tempogramTimes != null && tempogramTimes.isNotEmpty) {
          _latestTempogramTimes = tempogramTimes;
        }
        if (tempogramMatrix != null && tempogramMatrix.isNotEmpty) {
          _latestTempogramMatrix = tempogramMatrix;
        }
        if (plpTrace != null && plpTrace.isNotEmpty) {
          _latestPlpTrace = plpTrace;
        }
        if (plpStrengthTrace != null && plpStrengthTrace.isNotEmpty) {
          _latestPlpStrengthTrace = plpStrengthTrace;
        }
        if (plpBpm != null && plpBpm > 0) {
          _latestPlpBpm = plpBpm;
        }
        if (plpStrength != null) {
          _latestPlpStrength = plpStrength.clamp(0.0, 1.0);
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

        final filtered = readings.toList();
        for (final reading in filtered) {
          _readingCache[reading.algorithmId] = reading;
        }

        final consensusInputs = List<BpmReading>.from(filtered);
        if (_latestPlpBpm != null && _latestPlpBpm! > 0) {
          final double strength = (_latestPlpStrength ?? 0).clamp(0.0, 1.0);
          final plpConfidence = (0.4 + 0.45 * strength).clamp(0.0, 0.85);
          final plpReading = BpmReading(
            algorithmId: 'plp_tempogram',
            algorithmName: 'Tempogram PLP',
            bpm: _latestPlpBpm!.clamp(context.minBpm, context.maxBpm),
            confidence: plpConfidence,
            timestamp: DateTime.now().toUtc(),
            metadata: {
              'source': 'tempogram',
              'strength': strength,
            },
          );
          consensusInputs.add(plpReading);
        }

        final orderedReadings = <BpmReading>[];
        for (final algorithm in registry.algorithms) {
          final cached = _readingCache[algorithm.id];
          if (cached != null) {
            orderedReadings.add(cached);
          }
        }
        if (_lastWaveletReading != null) {
          orderedReadings.add(_lastWaveletReading!);
        }
        _latestReadings = orderedReadings;
        _latestConsensus = consensusEngine.combine(consensusInputs);

        if (_latestConsensus != null) {
          _logger.info(
              '✓ CONSENSUS: ${_latestConsensus!.bpm.toStringAsFixed(1)} BPM (confidence: ${_latestConsensus!.confidence.toStringAsFixed(2)})',
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
            readings: _latestReadings,
            consensus: _latestConsensus,
            previewSamples: _waveformSnapshot(waveform),
            plpBpm: _latestPlpBpm,
            plpStrength: _latestPlpStrength,
            plpTrace: _currentPlpTrace(),
            tempogram: _buildTempogramSnapshot(),
          ),
        );

        if (waveletEnabled) {
          _scheduleWaveletAnalysis(
            frames: windowFrames,
            context: context,
            baseReadings: filtered,
            baseConsensus: _latestConsensus,
            controller: controller,
            waveforms: _waveformSnapshot(waveform),
          );
        }
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

  void _scheduleWaveletAnalysis({
    required List<AudioFrame> frames,
    required DetectionContext context,
    required List<BpmReading> baseReadings,
    required ConsensusResult? baseConsensus,
    required StreamController<BpmSummary> controller,
    required List<double> waveforms,
  }) {
    final now = DateTime.now();
    if (_waveletRunning) {
      return;
    }
    if (_lastWaveletRun != null &&
        now.difference(_lastWaveletRun!) < const Duration(seconds: 2)) {
      return;
    }

    final waveletInput = _prepareWaveletInput(
      frames,
      sampleRate: context.sampleRate,
      targetDuration: const Duration(seconds: 8),
    );
    if (waveletInput.frames.isEmpty) {
      return;
    }
    _waveletRunning = true;
    _lastWaveletRun = now;
    _logger.info(
      'Wavelet scheduled with ${waveletInput.frames.first.samples.length} samples @ ${waveletInput.sampleRate}Hz',
      source: 'WaveletScheduler',
    );

    final params = _AlgorithmParams(
      frames: waveletInput.frames,
      context: _adjustDetectionContext(context, waveletInput.sampleRate),
      algorithmIds: const ['wavelet_energy'],
    );

    Future<void>.delayed(const Duration(milliseconds: 150), () async {
      try {
        final isolateWavelet = await compute(
          _runAlgorithmsInIsolate,
          params,
        ).timeout(
          const Duration(seconds: 8),
          onTimeout: () => const <String, Object?>{
            'readings': <BpmReading>[],
          },
        );

        final readings = (isolateWavelet['readings'] as List?)
                ?.whereType<BpmReading>()
                .toList() ??
            <BpmReading>[];

        if (readings.isEmpty) {
          return;
        }

        final merged = [
          ...baseReadings
              .where((reading) => reading.algorithmId != 'wavelet_energy'),
          ...readings,
        ];

        BpmReading? waveletReading;
        for (final reading in readings) {
          if (reading.algorithmId == 'wavelet_energy') {
            waveletReading = reading;
            break;
          }
        }
        if (waveletReading != null) {
          _lastWaveletReading = waveletReading;
          _readingCache[waveletReading.algorithmId] = waveletReading;
        }

        for (final reading in merged) {
          if (reading.algorithmId != 'wavelet_energy') {
            _readingCache[reading.algorithmId] = reading;
          }
        }

        final mergedWithWavelet = List<BpmReading>.from(merged);
        final orderedReadings = <BpmReading>[];
        for (final algorithm in registry.algorithms) {
          final cached = _readingCache[algorithm.id];
          if (cached != null) {
            orderedReadings.add(cached);
          }
        }
        if (_lastWaveletReading != null) {
          orderedReadings.add(_lastWaveletReading!);
        }
        _latestReadings = orderedReadings;
        final consensusInputs = List<BpmReading>.from(mergedWithWavelet);
        if (_latestPlpBpm != null && _latestPlpBpm! > 0) {
          final strength = (_latestPlpStrength ?? 0).clamp(0.0, 1.0);
          final plpConfidence = (0.4 + 0.45 * strength).clamp(0.0, 0.85);
          consensusInputs.add(
            BpmReading(
              algorithmId: 'plp_tempogram',
              algorithmName: 'Tempogram PLP',
              bpm: _latestPlpBpm!.clamp(context.minBpm, context.maxBpm),
              confidence: plpConfidence,
              timestamp: DateTime.now().toUtc(),
              metadata: {
                'source': 'tempogram',
                'strength': strength,
              },
            ),
          );
        }

        _latestConsensus =
            consensusEngine.combine(consensusInputs) ?? baseConsensus;

        if (!controller.isClosed) {
          controller.add(
            BpmSummary(
              status: DetectionStatus.streamingResults,
              readings: merged,
              consensus: _latestConsensus,
              previewSamples: waveforms,
              plpBpm: _latestPlpBpm,
              plpStrength: _latestPlpStrength,
              plpTrace: _currentPlpTrace(),
              tempogram: _buildTempogramSnapshot(),
            ),
          );
        }
      } catch (error) {
        _logger.warning('Wavelet analysis failed: $error',
            source: 'Coordinator');
      } finally {
        _waveletRunning = false;
      }
    });
  }

  TempogramSnapshot? _buildTempogramSnapshot() {
    if (_latestTempoAxis == null ||
        _latestTempogramTimes == null ||
        _latestPlpTrace == null ||
        _latestTempogramMatrix.isEmpty) {
      return null;
    }
    final dominant = _latestPlpTrace!;
    Float32List strength = _emptyFloat32;
    if (_latestPlpStrengthTrace != null &&
        _latestPlpStrengthTrace!.isNotEmpty) {
      strength = _latestPlpStrengthTrace!;
    } else if (dominant.isNotEmpty) {
      strength = Float32List(dominant.length);
    }
    return TempogramSnapshot(
      matrix: _latestTempogramMatrix,
      tempoAxis: _latestTempoAxis!,
      times: _latestTempogramTimes!,
      dominantTempo: dominant,
      dominantStrength: strength,
    );
  }

  List<double> _currentPlpTrace() {
    if (_latestPlpTrace == null || _latestPlpTrace!.isEmpty) {
      return const [];
    }
    return _latestPlpTrace!.toList(growable: false);
  }
}

({List<AudioFrame> frames, int sampleRate}) _prepareWaveletInput(
  List<AudioFrame> frames, {
  required int sampleRate,
  required Duration targetDuration,
}) {
  if (frames.isEmpty) {
    return (frames: const [], sampleRate: sampleRate);
  }

  final minSamples = sampleRate * 3;
  final maxSamples =
      math.max(sampleRate * targetDuration.inSeconds, minSamples);
  final collected = <double>[];
  var gathered = 0;

  for (var i = frames.length - 1; i >= 0 && gathered < maxSamples; i--) {
    final frame = frames[i];
    final remaining = maxSamples - gathered;
    if (frame.samples.length <= remaining) {
      collected.insertAll(0, frame.samples);
      gathered += frame.samples.length;
    } else {
      final start = frame.samples.length - remaining;
      collected.insertAll(0, frame.samples.sublist(start));
      gathered = maxSamples;
    }
  }

  if (collected.length < minSamples) {
    return (frames: const [], sampleRate: sampleRate);
  }

  final targetSampleRate = 4000;
  final downsampleFactor = math.max(1, (sampleRate / targetSampleRate).round());
  final effectiveSampleRate = (sampleRate / downsampleFactor).round();
  final downsampled = SignalUtils.downsample(collected, downsampleFactor);

  final frame = AudioFrame(
    samples: downsampled,
    sampleRate: effectiveSampleRate,
    channels: 1,
    sequence: frames.last.sequence,
  );

  return (frames: [frame], sampleRate: effectiveSampleRate);
}

DetectionContext _adjustDetectionContext(
    DetectionContext base, int sampleRate) {
  if (sampleRate == base.sampleRate) {
    return base;
  }
  return DetectionContext(
    sampleRate: sampleRate,
    minBpm: base.minBpm,
    maxBpm: base.maxBpm,
    windowDuration: base.windowDuration,
  );
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
Future<Map<String, Object?>> _runAlgorithmsInIsolate(
    _AlgorithmParams params) async {
  final results = <BpmReading>[];

  // Debug: Check if we have audio data
  final totalSamples =
      params.frames.fold<int>(0, (sum, frame) => sum + frame.samples.length);
  if (totalSamples == 0) {
    return {
      'readings': results,
    };
  }

  // PHASE 1: Run preprocessing pipeline ONCE for all algorithms
  PreprocessedSignal signal;
  try {
    const pipeline = PreprocessingPipeline();
    signal = pipeline.process(
      window: params.frames,
      context: params.context,
    );
  } catch (e) {
    // Preprocessing failed, return empty results
    return {
      'readings': results,
    };
  }

  // PHASE 2: Run each algorithm on the preprocessed signal
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
        case 'dp_beat_tracker':
          algorithm = DynamicProgrammingBeatTracker();
          break;
        default:
          continue;
      }

      final reading = await algorithm.analyze(
        signal: signal,
      );

      if (reading != null) {
        results.add(reading);
      }
    } catch (e) {
      // Skip failed algorithms - can't log in isolate
      continue;
    }
  }

  double? plpBpm;
  double? plpStrength;
  Float32List? plpTrace;
  final dominantTrace = signal.dominantTempoCurve;
  if (dominantTrace.isNotEmpty) {
    plpTrace = dominantTrace;
    plpBpm = dominantTrace[dominantTrace.length - 1];
    final strengthTrace = signal.dominantTempoStrength;
    if (strengthTrace.isNotEmpty) {
      plpStrength = strengthTrace[strengthTrace.length - 1];
    }
  }

  return {
    'readings': results,
    'plpBpm': plpBpm,
    'plpStrength': plpStrength,
    'plpTrace': plpTrace,
    'plpStrengthTrace': signal.dominantTempoStrength,
    'tempoAxis': signal.tempoAxis,
    'tempogramTimes': signal.tempogramTimes,
    'tempogramMatrix': signal.tempogram,
  };
}
