import 'dart:math';
import 'dart:typed_data';

import 'package:bpm/src/algorithms/bpm_detection_algorithm.dart';
import 'package:bpm/src/algorithms/detection_context.dart';
import 'package:bpm/src/dsp/signal_utils.dart';
import 'package:bpm/src/models/bpm_models.dart';
import 'package:fftea/fftea.dart';

class FftSpectrumAlgorithm extends BpmDetectionAlgorithm {
  FftSpectrumAlgorithm({
    this.minMagnitudeRatio = 0.2,
  });

  final double minMagnitudeRatio;

  @override
  String get id => 'fft_spectrum';

  @override
  String get label => 'FFT Spectrum';

  @override
  Duration get preferredWindow => const Duration(seconds: 12);

  @override
  Future<BpmReading?> analyze({
    required List<AudioFrame> window,
    required DetectionContext context,
  }) async {
    if (window.isEmpty) return null;

    final samples = SignalUtils.normalize(
      window.expand((frame) => frame.samples).toList(),
    );

    if (samples.length < context.sampleRate) {
      return null;
    }

    final desiredSamples =
        min(samples.length, context.sampleRate * context.windowDuration.inSeconds);
    final fftSize = SignalUtils.nextPowerOfTwo(max(desiredSamples, 1024));
    final padded = List<double>.filled(fftSize, 0)
      ..setRange(0, min(samples.length, fftSize), samples);

    final windowed = SignalUtils.applyHannWindow(padded);
    final fft = FFT(fftSize);
    final spectrum = fft.realFft(windowed);
    final nyquist = spectrum.length;
    if (nyquist <= 1) return null;

    final magnitudes = List<double>.generate(
      nyquist,
      (i) => _magnitude(spectrum[i]),
    );

    final freqResolution = context.sampleRate / fftSize;
    var bestBpm = 0.0;
    var bestMagnitude = 0.0;

    for (var i = 1; i < nyquist; i++) {
      final frequencyHz = i * freqResolution;
      final bpm = frequencyHz * 60;
      if (bpm < context.minBpm || bpm > context.maxBpm) {
        continue;
      }

      final magnitude = magnitudes[i];
      if (magnitude > bestMagnitude) {
        bestMagnitude = magnitude;
        bestBpm = bpm;
      }
    }

    if (bestMagnitude <= 0) {
      return null;
    }

    final totalMagnitude = magnitudes.reduce((a, b) => a + b);
    final confidence =
        (bestMagnitude / (totalMagnitude == 0 ? 1 : totalMagnitude / magnitudes.length))
            .clamp(0.0, 1.0);

    if (confidence < minMagnitudeRatio) {
      return null;
    }

    return BpmReading(
      algorithmId: id,
      algorithmName: label,
      bpm: bestBpm,
      confidence: confidence,
      timestamp: DateTime.now().toUtc(),
      metadata: {
        'fftSize': fftSize,
      },
    );
  }
}

double _magnitude(Float64x2 value) {
  final real = value.x;
  final imag = value.y;
  return sqrt(real * real + imag * imag);
}
