import 'package:bpm/src/algorithms/detection_context.dart';
import 'package:bpm/src/algorithms/fft_spectrum_algorithm.dart';
import 'package:bpm/src/algorithms/wavelet_energy_algorithm.dart';
import 'package:bpm/src/dsp/preprocessing_pipeline.dart';
import 'package:test/test.dart';

import '../support/signal_factory.dart';

void main() {
  const sampleRate = 44100;
  const detectionContext = DetectionContext(
    sampleRate: sampleRate,
    minBpm: 60,
    maxBpm: 180,
    windowDuration: Duration(seconds: 6),
  );

  PreprocessedSignal preprocessSignal(List<double> samples) {
    final frames = SignalFactory.framesFromSamples(
      samples,
      sampleRate: sampleRate,
    );
    const pipeline = PreprocessingPipeline();
    return pipeline.process(
      window: frames,
      context: detectionContext,
    );
  }

  test('FFT spectrum algorithm approximates planted tempo', () async {
    const targetBpm = 128.0;
    final samples = SignalFactory.beatSignal(
      bpm: targetBpm,
      sampleRate: sampleRate,
      duration: const Duration(seconds: 5),
    );

    final preprocessed = preprocessSignal(samples);
    final algorithm = FftSpectrumAlgorithm();

    final reading = await algorithm.analyze(
      signal: preprocessed,
    );

    expect(reading, isNotNull);
    expect((reading!.bpm - targetBpm).abs(), lessThan(3));
    expect(reading.confidence, greaterThan(0.2));
  });

  test('Wavelet energy algorithm surfaces tempo band within tolerance', () async {
    const targetBpm = 96.0;
    final samples = SignalFactory.beatSignal(
      bpm: targetBpm,
      sampleRate: sampleRate,
      duration: const Duration(seconds: 5),
      noiseAmplitude: 0.1,
    );

    final preprocessed = preprocessSignal(samples);
    final algorithm = WaveletEnergyAlgorithm(); // Now defaults to 2 levels

    final reading = await algorithm.analyze(
      signal: preprocessed,
    );

    printOnFailure('Wavelet reading: ${reading?.bpm}, metadata: ${reading?.metadata}');
    expect(reading, isNotNull);
    expect((reading!.bpm - targetBpm).abs(), lessThan(4));
    expect(reading.confidence, greaterThan(0));
  });
}
