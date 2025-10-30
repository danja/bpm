import 'package:bpm/src/algorithms/detection_context.dart';
import 'package:bpm/src/algorithms/simple_onset_algorithm.dart';
import 'package:bpm/src/dsp/preprocessing_pipeline.dart';
import 'package:test/test.dart';

import '../support/signal_factory.dart';

void main() {
  const sampleRate = 44100;
  const pipeline = PreprocessingPipeline();

  final scenarios = <_Scenario>[
    _Scenario(
      name: 'steady beat 120',
      targetBpm: 120,
      minBpm: 80,
      maxBpm: 180,
      tolerance: 3.0,
      minConfidence: 0.25,
      samplesBuilder: (sr) => SignalFactory.beatSignal(
        bpm: 120,
        sampleRate: sr,
        duration: const Duration(seconds: 5),
      ),
    ),
    _Scenario(
      name: 'noisy beat 105',
      targetBpm: 105,
      minBpm: 70,
      maxBpm: 160,
      tolerance: 4.0,
      minConfidence: 0.18,
      samplesBuilder: (sr) => SignalFactory.beatSignal(
        bpm: 105,
        sampleRate: sr,
        duration: const Duration(seconds: 5),
        noiseAmplitude: 0.12,
      ),
    ),
    _Scenario(
      name: 'click track 180',
      targetBpm: 180,
      minBpm: 110,
      maxBpm: 220,
      tolerance: 4.0,
      minConfidence: 0.2,
      samplesBuilder: (sr) => SignalFactory.clickTrack(
        bpm: 180,
        sampleRate: sr,
        duration: const Duration(seconds: 5),
        noiseAmplitude: 0.02,
      ),
    ),
    _Scenario(
      name: 'complex rhythm 92',
      targetBpm: 92,
      minBpm: 60,
      maxBpm: 150,
      tolerance: 4.5,
      minConfidence: 0.15,
      samplesBuilder: (sr) => SignalFactory.complexRhythm(
        bpm: 92,
        sampleRate: sr,
        duration: const Duration(seconds: 5),
      ),
    ),
    _Scenario(
      name: 'synthetic music 135',
      targetBpm: 135,
      minBpm: 80,
      maxBpm: 200,
      tolerance: 4.0,
      minConfidence: 0.12,
      samplesBuilder: (sr) => SignalFactory.syntheticMusic(
        bpm: 135,
        sampleRate: sr,
        duration: const Duration(seconds: 5),
        noiseAmplitude: 0.12,
      ),
    ),
  ];

  for (final scenario in scenarios) {
    test('SimpleOnset ${scenario.name}', () async {
      final samples = scenario.samplesBuilder(sampleRate);
      final frames = SignalFactory.framesFromSamples(
        samples,
        sampleRate: sampleRate,
      );

      final context = DetectionContext(
        sampleRate: sampleRate,
        minBpm: scenario.minBpm,
        maxBpm: scenario.maxBpm,
        windowDuration: const Duration(seconds: 5),
      );

      final signal = pipeline.process(
        window: frames,
        context: context,
      );

      final algorithm = SimpleOnsetAlgorithm();
      final reading = await algorithm.analyze(signal: signal);

      printOnFailure(
        'Scenario ${scenario.name}\n'
        '  Target: ${scenario.targetBpm}\n'
        '  Reading: ${reading?.bpm}\n'
        '  Confidence: ${reading?.confidence}\n'
        '  Metadata: ${reading?.metadata}',
      );

      expect(reading, isNotNull);
      expect(
        (reading!.bpm - scenario.targetBpm).abs(),
        lessThan(scenario.tolerance),
      );
      expect(reading.confidence, greaterThan(scenario.minConfidence));
    });
  }
}

class _Scenario {
  const _Scenario({
    required this.name,
    required this.targetBpm,
    required this.samplesBuilder,
    this.tolerance = 4.0,
    this.minConfidence = 0.1,
    this.minBpm = 50,
    this.maxBpm = 200,
  });

  final String name;
  final double targetBpm;
  final List<double> Function(int sampleRate) samplesBuilder;
  final double tolerance;
  final double minConfidence;
  final double minBpm;
  final double maxBpm;
}
