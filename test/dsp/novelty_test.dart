import 'package:bpm/src/algorithms/detection_context.dart';
import 'package:bpm/src/dsp/novelty.dart';
import 'package:test/test.dart';

import '../support/signal_factory.dart';

void main() {
  group('NoveltyComputer', () {
    test('produces stable novelty curve for rhythmic audio', () {
      const sampleRate = 44100;
      final samples = SignalFactory.syntheticMusic(
        bpm: 128,
        sampleRate: sampleRate,
        duration: const Duration(seconds: 4),
      );
      final frames = SignalFactory.framesFromSamples(
        samples,
        sampleRate: sampleRate,
      );
      final context = DetectionContext(
        sampleRate: sampleRate,
        minBpm: 60,
        maxBpm: 180,
        windowDuration: const Duration(seconds: 4),
      );

      final computer = NoveltyComputer();
      final result = computer.compute(
        frames: frames,
        context: context,
      );

      expect(result.curve.length, greaterThan(10));
      expect(result.featureRate, closeTo(sampleRate / computer.config.hopSize, 1e-6));
      expect(result.curve.any((value) => value > 0), isTrue);
    });

    test('handles narrow spectra without exceeding filter bounds', () {
      const sampleRate = 8000;
      final samples = SignalFactory.beatSignal(
        bpm: 100,
        sampleRate: sampleRate,
        duration: const Duration(seconds: 2),
        noiseAmplitude: 0.02,
      );
      final frames = SignalFactory.framesFromSamples(
        samples,
        sampleRate: sampleRate,
        frameSize: 256,
      );
      final context = DetectionContext(
        sampleRate: sampleRate,
        minBpm: 60,
        maxBpm: 180,
        windowDuration: const Duration(seconds: 2),
      );

      final computer = NoveltyComputer(
        config: const NoveltyConfig(
          windowSize: 256,
          hopSize: 128,
          melBands: 48,
          minFrequency: 40,
          maxFrequency: 4000,
          useLogCompression: true,
          useMelFilter: true,
        ),
      );

      final result = computer.compute(
        frames: frames,
        context: context,
      );

      expect(result.curve.length, greaterThanOrEqualTo(0));
      expect(result.featureRate, greaterThanOrEqualTo(0));
    });
  });
}
