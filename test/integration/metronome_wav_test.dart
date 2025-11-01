import 'dart:io';
import 'dart:math' as math;

import 'package:bpm/src/algorithms/autocorrelation_algorithm.dart';
import 'package:bpm/src/algorithms/bpm_detection_algorithm.dart';
import 'package:bpm/src/algorithms/detection_context.dart';
import 'package:bpm/src/algorithms/dynamic_programming_beat_tracker.dart';
import 'package:bpm/src/algorithms/fft_spectrum_algorithm.dart';
import 'package:bpm/src/algorithms/simple_onset_algorithm.dart';
import 'package:bpm/src/algorithms/wavelet_energy_algorithm.dart';
import 'package:bpm/src/core/robust_consensus_engine.dart';
import 'package:bpm/src/dsp/preprocessing_pipeline.dart';
import 'package:bpm/src/models/bpm_models.dart';
import 'package:test/test.dart';

import '../support/signal_factory.dart';
import '../support/wav_loader.dart';

void main() {
  final fixtures = _loadFixtures();
  group('WAV fixtures', () {
    for (final fixture in fixtures) {
      group('${fixture.name} (${fixture.expectedBpm.toStringAsFixed(1)} BPM)',
          () {
        for (final config in _algorithmConfigs) {
          test('${config.label} matches fixture', () async {
            final algorithm = config.builder();
            final reading = await algorithm.analyze(signal: fixture.signal);
            printOnFailure(
              '${config.label} reading for ${fixture.name}:\n'
              '  Expected: ${fixture.expectedBpm}\n'
              '  BPM: ${reading?.bpm}\n'
              '  Confidence: ${reading?.confidence}\n'
              '  Metadata: ${reading?.metadata}',
            );
            expect(reading, isNotNull,
                reason: '${config.label} produced null reading');
            final allowedError = math.max(
              config.tolerance,
              fixture.expectedBpm * config.percentTolerance,
            );
            expect(
              (reading!.bpm - fixture.expectedBpm).abs(),
              lessThan(allowedError),
              reason:
                  '${config.label} BPM off by ${(reading.bpm - fixture.expectedBpm).abs()} (allowed ±${allowedError.toStringAsFixed(2)})',
            );
            expect(
              reading.confidence,
              greaterThan(config.minConfidence),
              reason:
                  '${config.label} confidence too low (${reading.confidence})',
            );
          });
        }

        test('Robust consensus aligns with fixture', () async {
          final readings = <BpmReading>[];
          for (final config in _algorithmConfigs) {
            final reading =
                await config.builder().analyze(signal: fixture.signal);
            if (reading != null) {
              readings.add(reading);
            }
          }

          expect(
            readings,
            isNotEmpty,
            reason: 'No algorithm produced a reading for ${fixture.name}',
          );

          final engine = RobustConsensusEngine();
          engine.reset();
          final result = engine.combine(readings);

          expect(result, isNotNull,
              reason: 'Consensus engine returned null for ${fixture.name}');
          expect(
            (result!.bpm - fixture.expectedBpm).abs(),
            lessThan(2.5),
            reason:
                'Consensus BPM off by ${(result.bpm - fixture.expectedBpm).abs()}',
          );
          expect(
            result.confidence,
            greaterThan(0.25),
            reason:
                'Consensus confidence too low (${result.confidence}) for ${fixture.name}',
          );
        });
      });
    }
  });
}

double _parseBpmFromFilename(String path) {
  final filename = path.split(Platform.pathSeparator).last;
  final lower = filename.toLowerCase();
  if (!lower.endsWith('.wav')) {
    throw FormatException('WAV filename expected: $filename');
  }
  final base = filename.substring(0, filename.length - 4);
  final underscoreIndex = base.lastIndexOf('_');
  if (underscoreIndex == -1 || underscoreIndex == base.length - 1) {
    throw FormatException('Filename must end with _BPM: $filename');
  }
  final bpmPart = base.substring(underscoreIndex + 1);
  final bpm = double.tryParse(bpmPart);
  if (bpm == null) {
    throw FormatException('Invalid BPM in filename: $filename');
  }
  return bpm;
}

class _WavFixture {
  const _WavFixture({
    required this.name,
    required this.expectedBpm,
    required this.signal,
  });

  final String name;
  final double expectedBpm;
  final PreprocessedSignal signal;
}

class _AlgorithmConfig {
  const _AlgorithmConfig({
    required this.id,
    required this.label,
    required this.tolerance,
    required this.minConfidence,
    required this.builder,
    required this.percentTolerance,
  });

  final String id;
  final String label;
  final double tolerance;
  final double minConfidence;
  final BpmDetectionAlgorithm Function() builder;
  final double percentTolerance;
}

final _algorithmConfigs = <_AlgorithmConfig>[
  _AlgorithmConfig(
    id: 'simple_onset',
    label: 'SimpleOnset',
    tolerance: 2.5,
    minConfidence: 0.2,
    builder: SimpleOnsetAlgorithm.new,
    percentTolerance: 0.06,
  ),
  _AlgorithmConfig(
    id: 'autocorrelation',
    label: 'Autocorrelation',
    tolerance: 2.5,
    minConfidence: 0.15,
    builder: AutocorrelationAlgorithm.new,
    percentTolerance: 0.06,
  ),
  _AlgorithmConfig(
    id: 'fft_spectrum',
    label: 'FFT spectrum',
    tolerance: 2.5,
    minConfidence: 0.15,
    builder: FftSpectrumAlgorithm.new,
    percentTolerance: 0.08,
  ),
  _AlgorithmConfig(
    id: 'dp_beat_tracker',
    label: 'Dynamic beat tracker',
    tolerance: 3.0,
    minConfidence: 0.15,
    builder: DynamicProgrammingBeatTracker.new,
    percentTolerance: 0.08,
  ),
  _AlgorithmConfig(
    id: 'wavelet_energy',
    label: 'Wavelet energy',
    tolerance: 3.0,
    minConfidence: 0.1,
    builder: () => WaveletEnergyAlgorithm(levels: 2),
    percentTolerance: 0.2,
  ),
];

List<_WavFixture> _loadFixtures() {
  final directory = Directory('data');
  if (!directory.existsSync()) {
    throw StateError('Expected data directory at ${directory.path}');
  }

  final pipeline = const PreprocessingPipeline();
  final fixtures = <_WavFixture>[];

  for (final entity in directory.listSync().whereType<File>()) {
    if (!entity.path.toLowerCase().endsWith('.wav')) {
      continue;
    }

    final bpm = _parseBpmFromFilename(entity.path);
    final wav = loadPcm16Wav(entity.path);
    final frames = SignalFactory.framesFromSamples(
      wav.samples,
      sampleRate: wav.sampleRate,
    );
    var minBpm = math.max(40.0, bpm - 40);
    var maxBpm = math.min(260.0, bpm + 40);
    if (maxBpm <= minBpm) {
      maxBpm = minBpm + 40;
    }

    final context = DetectionContext(
      sampleRate: wav.sampleRate,
      minBpm: minBpm,
      maxBpm: maxBpm,
      windowDuration: Duration(
        microseconds: (wav.samples.length / wav.sampleRate * 1000000).round(),
      ),
    );
    final signal = pipeline.process(window: frames, context: context);
    fixtures.add(
      _WavFixture(
        name: entity.uri.pathSegments.last,
        expectedBpm: bpm,
        signal: signal,
      ),
    );
  }

  if (fixtures.isEmpty) {
    throw StateError('No WAV fixtures found in ${directory.path}');
  }

  return fixtures;
}
