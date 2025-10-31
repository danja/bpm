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

    final neighbors = <TempoCandidate>[
      TempoCandidate(
        bpm: bestBpm,
        weight: 1.0,
        source: 'peak',
        allowHarmonics: false,
      ),
      TempoCandidate(bpm: bestBpm / 2, weight: 0.55, source: 'half'),
      TempoCandidate(bpm: bestBpm * 2, weight: 0.5, source: 'double'),
      TempoCandidate(bpm: bestBpm * 1.5, weight: 0.35, source: 'three-halves'),
      TempoCandidate(bpm: bestBpm * 2 / 3, weight: 0.35, source: 'two-thirds'),
    ];

    // Add nearby spectral bins as candidates for clustering.
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
        final freqHz = index * freqResolution;
        final bpmCandidate = freqHz * 60;
        final magnitude = spectrum.magnitudes[index];
        final weight = (magnitude / (bestMagnitude + 1e-6)).clamp(0.2, 1.0);
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
    if (refinement != null) {
      bpm = refinement.bpm;
      final avgMultiplier = refinement.averageMultiplier.abs();
      if ((avgMultiplier - 1.0).abs() > 0.25 && peakAdjustment != null) {
        bpm = peakAdjustment.bpm;
        fundamentalGuardApplied = true;
      }
    } else {
      bpm = fallbackAdjustment!.bpm;
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
