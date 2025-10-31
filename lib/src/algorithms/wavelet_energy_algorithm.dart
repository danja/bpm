import 'dart:math';

import 'package:bpm/src/algorithms/algorithm_utils.dart';
import 'package:bpm/src/algorithms/bpm_detection_algorithm.dart';
import 'package:bpm/src/algorithms/detection_context.dart';
import 'package:bpm/src/dsp/preprocessing_pipeline.dart';
import 'package:bpm/src/dsp/signal_utils.dart';
import 'package:bpm/src/models/bpm_models.dart';

/// Wavelet-based BPM detection using Haar decomposition.
///
/// OPTIMIZED: Reduced from 4 levels to 2 for better performance (target <5s).
/// Now uses pre-filtered signal from preprocessing pipeline.
class WaveletEnergyAlgorithm extends BpmDetectionAlgorithm {
  WaveletEnergyAlgorithm({
    this.levels = 2, // Reduced from 4 to 2 for performance
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
    required PreprocessedSignal signal,
  }) async {
    // Prefer downsampled 400 Hz representation to keep wavelet analysis light-weight.
    final baseSamples = signal.samples400Hz.isNotEmpty
        ? signal.samples400Hz
        : signal.filteredSamples;
    var samples = List<double>.from(baseSamples);

    final contextSampleRate = signal.context.sampleRate.toDouble();
    final durationSeconds = signal.duration.inMicroseconds > 0
        ? signal.duration.inMicroseconds / 1e6
        : (samples.isNotEmpty ? samples.length / contextSampleRate : 0);
    final effectiveSampleRate = (durationSeconds > 0 && samples.isNotEmpty)
        ? samples.length / durationSeconds
        : contextSampleRate;

    if (samples.length < (effectiveSampleRate * 0.5).ceil()) {
      return null;
    }

    // Trim to power of 2 for wavelet decomposition
    final pow2 = SignalUtils.previousPowerOfTwo(samples.length);
    if (pow2 < 32) {
      return null;
    }
    final trimmed = samples.sublist(0, pow2);

    final detailBands = _haarDetailBands(trimmed, levels);
    if (detailBands.isEmpty) return null;

    double? bestBpm;
    double bestWeightedScore = double.negativeInfinity;
    int bestLag = 0;
    int bestLevel = 0;
    int bestScale = 1;
    late List<double> bestNormalized;
    var hasBestNormalized = false;
    List<double>? aggregatedEnvelope;
    double aggregatedWeight = 0;

    final diagnostics = <Map<String, dynamic>>[];

    for (var level = 0; level < detailBands.length; level++) {
      final detail = detailBands[level];
      if (detail.length < 8) continue;

      final scale = 1 << (level + 1);
      final energy = detail.map((value) => value.abs()).toList();
      final smoothed = _movingAverage(energy, max(2, detail.length ~/ 128));
      final normalized = SignalUtils.normalize(_removeDc(smoothed));
      if (normalized.every((value) => value == 0)) continue;

      final upsampled = _upsampleToLength(normalized, trimmed.length);
      final weight = 1 / scale;
      aggregatedEnvelope ??= List<double>.filled(upsampled.length, 0);
      for (var i = 0; i < upsampled.length; i++) {
        aggregatedEnvelope[i] += upsampled[i] * weight;
      }
      aggregatedWeight += weight;

      final minLag = (effectiveSampleRate * 60 / signal.context.maxBpm / scale)
          .floor()
          .clamp(1, normalized.length - 1);
      final maxLag = (effectiveSampleRate * 60 / signal.context.minBpm / scale)
          .floor()
          .clamp(minLag + 1, normalized.length - 1);
      if (minLag >= maxLag) continue;

      final lag = SignalUtils.dominantLag(
        normalized,
        minLag: minLag,
        maxLag: maxLag,
      );
      if (lag == null) continue;

      final score = SignalUtils.autocorrelation(normalized, lag);
      if (score <= 0) continue;
      final candidateLagSamples = lag * scale;
      final weightedScore = score / sqrt(scale);
      diagnostics.add({
        'level': level,
        'scale': scale,
        'lagSamples': candidateLagSamples,
        'score': score,
        'weightedScore': weightedScore,
      });
      if (weightedScore > bestWeightedScore) {
        bestWeightedScore = weightedScore;
        bestLag = lag;
        bestScale = scale;
        bestLevel = level;
        bestBpm = 60 * effectiveSampleRate / (lag * scale);
        bestNormalized = upsampled;
        hasBestNormalized = true;
      }
    }

    List<double>? aggregatedNormalized;
    if (aggregatedEnvelope != null && aggregatedWeight > 0) {
      final averaged = List<double>.from(aggregatedEnvelope);
      for (var i = 0; i < averaged.length; i++) {
        averaged[i] /= aggregatedWeight;
      }
      final normalizedAggregate = SignalUtils.normalize(_removeDc(averaged));
      if (normalizedAggregate.any((value) => value != 0)) {
        aggregatedNormalized = normalizedAggregate;
      }
    }

    final hasBestCandidate =
        bestBpm != null && bestWeightedScore > 0 && hasBestNormalized;
    final hasAggregateCandidate = aggregatedNormalized != null;
    if (!hasBestCandidate && !hasAggregateCandidate) {
      return null;
    }

    _LagResult? refine;
    List<double>? candidateEnvelope;
    int? candidateLagSamples;
    double? candidateScore;

    if (hasBestCandidate) {
      refine = _refineLag(
        detailBands[bestLevel],
        trimmed.length,
        signal.context,
        effectiveSampleRate,
      );
      final lagSamples = refine?.lagSamples ?? (bestLag * bestScale);
      final envelope = refine?.normalized ?? bestNormalized;
      candidateLagSamples = lagSamples;
      candidateEnvelope = envelope;
      candidateScore = SignalUtils.autocorrelation(envelope, lagSamples);
      if (candidateScore <= 0) {
        candidateScore = null;
      }
    }

    int? aggregateLag;
    double? aggregateScore;
    if (aggregatedNormalized != null) {
      final minLag = (effectiveSampleRate * 60 / signal.context.maxBpm)
          .floor()
          .clamp(1, aggregatedNormalized.length - 1);
      final maxLag = (effectiveSampleRate * 60 / signal.context.minBpm)
          .floor()
          .clamp(minLag + 1, aggregatedNormalized.length - 1);
      if (minLag < maxLag) {
        aggregateLag = SignalUtils.dominantLag(
          aggregatedNormalized,
          minLag: minLag,
          maxLag: maxLag,
        );
        if (aggregateLag != null) {
          aggregateScore =
              SignalUtils.autocorrelation(aggregatedNormalized, aggregateLag);
          if (aggregateScore <= 0) {
            aggregateLag = null;
            aggregateScore = null;
          }
        }
      }
    }

    List<double>? finalEnvelope;
    int? finalLagSamples;
    var usedAggregate = false;

    if (candidateScore != null && candidateLagSamples != null) {
      finalEnvelope = candidateEnvelope;
      finalLagSamples = candidateLagSamples;
    }

    if (aggregateLag != null && aggregateScore != null) {
      final shouldUseAggregate = finalLagSamples == null ||
          aggregateScore > (candidateScore ?? double.negativeInfinity);
      if (shouldUseAggregate) {
        finalEnvelope = aggregatedNormalized;
        finalLagSamples = aggregateLag;
        usedAggregate = true;
      }
    }

    if (finalEnvelope == null || finalLagSamples == null) {
      return null;
    }

    final fallback = _fallbackLag(
      trimmed,
      signal.context,
      effectiveSampleRate,
    );
    var fallbackUsed = false;
    if (fallback != null) {
      final fallbackScore = SignalUtils.autocorrelation(
        fallback.normalized,
        fallback.lagSamples,
      );
      final currentScore = SignalUtils.autocorrelation(
        finalEnvelope,
        finalLagSamples,
      );
      if (fallbackScore > currentScore) {
        finalEnvelope = fallback.normalized;
        finalLagSamples = fallback.lagSamples;
        fallbackUsed = true;
        usedAggregate = false;
      }
    }

    final resolvedBpm = 60 * effectiveSampleRate / finalLagSamples;

    final candidates = <TempoCandidate>[
      TempoCandidate(
        bpm: resolvedBpm,
        weight: 1.0,
        source: 'resolved',
        allowHarmonics: false,
      ),
    ];
    if (aggregateLag != null && aggregateLag > 0) {
      final aggregateBpm = 60 * effectiveSampleRate / aggregateLag;
      candidates.add(
        TempoCandidate(
          bpm: aggregateBpm,
          weight: 0.75,
          source: 'aggregate',
          allowHarmonics: false,
        ),
      );
    }
    if (fallback != null) {
      final fallbackBpm = 60 * effectiveSampleRate / fallback.lagSamples;
      candidates.add(
        TempoCandidate(
          bpm: fallbackBpm,
          weight: 0.6,
          source: 'fallback',
          allowHarmonics: false,
        ),
      );
    }
    if (diagnostics.isNotEmpty) {
      for (final entry in diagnostics) {
        final lagSamples = entry['lagSamples'] as int? ?? 0;
        if (lagSamples <= 0) continue;
        final score = (entry['weightedScore'] as num?)?.toDouble() ?? 0.0;
        final diagBpm = 60 * effectiveSampleRate / lagSamples;
        candidates.add(
          TempoCandidate(
            bpm: diagBpm,
            weight: score.clamp(0.1, 1.0),
            source: 'diag_level_${entry['level']}',
            allowHarmonics: false,
          ),
        );
      }
    }

    final refinement = AlgorithmUtils.refineFromCandidates(
      candidates: candidates,
      minBpm: signal.context.minBpm,
      maxBpm: signal.context.maxBpm,
    );

    BpmRangeResult? fallbackAdjustment;
    if (refinement == null) {
      fallbackAdjustment = AlgorithmUtils.coerceToRange(
        resolvedBpm,
        minBpm: signal.context.minBpm,
        maxBpm: signal.context.maxBpm,
      );
      if (fallbackAdjustment == null) {
        return null;
      }
    }

    final bpm = refinement?.bpm ?? fallbackAdjustment!.bpm;

    final harmonicPenalty = refinement != null
        ? refinement.consistency
        : (fallbackAdjustment!.clamped
            ? 0.6
            : (1.0 - (fallbackAdjustment.multiplier - 1.0).abs() * 0.15)
                .clamp(0.6, 1.0));

    final finalScore = SignalUtils.autocorrelation(
      finalEnvelope,
      finalLagSamples,
    ).abs();
    final candidateStrength = (candidateScore ?? 0).abs();
    final aggregateStrength = (aggregateScore ?? 0).abs();
    final envelopeStrength = [
      finalScore * 3.0,
      candidateStrength * 2.4,
      aggregateStrength * 2.0
    ].reduce(max).clamp(0.0, 1.0);

    final confidence =
        (0.55 * envelopeStrength + 0.45 * harmonicPenalty).clamp(0.0, 1.0);
    final metadata = <String, Object?>{
      'lagSamples': finalLagSamples,
      'level': usedAggregate ? -1 : bestLevel,
      'refined': refine != null && !usedAggregate,
      'aggregationUsed': usedAggregate,
      'fallbackUsed': fallbackUsed,
      if (aggregateLag != null) 'aggregateLag': aggregateLag,
      if (aggregateScore != null) 'aggregateScore': aggregateScore,
      'rawResolvedBpm': resolvedBpm,
      'clusterConsistency': harmonicPenalty,
      if (diagnostics.isNotEmpty) 'candidates': diagnostics,
      'finalScore': finalScore,
    };

    if (refinement != null) {
      metadata.addAll(refinement.metadata);
      metadata['rangeMultiplier'] = refinement.averageMultiplier;
      metadata['rangeClamped'] = refinement.clampedCount > 0;
    } else {
      metadata['clusterWeight'] = 0.0;
      metadata['clusterStd'] = 0.0;
      metadata['clusterCount'] = candidates.length;
      metadata['maxMultiplierDeviation'] =
          (fallbackAdjustment!.multiplier - 1.0).abs();
      metadata['clampedContributors'] = fallbackAdjustment.clamped ? 1 : 0;
      metadata['sources'] = const <String>['fallback'];
      metadata['rangeMultiplier'] = fallbackAdjustment.multiplier;
      metadata['rangeClamped'] = fallbackAdjustment.clamped;
    }

    metadata['clusterConsistency'] ??= harmonicPenalty;

    return BpmReading(
      algorithmId: id,
      algorithmName: label,
      bpm: bpm,
      confidence: confidence,
      timestamp: DateTime.now().toUtc(),
      metadata: metadata,
    );
  }

  _LagResult? _fallbackLag(
    List<double> samples,
    DetectionContext context,
    double sampleRate,
  ) {
    if (samples.isEmpty) return null;

    final envelope = samples.map((value) => value.abs()).toList();
    final smoothingWindow = max(2, (sampleRate / 200).round());
    final smoothed = _movingAverage(envelope, smoothingWindow);
    final normalized = SignalUtils.normalize(_removeDc(smoothed));
    if (normalized.every((value) => value == 0)) return null;

    final minLag = (sampleRate * 60 / context.maxBpm)
        .floor()
        .clamp(1, normalized.length - 1);
    final maxLag = (sampleRate * 60 / context.minBpm)
        .floor()
        .clamp(minLag + 1, normalized.length - 1);
    if (minLag >= maxLag) return null;

    final lag = SignalUtils.dominantLag(
      normalized,
      minLag: minLag,
      maxLag: maxLag,
    );
    if (lag == null) return null;

    return _LagResult(
      lagSamples: lag,
      normalized: normalized,
    );
  }

  List<List<double>> _haarDetailBands(List<double> samples, int maxLevels) {
    final bands = <List<double>>[];
    var current = List<double>.from(samples);
    final sqrt2 = sqrt2Constant;

    for (var level = 0; level < maxLevels; level++) {
      if (current.length < 2) break;
      final approx = <double>[];
      final detail = <double>[];

      for (var i = 0; i < current.length - 1; i += 2) {
        final a = current[i];
        final b = current[i + 1];
        approx.add((a + b) / sqrt2);
        detail.add((a - b) / sqrt2);
      }

      bands.add(detail);
      current = approx;
    }

    return bands;
  }

  _LagResult? _refineLag(
    List<double> detailBand,
    int targetLength,
    DetectionContext context,
    double sampleRate,
  ) {
    if (detailBand.isEmpty || targetLength <= 0) return null;

    final envelope = detailBand.map((value) => value.abs()).toList();
    final smoothed = _movingAverage(envelope, max(2, detailBand.length ~/ 64));
    final upsampled = _upsampleToLength(smoothed, targetLength);
    final normalized = SignalUtils.normalize(_removeDc(upsampled));
    if (normalized.every((value) => value == 0)) return null;

    final minLag = (sampleRate * 60 / context.maxBpm)
        .floor()
        .clamp(1, normalized.length - 1);
    final maxLag = (sampleRate * 60 / context.minBpm)
        .floor()
        .clamp(minLag + 1, normalized.length - 1);
    if (minLag >= maxLag) return null;

    final lag = SignalUtils.dominantLag(
      normalized,
      minLag: minLag,
      maxLag: maxLag,
    );
    if (lag == null) return null;

    return _LagResult(lagSamples: lag, normalized: normalized);
  }
}

const sqrt2Constant = 1.4142135623730951;

List<double> _movingAverage(List<double> data, int windowSize) {
  if (data.isEmpty || windowSize <= 1) {
    return List<double>.from(data);
  }
  final window = min(windowSize, data.length);
  final result = List<double>.filled(data.length, 0);
  var sum = 0.0;

  for (var i = 0; i < data.length; i++) {
    sum += data[i];
    if (i >= window) {
      sum -= data[i - window];
    }
    final currentWindow = min(i + 1, window);
    result[i] = sum / currentWindow;
  }
  return result;
}

List<double> _removeDc(List<double> data) {
  if (data.isEmpty) return data;
  final mean = data.reduce((a, b) => a + b) / data.length;
  return data.map((value) => value - mean).toList();
}

List<double> _upsampleToLength(List<double> data, int targetLength) {
  if (targetLength <= 0) return const [];
  if (data.isEmpty) {
    return List<double>.filled(targetLength, 0);
  }
  if (data.length == targetLength) {
    return List<double>.from(data);
  }
  final result = List<double>.filled(targetLength, 0);
  final scale = data.length / targetLength;
  for (var i = 0; i < targetLength; i++) {
    final sourceIndex = (i * scale).floor().clamp(0, data.length - 1);
    result[i] = data[sourceIndex];
  }
  return result;
}

class _LagResult {
  const _LagResult({
    required this.lagSamples,
    required this.normalized,
  });

  final int lagSamples;
  final List<double> normalized;
}
