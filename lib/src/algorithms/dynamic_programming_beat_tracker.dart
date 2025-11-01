import 'dart:math' as math;

import 'package:bpm/src/algorithms/bpm_detection_algorithm.dart';
import 'package:bpm/src/dsp/preprocessing_pipeline.dart';
import 'package:bpm/src/models/bpm_models.dart';

/// Dynamic-programming beat tracker inspired by Ellis (2007).
///
/// Operates on the shared onset envelope produced by the preprocessing
/// pipeline and searches for a smooth sequence of beats that maximises onset
/// energy while penalising large tempo swings. The resulting beat interval is
/// converted to BPM so the algorithm can participate in the existing
/// consensus process.
class DynamicProgrammingBeatTracker extends BpmDetectionAlgorithm {
  DynamicProgrammingBeatTracker({
    this.lambda = 0.6,
    this.maxFrames = 2400,
    this.tempoStepBpm = 2.0,
  });

  /// Smoothness penalty applied when consecutive beat intervals diverge.
  final double lambda;

  /// Maximum number of onset frames evaluated (tail window).
  final int maxFrames;

  /// Tempo discretisation step in BPM.
  final double tempoStepBpm;

  @override
  String get id => 'dp_beat_tracker';

  @override
  String get label => 'Dynamic Programming Beat Tracker';

  @override
  Duration get preferredWindow => const Duration(seconds: 12);

  @override
  Future<BpmReading?> analyze({required PreprocessedSignal signal}) async {
    final onsetEnvelope = signal.onsetEnvelope;
    if (onsetEnvelope.isEmpty) {
      return null;
    }

    final featureRate = (1.0 / signal.onsetTimeScale).clamp(1.0, 200.0);
    final minBpm = signal.context.minBpm.clamp(40.0, 300.0);
    final maxBpm = signal.context.maxBpm.clamp(40.0, 300.0);
    if (maxBpm <= minBpm) {
      return null;
    }

    final minPeriod = (featureRate * 60.0 / maxBpm).floor().clamp(1, 400);
    final maxPeriod =
        (featureRate * 60.0 / minBpm).ceil().clamp(minPeriod, 800);
    if (maxPeriod - minPeriod < 2) {
      return null;
    }

    final frameCount = math.min(onsetEnvelope.length, maxFrames);
    final startOffset = onsetEnvelope.length - frameCount;
    final envelope = List<double>.generate(
      frameCount,
      (index) => onsetEnvelope[startOffset + index].toDouble(),
    );

    final tempoBins = _buildTempoBins(
      minPeriod: minPeriod,
      maxPeriod: maxPeriod,
      stepBpm: tempoStepBpm,
      featureRate: featureRate,
    );
    if (tempoBins.periods.isEmpty) {
      return null;
    }

    final dp = List.generate(
      frameCount,
      (_) => List<double>.filled(
          tempoBins.periods.length, double.negativeInfinity),
    );
    final backTime = List.generate(
      frameCount,
      (_) => List<int>.filled(tempoBins.periods.length, -1),
    );
    final backTempo = List.generate(
      frameCount,
      (_) => List<int>.filled(tempoBins.periods.length, -1),
    );

    // Pre-compute absolute differences to avoid recomputation inside loops.
    final tempoDifferences = List.generate(
      tempoBins.periods.length,
      (i) => List<double>.generate(
        tempoBins.periods.length,
        (j) => (tempoBins.periods[i] - tempoBins.periods[j]).abs().toDouble(),
      ),
    );

    // Dynamic programming forward pass.
    for (var t = 0; t < frameCount; t++) {
      final energy = envelope[t];
      for (var tempoIndex = 0;
          tempoIndex < tempoBins.periods.length;
          tempoIndex++) {
        final period = tempoBins.periods[tempoIndex];
        var bestScore = energy;
        var bestPrevTime = -1;
        var bestPrevTempo = -1;
        final prevTime = t - period;
        if (prevTime >= 0) {
          var candidateScore = double.negativeInfinity;
          for (var prevTempoIndex = 0;
              prevTempoIndex < tempoBins.periods.length;
              prevTempoIndex++) {
            final prevScore = dp[prevTime][prevTempoIndex];
            if (prevScore.isFinite) {
              final penalty =
                  lambda * tempoDifferences[tempoIndex][prevTempoIndex];
              final score = prevScore + energy - penalty;
              if (score > candidateScore) {
                candidateScore = score;
                bestPrevTime = prevTime;
                bestPrevTempo = prevTempoIndex;
              }
            }
          }
          if (candidateScore.isFinite) {
            bestScore = candidateScore;
          }
        }
        dp[t][tempoIndex] = bestScore;
        backTime[t][tempoIndex] = bestPrevTime;
        backTempo[t][tempoIndex] = bestPrevTempo;
      }
    }

    final bestTerminal = _findBestTerminal(dp);
    if (bestTerminal == null) {
      return null;
    }

    final pathFrames = <int>[];
    var currentTime = bestTerminal.time;
    var currentTempo = bestTerminal.tempoIndex;
    while (currentTime >= 0 && currentTempo >= 0) {
      pathFrames.add(currentTime);
      final prevTime = backTime[currentTime][currentTempo];
      final prevTempo = backTempo[currentTime][currentTempo];
      if (prevTime < 0 || prevTempo < 0) {
        break;
      }
      currentTime = prevTime;
      currentTempo = prevTempo;
    }

    if (pathFrames.length < 2) {
      return null;
    }

    pathFrames.sort();
    final beatIntervals = <int>[];
    for (var i = 1; i < pathFrames.length; i++) {
      beatIntervals.add(pathFrames[i] - pathFrames[i - 1]);
    }
    if (beatIntervals.isEmpty) {
      return null;
    }

    final trimmedPeriod = _trimmedMean(beatIntervals);
    final bpm = (featureRate * 60.0 / trimmedPeriod).clamp(minBpm, maxBpm);

    final startSeconds = startOffset / featureRate;
    final beatTimes = pathFrames
        .map((frame) => startSeconds + frame / featureRate)
        .toList(growable: false);

    final beatEnergy = pathFrames.fold<double>(
      0,
      (sum, t) => sum + envelope[t],
    );
    final totalEnergy =
        envelope.fold<double>(0, (sum, value) => sum + value.abs()) + 1e-6;
    final energyRatio = (beatEnergy / totalEnergy).clamp(0.0, 1.0);
    final smoothness = _computeSmoothness(beatIntervals);

    final confidence =
        (0.25 + 0.5 * energyRatio + 0.25 * (1.0 - smoothness).clamp(0.0, 1.0))
            .clamp(0.0, 1.0);

    return BpmReading(
      algorithmId: id,
      algorithmName: label,
      bpm: bpm,
      confidence: confidence,
      timestamp: DateTime.now().toUtc(),
      metadata: {
        'featureRate': featureRate,
        'meanPeriodFrames': trimmedPeriod,
        'energyRatio': energyRatio,
        'smoothness': smoothness,
        'score': bestTerminal.score,
        'tempoEstimateBpm': bpm,
        'tempoBinCount': tempoBins.periods.length,
        'lambda': lambda,
        'beatCount': pathFrames.length,
        'beatTimes': beatTimes,
        'beatIntervalsFrames': beatIntervals,
      },
    );
  }

  _TempoBins _buildTempoBins({
    required int minPeriod,
    required int maxPeriod,
    required double stepBpm,
    required double featureRate,
  }) {
    final periods = <int>[];
    final bpms = <double>[];
    final minBpm = featureRate * 60.0 / maxPeriod;
    final maxBpm = featureRate * 60.0 / minPeriod;
    for (var bpm = minBpm; bpm <= maxBpm; bpm += stepBpm) {
      final period = (featureRate * 60.0 / bpm).round();
      if (period < minPeriod || period > maxPeriod) {
        continue;
      }
      if (periods.isEmpty || periods.last != period) {
        periods.add(period);
        bpms.add(bpm);
      }
    }
    return _TempoBins(periods: periods, bpms: bpms);
  }

  _TerminalState? _findBestTerminal(List<List<double>> dp) {
    var bestScore = double.negativeInfinity;
    var bestTime = -1;
    var bestTempo = -1;
    for (var t = 0; t < dp.length; t++) {
      for (var tempoIndex = 0; tempoIndex < dp[t].length; tempoIndex++) {
        final score = dp[t][tempoIndex];
        if (score > bestScore) {
          bestScore = score;
          bestTime = t;
          bestTempo = tempoIndex;
        }
      }
    }
    if (bestTime < 0 || bestTempo < 0 || !bestScore.isFinite) {
      return null;
    }
    return _TerminalState(
        time: bestTime, tempoIndex: bestTempo, score: bestScore);
  }

  double _computeSmoothness(List<int> intervals) {
    if (intervals.length < 2) {
      return 0.0;
    }
    final mean = intervals.reduce((a, b) => a + b) / intervals.length;
    final variance = intervals.fold<double>(
      0,
      (sum, value) => sum + math.pow(value - mean, 2),
    );
    final stdDev = math.sqrt(variance / intervals.length);
    return (stdDev / (mean.abs() + 1e-6)).clamp(0.0, 1.0);
  }

  double _trimmedMean(List<int> intervals) {
    if (intervals.isEmpty) {
      return 1.0;
    }
    final values = intervals.map((e) => e.toDouble()).toList()..sort();
    final trim = (values.length * 0.1).floor();
    final start = trim.clamp(0, values.length - 1);
    final end = (values.length - trim).clamp(start + 1, values.length);
    final window = values.sublist(start, end);
    final sum = window.fold<double>(0, (sum, value) => sum + value);
    return sum / window.length;
  }
}

class _TempoBins {
  const _TempoBins({required this.periods, required this.bpms});

  final List<int> periods;
  final List<double> bpms;
}

class _TerminalState {
  const _TerminalState({
    required this.time,
    required this.tempoIndex,
    required this.score,
  });

  final int time;
  final int tempoIndex;
  final double score;
}
