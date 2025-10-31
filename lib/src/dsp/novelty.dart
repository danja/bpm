import 'dart:math' as math;
import 'dart:typed_data';

import '../algorithms/detection_context.dart';
import '../models/bpm_models.dart';
import 'stft.dart';

class NoveltyConfig {
  const NoveltyConfig({
    this.windowSize = 1024,
    this.hopSize = 512,
    this.logCompressionC = 1000,
    this.useLogCompression = true,
    this.useMelFilter = true,
    this.melBands = 6,
    this.minFrequency = 40,
    this.maxFrequency = 8000,
    this.smoothingSeconds = 1.0,
  });

  final int windowSize;
  final int hopSize;
  final double logCompressionC;
  final bool useLogCompression;
  final bool useMelFilter;
  final int melBands;
  final double minFrequency;
  final double maxFrequency;
  final double smoothingSeconds;
}

class NoveltyResult {
  const NoveltyResult({
    required this.curve,
    required this.featureRate,
  });

  final Float32List curve;
  final double featureRate;
}

class NoveltyComputer {
  const NoveltyComputer({this.config = const NoveltyConfig()});

  final NoveltyConfig config;

  NoveltyResult compute({
    required List<AudioFrame> frames,
    required DetectionContext context,
  }) {
    final samples = _collectSamples(frames);
    if (samples.isEmpty) {
      return NoveltyResult(curve: Float32List(0), featureRate: 0);
    }

    final stft = STFT(
      fftSize: config.windowSize,
      hopSize: config.hopSize,
      window: WindowFunction.hann,
    );
    final spectra = stft.forward(Float32List.fromList(samples));
    if (spectra.isEmpty) {
      return NoveltyResult(curve: Float32List(0), featureRate: 0);
    }

    List<Float32List> processed = spectra;
    if (config.useMelFilter) {
      processed = _applyMelFilterbank(
        processed,
        context.sampleRate,
        config.windowSize,
        config.melBands,
        config.minFrequency,
        config.maxFrequency,
      );
    }

    if (config.useLogCompression) {
      processed = _applyLogCompression(
        processed,
        config.logCompressionC,
      );
    }

    final novelty = _spectralFlux(processed);
    final featureRate = context.sampleRate / config.hopSize;
    final smoothed = _movingAverage(novelty, math.max(1, (config.smoothingSeconds * featureRate).round()));
    final result = Float32List(novelty.length);
    for (var i = 0; i < novelty.length; i++) {
      final value = novelty[i] - smoothed[i];
      result[i] = value > 0 ? value : 0;
    }

    return NoveltyResult(
      curve: result,
      featureRate: featureRate,
    );
  }

  List<double> _collectSamples(List<AudioFrame> frames) {
    if (frames.isEmpty) {
      return const [];
    }
    final buffer = List<double>.filled(
      frames.fold<int>(0, (len, frame) => len + frame.samples.length),
      0,
      growable: false,
    );
    var offset = 0;
    for (final frame in frames) {
      buffer.setRange(offset, offset + frame.samples.length, frame.samples);
      offset += frame.samples.length;
    }
    return buffer;
  }

  List<Float32List> _applyLogCompression(
    List<Float32List> spectra,
    double compressionC,
  ) {
    final logDen = math.log(1 + compressionC);
    return List<Float32List>.generate(spectra.length, (index) {
      final src = spectra[index];
      final dest = Float32List(src.length);
      for (var i = 0; i < src.length; i++) {
        dest[i] = math.log(1 + src[i] * compressionC) / logDen;
      }
      return dest;
    }, growable: false);
  }

  List<Float32List> _applyMelFilterbank(
    List<Float32List> spectra,
    int sampleRate,
    int fftSize,
    int melBands,
    double minFrequency,
    double maxFrequency,
  ) {
    if (spectra.isEmpty) {
      return spectra;
    }
    final spectrumLength = spectra.first.length;
    if (spectrumLength == 0 || melBands <= 0) {
      return spectra;
    }
    final filters = _createMelFilterbank(
      sampleRate,
      fftSize,
      spectrumLength,
      melBands,
      minFrequency,
      maxFrequency,
    );
    return List<Float32List>.generate(spectra.length, (index) {
      final spectrum = spectra[index];
      final dest = Float32List(filters.length);
      for (var band = 0; band < filters.length; band++) {
        final filter = filters[band];
        double sum = 0;
        final limit = math.min(filter.length, spectrum.length);
        for (var bin = 0; bin < limit; bin++) {
          sum += spectrum[bin] * filter[bin];
        }
        dest[band] = sum;
      }
      return dest;
    }, growable: false);
  }

  List<Float32List> _createMelFilterbank(
    int sampleRate,
    int fftSize,
    int spectrumLength,
    int melBands,
    double minFrequency,
    double maxFrequency,
  ) {
    if (spectrumLength == 0 || melBands <= 0) {
      return [];
    }

    int clampBin(int value) {
      if (value < 0) return 0;
      final maxIndex = spectrumLength - 1;
      if (value > maxIndex) return maxIndex;
      return value;
    }

    final melMin = _hzToMel(minFrequency);
    final melMax = _hzToMel(math.min(maxFrequency, sampleRate / 2));
    final melPoints = List<double>.generate(
      melBands + 2,
      (index) => melMin + (melMax - melMin) * index / (melBands + 1),
    );
    final binPoints = List<int>.generate(melPoints.length, (index) {
      final hz = _melToHz(melPoints[index]);
      final rawBin = ((fftSize / 2) * hz / sampleRate).floor();
      return clampBin(rawBin);
    });

    final filters = <Float32List>[];
    for (var band = 0; band < melBands; band++) {
      final filter = Float32List(spectrumLength);
      final left = binPoints[band];
      final center = binPoints[band + 1];
      final right = binPoints[band + 2];
      if (center <= left || right <= center) {
        filters.add(filter);
        continue;
      }

      final safeLeft = clampBin(left);
      final safeCenter = clampBin(center);
      final safeRight = clampBin(right);
      if (safeCenter <= safeLeft || safeRight <= safeCenter) {
        filters.add(filter);
        continue;
      }

      for (var bin = safeLeft; bin < safeCenter; bin++) {
        filter[bin] = (bin - left) / (center - left);
      }
      for (var bin = safeCenter; bin <= safeRight; bin++) {
        filter[bin] = (right - bin) / (right - center);
      }
      final sum = filter.fold<double>(0, (value, element) => value + element);
      if (sum > 0) {
        for (var i = 0; i < filter.length; i++) {
          filter[i] = filter[i] / sum;
        }
      }
      filters.add(filter);
    }
    return filters;
  }

  Float32List _spectralFlux(List<Float32List> spectra) {
    final flux = Float32List(spectra.length);
    final previous = Float32List(spectra.first.length);
    for (var i = 0; i < spectra.length; i++) {
      final spectrum = spectra[i];
      double sum = 0;
      for (var bin = 0; bin < spectrum.length; bin++) {
        final diff = spectrum[bin] - previous[bin];
        if (diff > 0) {
          sum += diff;
        }
        previous[bin] = spectrum[bin];
      }
      flux[i] = sum;
    }
    return flux;
  }

  Float32List _movingAverage(Float32List values, int window) {
    if (values.isEmpty || window <= 1) {
      return Float32List.fromList(values);
    }
    final result = Float32List(values.length);
    double sum = 0;
    for (var i = 0; i < values.length; i++) {
      sum += values[i];
      if (i >= window) {
        sum -= values[i - window];
      }
      final divisor = math.min(i + 1, window);
      result[i] = sum / divisor;
    }
    return result;
  }

  double _hzToMel(double hz) => 2595 * math.log(1 + hz / 700) / math.ln10;

  double _melToHz(double mel) => 700 * (math.pow(10, mel / 2595) - 1);
}
