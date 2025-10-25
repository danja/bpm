import 'package:bpm/src/algorithms/detection_context.dart';
import 'package:bpm/src/algorithms/fft_spectrum_algorithm.dart';
import 'package:bpm/src/algorithms/wavelet_energy_algorithm.dart';
import 'package:bpm/src/models/bpm_models.dart';
import 'package:test/test.dart';

import '../support/signal_factory.dart';

void main() {
  const sampleRate = 44100;
  const detectionContext = DetectionContext(
    sampleRate: sampleRate,
    minBpm: 60,
    maxBpm: 180,
    windowDuration: Duration(seconds: 12),
  );

  List<AudioFrame> _windowFromSignal(List<double> samples) =>
      SignalFactory.framesFromSamples(
        samples,
        sampleRate: sampleRate,
      );

  test('FFT spectrum algorithm approximates planted tempo', () async {
    const targetBpm = 128.0;
    final signal = SignalFactory.beatSignal(
      bpm: targetBpm,
      sampleRate: sampleRate,
      duration: const Duration(seconds: 12),
    );

    final frames = _windowFromSignal(signal);
    final algorithm = FftSpectrumAlgorithm();

    final reading = await algorithm.analyze(
      window: frames,
      context: detectionContext,
    );

    expect(reading, isNotNull);
    expect((reading!.bpm - targetBpm).abs(), lessThan(3));
    expect(reading.confidence, greaterThan(0.2));
  });

  test('Wavelet energy algorithm surfaces tempo band within tolerance', () async {
    const targetBpm = 96.0;
    final signal = SignalFactory.beatSignal(
      bpm: targetBpm,
      sampleRate: sampleRate,
      duration: const Duration(seconds: 14),
      noiseAmplitude: 0.1,
    );

    final frames = _windowFromSignal(signal);
    final algorithm = WaveletEnergyAlgorithm(levels: 4);

    final reading = await algorithm.analyze(
      window: frames,
      context: detectionContext,
    );

    expect(reading, isNotNull);
    expect((reading!.bpm - targetBpm).abs(), lessThan(4));
    expect(reading.confidence, greaterThan(0));
  });
}
