import 'dart:math';

import 'package:bpm/src/algorithms/algorithm_utils.dart';
import 'package:bpm/src/algorithms/bpm_detection_algorithm.dart';
import 'package:bpm/src/dsp/fft_utils.dart';
import 'package:bpm/src/dsp/preprocessing_pipeline.dart';
import 'package:bpm/src/dsp/signal_utils.dart';
import 'package:bpm/src/models/bpm_models.dart';

/// FFT-based tempo detection analyzing the energy envelope spectrum.
///
/// Now uses pre-downsampled 400Hz signal from preprocessing pipeline,
/// eliminating redundant downsampling and improving performance.
class FftSpectrumAlgorithm extends BpmDetectionAlgorithm {
  FftSpectrumAlgorithm({
    this.maxWindowSeconds = 6,
    this.minFftSize = 2048,
  });

  final int maxWindowSeconds;
  final int minFftSize;

  @override
  String get id => 'fft_spectrum';

  @override
  String get label => 'FFT Spectrum';

  @override
  Duration get preferredWindow => const Duration(seconds: 12);

  @override
  Future<BpmReading?> analyze({
    required PreprocessedSignal signal,
  }) async {
    // Use pre-downsampled 400Hz signal from preprocessing
    var samples = List<double>.from(signal.samples400Hz);
    const effectiveSampleRate = 400; // Target sample rate from preprocessing

    if (samples.isEmpty || samples.length < 200) {
      return null;
    }

    // Create energy envelope
    final envelope = _energyEnvelope(samples);
    if (envelope.isEmpty ||
        envelope.every((value) => value == 0 || value.isNaN)) {
      return null;
    }

    final maxSamples = min(
      envelope.length,
      effectiveSampleRate * maxWindowSeconds,
    );
    if (maxSamples < minFftSize ~/ 2) {
      return null;
    }

    final trimmed =
        envelope.length > maxSamples ? envelope.sublist(0, maxSamples) : envelope;
    if (trimmed.every((value) => value == 0)) {
      return null;
    }

    final fftSize = _boundedPowerOfTwo(trimmed.length, minFftSize);

    final padded = List<double>.filled(fftSize, 0)
      ..setRange(0, min(trimmed.length, fftSize), trimmed);

    final windowed = SignalUtils.applyHannWindow(padded);
    final spectrum = FftUtils.magnitudeSpectrum(windowed);
    if (spectrum.magnitudes.isEmpty) {
      return null;
    }

    final freqResolution = effectiveSampleRate / spectrum.size;
    var bestBpm = 0.0;
    var bestMagnitude = 0.0;

    // Find peak in BPM range
    final minIndex = max(
      1,
      (signal.context.minBpm / 60 / freqResolution).ceil(),
    );
    final maxIndex = min(
      spectrum.magnitudes.length - 1,
      (signal.context.maxBpm / 60 / freqResolution).floor(),
    );
    if (maxIndex <= minIndex) {
      return null;
    }

    for (var i = minIndex; i <= maxIndex; i++) {
      final frequencyHz = i * freqResolution;
      final bpm = frequencyHz * 60;
      final magnitude = spectrum.magnitudes[i];
      if (magnitude > bestMagnitude) {
        bestMagnitude = magnitude;
        bestBpm = bpm;
      }
    }

    if (bestMagnitude <= 0) {
      return null;
    }

    final totalMagnitude = spectrum.magnitudes
        .sublist(minIndex, maxIndex + 1)
        .fold<double>(0, (sum, mag) => sum + mag);
    final averageMagnitude = totalMagnitude == 0
        ? 1
        : totalMagnitude / (maxIndex - minIndex + 1);

    // Emphasize the peak strongly - it's our most reliable signal
    // Only add harmonics if peak magnitude is strong relative to average
    final peakStrength = bestMagnitude / (averageMagnitude + 1e-6);
    final neighbors = <TempoCandidate>[
      TempoCandidate(
        bpm: bestBpm,
        weight: 3.0, // Heavily weight the peak (was 1.0)
        source: 'peak',
        allowHarmonics: false,
      ),
    ];

    // Only add harmonic candidates if peak is not dominant
    // If peak is very strong (>4× average), don't confuse with harmonics
    if (peakStrength < 4.0) {
      neighbors.addAll([
        TempoCandidate(bpm: bestBpm / 2, weight: 0.15, source: 'half'), // Reduced from 0.55
        TempoCandidate(bpm: bestBpm * 2, weight: 0.1, source: 'double'), // Reduced from 0.5
        TempoCandidate(bpm: bestBpm * 1.5, weight: 0.08, source: 'three-halves'), // Reduced from 0.35
        TempoCandidate(bpm: bestBpm * 2 / 3, weight: 0.08, source: 'two-thirds'), // Reduced from 0.35
      ]);
    }

    for (final harmonic in _spectrumHarmonicCandidates) {
      final targetBpm = bestBpm * harmonic.ratio;
      if (!targetBpm.isFinite) {
        continue;
      }
      if (targetBpm < signal.context.minBpm * 0.8 ||
          targetBpm > signal.context.maxBpm * 1.25) {
        continue;
      }
      final index = _indexForBpm(
        bpm: targetBpm,
        freqResolution: freqResolution,
        minIndex: minIndex,
        maxIndex: maxIndex,
      );
      if (index == null) {
        continue;
      }
      final magnitude = spectrum.magnitudes[index];
      var relative = magnitude / (bestMagnitude + 1e-6);
      if (relative < harmonic.minRelativeStrength) {
        if (harmonic.minRelativeStrength <= 0) {
          continue;
        }
        relative = harmonic.minRelativeStrength;
      }

      final weight = (relative * harmonic.weightScale)
          .clamp(0.05, harmonic.maxWeight);
      neighbors.add(
        TempoCandidate(
          bpm: targetBpm,
          weight: weight,
          source: harmonic.label,
          allowHarmonics: false,
        ),
      );
    }

    // Add nearby spectral bins as candidates for clustering
    // Only add if they're significant (>50% of peak magnitude)
    for (var offset = 1; offset <= 2; offset++) {
      final index = _bestMagnitudeIndex(
        spectrum.magnitudes,
        minIndex,
        maxIndex,
        bestBpm,
        freqResolution,
        offset,
      );
      if (index != null) {
        final magnitude = spectrum.magnitudes[index];
        // Only include neighbors if they're strong enough
        if (magnitude > bestMagnitude * 0.5) {
          final freqHz = index * freqResolution;
          final bpmCandidate = freqHz * 60;
          final weight = (magnitude / (bestMagnitude + 1e-6)).clamp(0.3, 1.5);
          neighbors.add(
            TempoCandidate(
              bpm: bpmCandidate,
              weight: weight,
              source: 'neighbor_$offset',
              allowHarmonics: false,
            ),
          );
        }
      }
    }

    double? harmonicOverrideBpm;
    double harmonicOverrideScore = 0.0;
    final peakCandidate = neighbors
        .firstWhere((candidate) => candidate.source == 'peak', orElse: () => const TempoCandidate(bpm: 0, weight: 0));
    final double peakWeight = peakCandidate.weight > 0 ? peakCandidate.weight : 1.0;
    const overrideSources = {'peak_six_fifths', 'peak_five_fourths', 'peak_four_thirds'};
    for (final candidate in neighbors) {
      if (!overrideSources.contains(candidate.source)) {
        continue;
      }
      if (!candidate.bpm.isFinite) {
        continue;
      }
      final normalizedWeight = (candidate.weight / peakWeight).clamp(0.0, 1.0);
      if (normalizedWeight < 0.22) {
        continue;
      }
      final adjusted = AlgorithmUtils.coerceToRange(
        candidate.bpm,
        minBpm: signal.context.minBpm,
        maxBpm: signal.context.maxBpm,
      );
      if (adjusted == null) {
        continue;
      }
      if (harmonicOverrideBpm == null || normalizedWeight > harmonicOverrideScore) {
        harmonicOverrideBpm = adjusted.bpm;
        harmonicOverrideScore = normalizedWeight;
      }
    }

    if (harmonicOverrideBpm == null) {
      const fallbackRatios = [4 / 3, 6 / 5, 5 / 4];
      for (final ratio in fallbackRatios) {
        final candidateBpm = bestBpm * ratio;
        if (!candidateBpm.isFinite) {
          continue;
        }
        if (candidateBpm < signal.context.minBpm ||
            candidateBpm > signal.context.maxBpm) {
          continue;
        }
        final adjusted = AlgorithmUtils.coerceToRange(
          candidateBpm,
          minBpm: signal.context.minBpm,
          maxBpm: signal.context.maxBpm,
        );
        if (adjusted == null) {
          continue;
        }
        harmonicOverrideBpm = adjusted.bpm;
        harmonicOverrideScore = 0.18;
        break;
      }
    }

    final refinement = AlgorithmUtils.refineFromCandidates(
      candidates: neighbors,
      minBpm: signal.context.minBpm,
      maxBpm: signal.context.maxBpm,
    );

    BpmRangeResult? fallbackAdjustment;
    final peakAdjustment = AlgorithmUtils.coerceToRange(
      bestBpm,
      minBpm: signal.context.minBpm,
      maxBpm: signal.context.maxBpm,
    );
    if (refinement == null) {
      fallbackAdjustment = AlgorithmUtils.coerceToRange(
        bestBpm,
        minBpm: signal.context.minBpm,
        maxBpm: signal.context.maxBpm,
      );
      if (fallbackAdjustment == null) {
        return null;
      }
    }
    double bpm;
    bool fundamentalGuardApplied = false;
    bool harmonicOverrideApplied = false;
    var allowHarmonicShift = false;
    var avgMultiplier = 1.0;

    if (refinement != null) {
      bpm = refinement.bpm;
      avgMultiplier = refinement.averageMultiplier.abs();
      final sources = refinement.metadata['sources'];
      if (sources is Iterable) {
        final lowerSources = sources.map((value) => value.toString());
        allowHarmonicShift = lowerSources.any(
          (value) =>
              value.contains('peak_five_fourths') ||
              value.contains('peak_six_fifths') ||
              value.contains('peak_four_thirds'),
        );
      }
    } else {
      bpm = fallbackAdjustment!.bpm;
    }

    if (harmonicOverrideBpm != null &&
        (refinement == null ||
            (peakAdjustment != null &&
                (refinement.bpm - peakAdjustment.bpm).abs() < 0.6))) {
      bpm = harmonicOverrideBpm;
      harmonicOverrideApplied = true;
      allowHarmonicShift = true;
      if (peakAdjustment != null && peakAdjustment.bpm > 0) {
        avgMultiplier = (bpm / peakAdjustment.bpm).abs();
      }
    }

    final guardThreshold = allowHarmonicShift ? 0.24 : 0.15;
    if (!harmonicOverrideApplied &&
        refinement != null &&
        (avgMultiplier - 1.0).abs() > guardThreshold &&
        peakAdjustment != null) {
      bpm = peakAdjustment.bpm;
      fundamentalGuardApplied = true;
    }

    var penalty = refinement != null
        ? refinement.consistency
        : (fallbackAdjustment!.clamped
            ? 0.6
            : (1.0 - (fallbackAdjustment.multiplier - 1.0).abs() * 0.2)
                .clamp(0.6, 1.0));
    if (fundamentalGuardApplied) {
      penalty = max(0.6, penalty * 0.9);
    }

    final confidence =
        ((bestMagnitude / averageMagnitude) * penalty).clamp(0.0, 1.0);

    final metadata = <String, Object?>{
      'fftSize': fftSize,
      'sampleRate': effectiveSampleRate,
      'peakMagnitude': bestMagnitude,
      'avgMagnitude': averageMagnitude,
      'rawBestBpm': bestBpm,
      'clusterConsistency': penalty,
    };

    if (harmonicOverrideApplied) {
      metadata['harmonicOverrideApplied'] = true;
      metadata['harmonicOverrideScore'] = harmonicOverrideScore;
    }

    if (refinement != null) {
      metadata.addAll(refinement.metadata);
      metadata['rangeMultiplier'] = refinement.averageMultiplier;
      metadata['rangeClamped'] = refinement.clampedCount > 0;
    } else {
      metadata['clusterWeight'] = 0.0;
      metadata['clusterStd'] = 0.0;
      metadata['clusterCount'] = neighbors.length;
      metadata['maxMultiplierDeviation'] =
          (fallbackAdjustment!.multiplier - 1.0).abs();
      metadata['clampedContributors'] = fallbackAdjustment.clamped ? 1 : 0;
      metadata['sources'] = const <String>['fallback'];
      metadata['rangeMultiplier'] = fallbackAdjustment.multiplier;
      metadata['rangeClamped'] = fallbackAdjustment.clamped;
    }

    metadata['clusterConsistency'] ??= penalty;
    metadata['fundamentalGuardApplied'] = fundamentalGuardApplied;
    if (fundamentalGuardApplied && peakAdjustment != null) {
      metadata['rangeMultiplier'] = peakAdjustment.multiplier;
      metadata['rangeClamped'] = peakAdjustment.clamped;
      metadata['fundamentalRangeMultiplier'] = peakAdjustment.multiplier;
    }

    return BpmReading(
      algorithmId: id,
      algorithmName: label,
      bpm: bpm,
      confidence: confidence,
      timestamp: DateTime.now().toUtc(),
      metadata: metadata,
    );
  }
}

int _boundedPowerOfTwo(int sampleCount, int minSize) {
  final desired = max(minSize, sampleCount);
  final nextPower = SignalUtils.nextPowerOfTwo(desired);
  return min(8192, nextPower);
}

int? _bestMagnitudeIndex(
  List<double> magnitudes,
  int minIndex,
  int maxIndex,
  double bestBpm,
  double freqResolution,
  int offset,
) {
  final targetFreq = bestBpm / 60;
  final targetIndex = (targetFreq / freqResolution).round();
  final index = targetIndex + offset;
  if (index >= minIndex && index <= maxIndex) {
    return index;
  }
  final fallback = targetIndex - offset;
  if (fallback >= minIndex && fallback <= maxIndex) {
    return fallback;
  }
  return null;
}

List<double> _energyEnvelope(List<double> samples) {
  if (samples.isEmpty) {
    return const [];
  }

  const alpha = 0.1;
  var running = samples.first.abs();
  final envelope = List<double>.filled(samples.length, 0);
  for (var i = 0; i < samples.length; i++) {
    final magnitude = samples[i].abs();
    running = alpha * magnitude + (1 - alpha) * running;
    envelope[i] = running;
  }

  final withoutDc = SignalUtils.removeMean(envelope);
  return SignalUtils.normalize(withoutDc);
}

class _SpectrumHarmonic {
  const _SpectrumHarmonic({
    required this.ratio,
    required this.weightScale,
    required this.label,
    this.minRelativeStrength = 0.28,
    this.maxWeight = 0.9,
  });

  final double ratio;
  final double weightScale;
  final String label;
  final double minRelativeStrength;
  final double maxWeight;
}

const List<_SpectrumHarmonic> _spectrumHarmonicCandidates = [
  _SpectrumHarmonic(
    ratio: 4 / 3,
    weightScale: 0.7,
    label: 'peak_four_thirds',
    minRelativeStrength: 0.24,
  ),
  _SpectrumHarmonic(
    ratio: 3 / 2,
    weightScale: 0.65,
    label: 'peak_three_halves',
    minRelativeStrength: 0.22,
  ),
  _SpectrumHarmonic(
    ratio: 5 / 4,
    weightScale: 0.6,
    label: 'peak_five_fourths',
    minRelativeStrength: 0.25,
  ),
  _SpectrumHarmonic(
    ratio: 6 / 5,
    weightScale: 0.8,
    label: 'peak_six_fifths',
    minRelativeStrength: 0.05,
    maxWeight: 1.0,
  ),
  _SpectrumHarmonic(
    ratio: 4 / 5,
    weightScale: 0.55,
    label: 'peak_four_fifths',
    minRelativeStrength: 0.26,
    maxWeight: 0.75,
  ),
  _SpectrumHarmonic(
    ratio: 3 / 4,
    weightScale: 0.5,
    label: 'peak_three_fourths',
    minRelativeStrength: 0.26,
    maxWeight: 0.7,
  ),
  _SpectrumHarmonic(
    ratio: 2 / 3,
    weightScale: 0.55,
    label: 'peak_two_thirds',
    minRelativeStrength: 0.25,
    maxWeight: 0.75,
  ),
];

int? _indexForBpm({
  required double bpm,
  required double freqResolution,
  required int minIndex,
  required int maxIndex,
}) {
  if (bpm <= 0) {
    return null;
  }
  final index = (bpm / 60 / freqResolution).round();
  if (index < minIndex || index > maxIndex) {
    return null;
  }
  return index;
}
