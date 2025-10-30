import 'package:bpm/src/algorithms/detection_context.dart';
import 'package:bpm/src/dsp/preprocessing_pipeline.dart';
import 'package:test/test.dart';

import '../support/signal_factory.dart';

void main() {
  test('Preprocessing pipeline creates valid output', () {
    const sampleRate = 44100;
    const context = DetectionContext(
      sampleRate: sampleRate,
      minBpm: 60,
      maxBpm: 180,
      windowDuration: Duration(seconds: 5),
    );

    final samples = SignalFactory.beatSignal(
      bpm: 120,
      sampleRate: sampleRate,
      duration: const Duration(seconds: 5),
    );

    final frames = SignalFactory.framesFromSamples(
      samples,
      sampleRate: sampleRate,
    );

    const pipeline = PreprocessingPipeline();
    final signal = pipeline.process(
      window: frames,
      context: context,
    );

    // Verify basic properties
    expect(signal.rawSamples.length, samples.length);
    expect(signal.normalizedSamples.length, samples.length);
    expect(signal.filteredSamples.length, samples.length);
    expect(signal.onsetEnvelope.length, greaterThan(0));
    expect(signal.samples8kHz.length, greaterThan(0));
    expect(signal.samples400Hz.length, greaterThan(0));
    expect(signal.originalSampleRate, sampleRate);

    // Verify downsampling ratios are reasonable
    final ratio8k = signal.rawSamples.length / signal.samples8kHz.length;
    expect(ratio8k, closeTo(sampleRate / 8000, 1.0));

    final ratio400 = signal.rawSamples.length / signal.samples400Hz.length;
    expect(ratio400, closeTo(sampleRate / 400, 5.0));

    print('Preprocessing completed:');
    print('  Raw samples: ${signal.rawSamples.length}');
    print('  Onset envelope: ${signal.onsetEnvelope.length}');
    print('  8kHz samples: ${signal.samples8kHz.length}');
    print('  400Hz samples: ${signal.samples400Hz.length}');
    print('  Noise floor: ${signal.noiseFloor}');
  });
}
