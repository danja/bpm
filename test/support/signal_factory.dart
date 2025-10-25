import 'dart:math';

import 'package:bpm/src/models/bpm_models.dart';

class SignalFactory {
  const SignalFactory._();

  static List<double> beatSignal({
    required double bpm,
    required int sampleRate,
    required Duration duration,
    double noiseAmplitude = 0.05,
  }) {
    final totalSamplesFloat =
        duration.inMilliseconds / 1000 * sampleRate;
    final totalSamples =
        totalSamplesFloat.round().clamp(1, 1 << 22).toInt();
    final samples = List<double>.filled(totalSamples, 0);
    final fundamental = bpm / 60;
    final random = Random(42);

    for (var i = 0; i < totalSamples; i++) {
      final t = i / sampleRate;
      final pulse = sin(2 * pi * fundamental * t) +
          0.5 * sin(4 * pi * fundamental * t) +
          0.25 * sin(6 * pi * fundamental * t);
      final envelope = (sin(pi * fundamental * t).abs());
      final noise = (random.nextDouble() * 2 - 1) * noiseAmplitude;
      samples[i] = (pulse * envelope) + noise;
    }

    return samples;
  }

  static List<AudioFrame> framesFromSamples(
    List<double> samples, {
    required int sampleRate,
    int frameSize = 2048,
  }) {
    final frames = <AudioFrame>[];
    var sequence = 0;
    for (var i = 0; i < samples.length; i += frameSize) {
      final chunk = samples.sublist(i, i + frameSize > samples.length ? samples.length : i + frameSize);
      frames.add(
        AudioFrame(
          samples: chunk,
          sampleRate: sampleRate,
          channels: 1,
          sequence: sequence++,
        ),
      );
    }
    return frames;
  }
}
