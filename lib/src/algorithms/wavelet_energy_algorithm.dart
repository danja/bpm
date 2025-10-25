import 'dart:math';

import 'package:bpm/src/algorithms/bpm_detection_algorithm.dart';
import 'package:bpm/src/algorithms/detection_context.dart';
import 'package:bpm/src/dsp/signal_utils.dart';
import 'package:bpm/src/models/bpm_models.dart';

class WaveletEnergyAlgorithm extends BpmDetectionAlgorithm {
  WaveletEnergyAlgorithm({
    this.levels = 4,
  });

  final int levels;

  @override
  String get id => 'wavelet_energy';

  @override
  String get label => 'Wavelet Energy';

  @override
  Duration get preferredWindow => const Duration(seconds: 14);

  @override
  Future<BpmReading?> analyze({
    required List<AudioFrame> window,
    required DetectionContext context,
  }) async {
    if (window.isEmpty) return null;

    final samples = SignalUtils.normalize(
      window.expand((frame) => frame.samples).toList(),
    );

    if (samples.length < context.sampleRate ~/ 2) {
      return null;
    }

    final pow2 = SignalUtils.nextPowerOfTwo(samples.length);
    final padded = List<double>.filled(pow2, 0)
      ..setRange(0, samples.length, samples);

    final detailLevels = _haarDetailBands(padded, levels);
    if (detailLevels.isEmpty) return null;

    double? bestBpm;
    double bestScore = double.negativeInfinity;
    int bestLevel = 0;
    int bestLag = 0;

    for (var level = 0; level < detailLevels.length; level++) {
      final details = detailLevels[level];
      final envelope = details.map((value) => value.abs()).toList();

      final scale = pow(2, level).toInt();
      final minLag =
          (context.sampleRate * 60 / context.maxBpm / scale).floor().clamp(1, envelope.length - 1);
      final maxLag =
          (context.sampleRate * 60 / context.minBpm / scale).floor().clamp(minLag + 1, envelope.length - 1);
      if (minLag >= maxLag) {
        continue;
      }

      final lag = SignalUtils.dominantLag(
        envelope,
        minLag: minLag,
        maxLag: maxLag,
      );
      if (lag == null) continue;

      final score = SignalUtils.autocorrelation(envelope, lag);
      if (score > bestScore) {
        bestScore = score;
        bestLevel = level;
        bestLag = lag;
        final lagSamples = lag * scale;
        bestBpm = 60 * context.sampleRate / lagSamples;
      }
    }

    if (bestBpm == null ||
        bestBpm < context.minBpm ||
        bestBpm > context.maxBpm ||
        bestScore <= 0) {
      return null;
    }

    final confidence = bestScore.clamp(0.0, 1.0);

    return BpmReading(
      algorithmId: id,
      algorithmName: label,
      bpm: bestBpm,
      confidence: confidence,
      timestamp: DateTime.now().toUtc(),
      metadata: {
        'level': bestLevel,
        'lag': bestLag,
      },
    );
  }

  List<List<double>> _haarDetailBands(List<double> samples, int maxLevels) {
    final detailBands = <List<double>>[];
    var current = List<double>.from(samples);
    final sqrt2 = sqrt2Constant;

    for (var level = 0; level < maxLevels; level++) {
      if (current.length < 2) break;
      final approx = <double>[];
      final details = <double>[];

      for (var i = 0; i < current.length - 1; i += 2) {
        final a = current[i];
        final b = current[i + 1];
        approx.add((a + b) / sqrt2);
        details.add((a - b) / sqrt2);
      }

      detailBands.add(details);
      current = approx;
    }

    return detailBands;
  }
}

const sqrt2Constant = 1.4142135623730951;
