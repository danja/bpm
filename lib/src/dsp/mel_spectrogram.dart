import 'dart:math' as math;
import 'dart:typed_data';

import 'stft.dart';

/// Represents mel-spectrogram features derived from an audio segment.
class MelSpectrogram {
  const MelSpectrogram({
    required this.frames,
    required this.meanBands,
    required this.fftSize,
    required this.hopSize,
    required this.sampleRate,
  });

  /// Mel energy per frame (melBands × numFrames).
  final List<Float32List> frames;

  /// Mean mel energy across all frames (length == melBands).
  final Float32List meanBands;

  final int fftSize;
  final int hopSize;
  final int sampleRate;

  bool get isEmpty => frames.isEmpty;
}

/// Computes mel-spectrogram features from [samples].
MelSpectrogram computeMelSpectrogram(
  Float32List samples, {
  required int sampleRate,
  int fftSize = 1024,
  int hopSize = 512,
  int melBands = 40,
  double minFrequency = 20.0,
  double maxFrequency = 8000.0,
  bool logScale = true,
}) {
  if (samples.isEmpty) {
    return MelSpectrogram(
      frames: const [],
      meanBands: Float32List(melBands),
      fftSize: fftSize,
      hopSize: hopSize,
      sampleRate: sampleRate,
    );
  }

  final stft = STFT(
    fftSize: fftSize,
    hopSize: hopSize,
    window: WindowFunction.hann,
  );
  final spectra = stft.forward(samples);
  if (spectra.isEmpty) {
    return MelSpectrogram(
      frames: const [],
      meanBands: Float32List(melBands),
      fftSize: fftSize,
      hopSize: hopSize,
      sampleRate: sampleRate,
    );
  }

  final filterBank = _buildMelFilterBank(
    fftSize: fftSize,
    sampleRate: sampleRate,
    melBands: melBands,
    minFrequency: minFrequency,
    maxFrequency: math.min(maxFrequency, sampleRate / 2),
  );

  final melFrames = <Float32List>[];
  final meanBands = Float32List(melBands);

  for (final spectrum in spectra) {
    final melEnergies = Float32List(melBands);
    for (var band = 0; band < melBands; band++) {
      double energy = 0.0;
      final weights = filterBank[band];
      final length = math.min(weights.length, spectrum.length);
      for (var bin = 0; bin < length; bin++) {
        energy += spectrum[bin] * weights[bin];
      }
      if (logScale) {
        energy = math.log(1 + energy);
      }
      melEnergies[band] = energy;
      meanBands[band] += energy;
    }
    melFrames.add(melEnergies);
  }

  if (melFrames.isNotEmpty) {
    for (var band = 0; band < melBands; band++) {
      meanBands[band] /= melFrames.length;
    }
    _normalizeInPlace(meanBands);
  }

  return MelSpectrogram(
    frames: melFrames,
    meanBands: meanBands,
    fftSize: fftSize,
    hopSize: hopSize,
    sampleRate: sampleRate,
  );
}

List<Float32List> _buildMelFilterBank({
  required int fftSize,
  required int sampleRate,
  required int melBands,
  required double minFrequency,
  required double maxFrequency,
}) {
  final minMel = _hzToMel(minFrequency);
  final maxMel = _hzToMel(maxFrequency);
  final melPoints = List<double>.generate(
    melBands + 2,
    (index) => minMel + (maxMel - minMel) * index / (melBands + 1),
  );

  final binPoints = melPoints
      .map((mel) => _melToHz(mel))
      .map((hz) => ((fftSize) * hz / sampleRate).floor())
      .map((bin) => bin.clamp(0, fftSize ~/ 2))
      .toList();

  final filters = List<Float32List>.generate(
    melBands,
    (_) => Float32List(fftSize ~/ 2),
  );

  for (var band = 0; band < melBands; band++) {
    final left = binPoints[band];
    final center = binPoints[band + 1];
    final right = binPoints[band + 2];

    if (center == left) {
      continue;
    }
    for (var bin = left; bin < center; bin++) {
      final weight = (bin - left) / (center - left);
      filters[band][bin] = weight.toDouble();
    }
    if (right == center) {
      continue;
    }
    for (var bin = center; bin < right && bin < filters[band].length; bin++) {
      final weight = 1.0 - ((bin - center) / (right - center));
      filters[band][bin] = math.max(weight, 0).toDouble();
    }
  }

  // Normalize filters so each sums to 1 (avoid bias towards dense regions)
  for (final filter in filters) {
    double sum = 0.0;
    for (final value in filter) {
      sum += value;
    }
    if (sum > 0) {
      final scale = 1 / sum;
      for (var i = 0; i < filter.length; i++) {
        filter[i] *= scale;
      }
    }
  }

  return filters;
}

double _hzToMel(double hz) => 2595.0 * math.log(1 + hz / 700.0);

double _melToHz(double mel) => 700.0 * (math.exp(mel / 2595.0) - 1);

void _normalizeInPlace(Float32List values) {
  double maxValue = 0.0;
  for (final value in values) {
    if (value > maxValue) {
      maxValue = value;
    }
  }
  if (maxValue <= 0) {
    return;
  }
  for (var i = 0; i < values.length; i++) {
    values[i] /= maxValue;
  }
}
