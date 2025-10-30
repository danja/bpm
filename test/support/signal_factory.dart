import 'dart:math';

import 'package:bpm/src/models/bpm_models.dart';

/// Factory for generating synthetic audio signals for testing BPM detection.
class SignalFactory {
  const SignalFactory._();

  /// Generates a synthetic beat signal with harmonics and envelope.
  ///
  /// Creates a periodic signal with fundamental frequency matching BPM,
  /// including harmonics and amplitude modulation to simulate rhythmic content.
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

  /// Generates a click track with sharp transients at specified BPM.
  ///
  /// Creates impulse-like clicks at regular intervals matching the tempo.
  /// More realistic for testing onset detection.
  static List<double> clickTrack({
    required double bpm,
    required int sampleRate,
    required Duration duration,
    double noiseAmplitude = 0.0,
  }) {
    final totalSamples =
        (duration.inMilliseconds / 1000 * sampleRate).round();
    final samples = List<double>.filled(totalSamples, 0);
    final beatInterval = 60.0 / bpm; // seconds per beat
    final clickWidth = 0.005; // 5ms click width
    final random = Random(42);

    double nextBeatTime = 0.0;
    for (var i = 0; i < totalSamples; i++) {
      final t = i / sampleRate;

      // Add click if we're at a beat position
      if ((t - nextBeatTime).abs() < clickWidth) {
        final relativePos = (t - nextBeatTime) / clickWidth;
        // Triangular pulse
        samples[i] = 1.0 - relativePos.abs();
      }

      // Move to next beat
      if (t >= nextBeatTime + beatInterval) {
        nextBeatTime += beatInterval;
      }

      // Add noise
      if (noiseAmplitude > 0) {
        samples[i] += (random.nextDouble() * 2 - 1) * noiseAmplitude;
      }
    }

    return samples;
  }

  /// Generates a complex rhythm pattern with variable beat intensities.
  ///
  /// Creates beats with different amplitudes following a pattern.
  /// Useful for testing algorithms with syncopated rhythms.
  static List<double> complexRhythm({
    required double bpm,
    required int sampleRate,
    required Duration duration,
    List<double> beatPattern = const [1.0, 0.5, 0.75, 0.5],
    double noiseAmplitude = 0.05,
  }) {
    final totalSamples =
        (duration.inMilliseconds / 1000 * sampleRate).round();
    final samples = List<double>.filled(totalSamples, 0);
    final beatInterval = 60.0 / bpm;
    final random = Random(42);

    int patternIndex = 0;
    double nextBeatTime = 0.0;

    for (var i = 0; i < totalSamples; i++) {
      final t = i / sampleRate;

      if ((t - nextBeatTime).abs() < 0.01) {
        // Within 10ms of beat
        final intensity = beatPattern[patternIndex % beatPattern.length];
        final fundamental = bpm / 60;
        final beatPhase = (t - nextBeatTime) * 100; // 0-1 over 10ms

        // Short percussive burst
        samples[i] += intensity *
            sin(2 * pi * fundamental * beatPhase) *
            exp(-beatPhase * 5);
      }

      if (t >= nextBeatTime + beatInterval) {
        nextBeatTime += beatInterval;
        patternIndex++;
      }

      // Add noise
      samples[i] += (random.nextDouble() * 2 - 1) * noiseAmplitude;
    }

    return samples;
  }

  /// Generates synthetic music-like signal with bass and harmonics.
  ///
  /// More realistic than simple beat signals, includes low-frequency
  /// bass pattern and harmonic content.
  static List<double> syntheticMusic({
    required double bpm,
    required int sampleRate,
    required Duration duration,
    bool includeHarmonics = true,
    bool includeBass = true,
    double noiseAmplitude = 0.1,
  }) {
    final totalSamples =
        (duration.inMilliseconds / 1000 * sampleRate).round();
    final samples = List<double>.filled(totalSamples, 0);
    final fundamental = bpm / 60;
    final random = Random(42);

    for (var i = 0; i < totalSamples; i++) {
      final t = i / sampleRate;
      double value = 0.0;

      // Main rhythmic component
      value += sin(2 * pi * fundamental * t);

      // Bass (sub-harmonic)
      if (includeBass) {
        value += 0.6 * sin(2 * pi * fundamental * 0.5 * t);
      }

      // Harmonics
      if (includeHarmonics) {
        value += 0.3 * sin(4 * pi * fundamental * t);
        value += 0.15 * sin(6 * pi * fundamental * t);
      }

      // Amplitude modulation (beat envelope)
      final envelope = pow(sin(pi * fundamental * t).abs(), 0.5).toDouble();
      value *= envelope;

      // Add some variation
      value += 0.1 * sin(2 * pi * fundamental * 1.5 * t);

      // Noise
      value += (random.nextDouble() * 2 - 1) * noiseAmplitude;

      samples[i] = value * 0.5; // Scale down
    }

    return samples;
  }

  /// Generates white noise signal.
  static List<double> whiteNoise({
    required Duration duration,
    required int sampleRate,
    double amplitude = 0.5,
  }) {
    final totalSamples =
        (duration.inMilliseconds / 1000 * sampleRate).round();
    final random = Random(42);
    return List<double>.generate(
      totalSamples,
      (_) => (random.nextDouble() * 2 - 1) * amplitude,
    );
  }

  /// Generates silence (all zeros).
  static List<double> silence({
    required Duration duration,
    required int sampleRate,
  }) {
    final totalSamples =
        (duration.inMilliseconds / 1000 * sampleRate).round();
    return List<double>.filled(totalSamples, 0.0);
  }

  /// Generates a pure sine wave at specified frequency.
  static List<double> sineWave({
    required double frequency,
    required Duration duration,
    required int sampleRate,
    double amplitude = 0.5,
  }) {
    final totalSamples =
        (duration.inMilliseconds / 1000 * sampleRate).round();
    final samples = List<double>.filled(totalSamples, 0);

    for (var i = 0; i < totalSamples; i++) {
      final t = i / sampleRate;
      samples[i] = amplitude * sin(2 * pi * frequency * t);
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
