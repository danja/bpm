import 'dart:math';

class SignalUtils {
  const SignalUtils._();

  static List<double> normalize(List<double> samples) {
    if (samples.isEmpty) return samples;
    final maxValue = samples.map((e) => e.abs()).reduce(max);
    if (maxValue == 0) {
      return List<double>.from(samples);
    }
    return samples.map((value) => value / maxValue).toList();
  }

  static int nextPowerOfTwo(int value) {
    var v = value - 1;
    v |= v >> 1;
    v |= v >> 2;
    v |= v >> 4;
    v |= v >> 8;
    v |= v >> 16;
    return v + 1;
  }

  static int previousPowerOfTwo(int value) {
    if (value <= 1) {
      return value <= 0 ? 1 : 1;
    }
    var v = nextPowerOfTwo(value);
    if (v == value) {
      return value;
    }
    return v >> 1;
  }

  static List<double> applyHannWindow(List<double> samples) {
    final length = samples.length;
    if (length <= 1) {
      return List<double>.from(samples);
    }
    final windowed = List<double>.filled(length, 0);
    for (var i = 0; i < length; i++) {
      final multiplier = 0.5 * (1 - cos((2 * pi * i) / (length - 1)));
      windowed[i] = samples[i] * multiplier;
    }
    return windowed;
  }

  static double autocorrelation(List<double> samples, int lag) {
    if (lag <= 0 || lag >= samples.length) {
      return 0;
    }
    var sum = 0.0;
    for (var i = 0; i < samples.length - lag; i++) {
      sum += samples[i] * samples[i + lag];
    }
    return sum / (samples.length - lag);
  }

  static int? dominantLag(
    List<double> signal, {
    required int minLag,
    required int maxLag,
  }) {
    if (signal.length < maxLag || minLag >= maxLag) {
      return null;
    }

    var bestLag = minLag;
    var bestScore = double.negativeInfinity;

    for (var lag = minLag; lag <= maxLag; lag++) {
      final score = autocorrelation(signal, lag);
      if (score > bestScore) {
        bestScore = score;
        bestLag = lag;
      }
    }

    if (bestScore <= 0) {
      return null;
    }

    return bestLag;
  }
}
