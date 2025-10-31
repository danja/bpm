import 'dart:math' as math;
import 'dart:typed_data';

import 'signal_utils.dart';
import 'fft_utils.dart';

class TempogramConfig {
  const TempogramConfig({
    this.windowSeconds = 8.0,
    this.hopSeconds = 1.0,
    this.minBpm = 50.0,
    this.maxBpm = 250.0,
    this.tempoBins = 120,
  }) : assert(minBpm > 0 && maxBpm > minBpm && tempoBins > 0);

  final double windowSeconds;
  final double hopSeconds;
  final double minBpm;
  final double maxBpm;
  final int tempoBins;
}

class TempogramResult {
  const TempogramResult({
    required this.matrix,
    required this.tempoAxis,
    required this.times,
    required this.dominantTempo,
    required this.dominantStrength,
  });

  final List<Float32List> matrix;
  final Float32List tempoAxis;
  final Float32List times;
  final Float32List dominantTempo;
  final Float32List dominantStrength;
}

class TempogramComputer {
  const TempogramComputer({this.config = const TempogramConfig()});

  final TempogramConfig config;

  TempogramResult compute({
    required Float32List noveltyCurve,
    required double featureRate,
    double? minBpm,
    double? maxBpm,
  }) {
    if (noveltyCurve.isEmpty || featureRate <= 0) {
      return _emptyResult();
    }

    final windowSeconds = math.max(1.5, config.windowSeconds);
    final hopSeconds = math.max(0.2, math.min(windowSeconds, config.hopSeconds));

    final windowLength = (windowSeconds * featureRate).round();
    final hopLength = math.max(1, (hopSeconds * featureRate).round());
    if (windowLength <= 8) {
      return _emptyResult();
    }

    final minTempo = minBpm ?? config.minBpm;
    final maxTempo = maxBpm ?? config.maxBpm;
    final tempoBins = config.tempoBins;
    final tempoAxis = Float32List(tempoBins);
    final tempoStep = (maxTempo - minTempo) / (tempoBins - 1).clamp(1, tempoBins);
    for (var i = 0; i < tempoBins; i++) {
      tempoAxis[i] = (minTempo + tempoStep * i).clamp(minTempo, maxTempo);
    }

    final frames = <Float32List>[];
    final times = <double>[];
    final halfWindow = windowLength / 2.0;
    final dominantRecords = <(int, double, double)>[];

    for (int start = 0; start < noveltyCurve.length; start += hopLength) {
      final end = math.min(start + windowLength, noveltyCurve.length);
      final window = noveltyCurve.sublist(start, end);
      if (window.isEmpty) {
        continue;
      }
      final paddedLength = SignalUtils.nextPowerOfTwo(math.max(window.length, 64));
      final padded = List<double>.filled(paddedLength, 0);
      for (var i = 0; i < window.length; i++) {
        padded[i] = window[i];
      }
      final windowed = _applyHannWindow(padded);
      final spectrum = FftUtils.magnitudeSpectrum(windowed);
      final magnitudes = spectrum.magnitudes;
      final freqResolution = featureRate / spectrum.size;

      final row = Float32List(tempoBins);
      var maxValue = 0.0;
      var secondValue = 0.0;
      var maxIndex = 0;
      for (var i = 0; i < tempoBins; i++) {
        final bpm = tempoAxis[i];
        final freq = bpm / 60.0;
        final position = freq / freqResolution;
        var lower = position.floor();
        if (lower < 0) {
          lower = 0;
        }
        if (lower >= magnitudes.length) {
          lower = magnitudes.length - 1;
        }
        var upper = lower + 1;
        if (upper >= magnitudes.length) {
          upper = magnitudes.length - 1;
        }
        final frac = (position - lower).clamp(0.0, 1.0);
        final lowerMag = magnitudes[lower].toDouble();
        final upperMag = magnitudes[upper].toDouble();
        final value = lowerMag + (upperMag - lowerMag) * frac;
        row[i] = value;
        if (value > maxValue) {
          secondValue = maxValue;
          maxValue = value;
          maxIndex = i;
        } else if (value > secondValue) {
          secondValue = value;
        }
      }

      if (maxValue > 0) {
        for (var i = 0; i < row.length; i++) {
          row[i] = (row[i] / maxValue).clamp(0.0, 1.0);
        }
      }

      frames.add(row);
      final center = start + halfWindow;
      times.add(center / featureRate);
      dominantRecords.add((maxIndex, maxValue, secondValue));
    }

    if (frames.isEmpty) {
      return _emptyResult();
    }

    final dominant = Float32List(frames.length);
    final strength = Float32List(frames.length);
    for (var t = 0; t < frames.length; t++) {
      final record = dominantRecords[t];
      final maxIndex = record.$1;
      final primary = record.$2;
      final secondary = record.$3;
      dominant[t] = tempoAxis[maxIndex];
      if (primary > 0) {
        final contrast = (primary - secondary).clamp(0.0, primary);
        strength[t] = (contrast / primary).clamp(0.0, 1.0).toDouble();
      } else {
        strength[t] = 0;
      }
    }

    return TempogramResult(
      matrix: frames,
      tempoAxis: tempoAxis,
      times: Float32List.fromList(times),
      dominantTempo: dominant,
      dominantStrength: strength,
    );
  }

  List<double> _applyHannWindow(List<double> samples) {
    final result = List<double>.filled(samples.length, 0);
    for (var i = 0; i < samples.length; i++) {
      final w = 0.5 * (1 - math.cos(2 * math.pi * i / (samples.length - 1)));
      result[i] = samples[i] * w;
    }
    return result;
  }
}

TempogramResult _emptyResult() => TempogramResult(
      matrix: const [],
      tempoAxis: Float32List(0),
      times: Float32List(0),
      dominantTempo: Float32List(0),
      dominantStrength: Float32List(0),
    );
