import 'package:bpm/src/algorithms/detection_context.dart';
import 'package:bpm/src/algorithms/simple_onset_algorithm.dart';
import 'package:bpm/src/dsp/preprocessing_pipeline.dart';
import 'package:test/test.dart';

import '../support/signal_factory.dart';

void main() {
  test('SimpleOnset algorithm with preprocessing detects 120 BPM', () async {
    const sampleRate = 44100;
    const targetBpm = 120.0;

    final samples = SignalFactory.beatSignal(
      bpm: targetBpm,
      sampleRate: sampleRate,
      duration: const Duration(seconds: 5),
    );

    final frames = SignalFactory.framesFromSamples(
      samples,
      sampleRate: sampleRate,
    );

    const context = DetectionContext(
      sampleRate: sampleRate,
      minBpm: 60,
      maxBpm: 180,
      windowDuration: Duration(seconds: 5),
    );

    const pipeline = PreprocessingPipeline();
    final signal = pipeline.process(
      window: frames,
      context: context,
    );

    final algorithm = SimpleOnsetAlgorithm();
    final reading = await algorithm.analyze(signal: signal);

    printOnFailure(
      'SimpleOnset result: ${reading?.bpm} BPM (target: $targetBpm)\n'
      '  Confidence: ${reading?.confidence}\n'
      '  Metadata: ${reading?.metadata}',
    );

    expect(reading, isNotNull);
    expect((reading!.bpm - targetBpm).abs(), lessThan(5.0));
    expect(reading.confidence, greaterThan(0.1));
  });
}
