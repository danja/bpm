import 'dart:math' as math;
import 'dart:typed_data';

import 'stft.dart';

/// Onset detection utilities for beat and transient detection.
///
/// Provides energy-based and spectral flux-based onset envelope computation,
/// plus adaptive peak picking for identifying beat locations.

/// Detected peak/onset location.
class Peak {
  const Peak({
    required this.index,
    required this.value,
    required this.timeSeconds,
  });

  /// Index in the onset envelope
  final int index;

  /// Onset strength value at this peak
  final double value;

  /// Time in seconds (if sample rate provided)
  final double timeSeconds;

  @override
  String toString() => 'Peak(index: $index, value: ${value.toStringAsFixed(3)}, time: ${timeSeconds.toStringAsFixed(3)}s)';
}

/// Computes energy-based onset envelope using short-time energy.
///
/// Divides signal into overlapping frames, computes RMS energy for each frame,
/// and optionally applies smoothing. Good for detecting sharp transients.
///
/// [samples] - Input audio samples
/// [sampleRate] - Sample rate in Hz
/// [frameSizeMs] - Frame size in milliseconds (default: 30ms)
/// [hopSizeMs] - Hop size in milliseconds (default: 10ms)
/// [smooth] - Apply exponential smoothing to envelope
///
/// Returns onset strength envelope (one value per frame).
Float32List energyOnsetEnvelope(
  Float32List samples,
  int sampleRate, {
  double frameSizeMs = 30.0,
  double hopSizeMs = 10.0,
  bool smooth = true,
}) {
  if (samples.isEmpty) return Float32List(0);

  final frameSizeSamples = (sampleRate * frameSizeMs / 1000).round();
  final hopSizeSamples = (sampleRate * hopSizeMs / 1000).round();

  final numFrames =
      ((samples.length - frameSizeSamples) / hopSizeSamples).floor() + 1;
  if (numFrames <= 0) return Float32List(0);

  final energy = Float32List(numFrames);

  // Compute RMS energy for each frame
  for (int frameIdx = 0; frameIdx < numFrames; frameIdx++) {
    final start = frameIdx * hopSizeSamples;
    final end = math.min(start + frameSizeSamples, samples.length);

    double sumSquares = 0.0;
    for (int i = start; i < end; i++) {
      sumSquares += samples[i] * samples[i];
    }

    energy[frameIdx] = math.sqrt(sumSquares / (end - start));
  }

  // Apply exponential smoothing if requested
  if (smooth) {
    const alpha = 0.3; // Smoothing factor
    for (int i = 1; i < energy.length; i++) {
      energy[i] = alpha * energy[i] + (1.0 - alpha) * energy[i - 1];
    }
  }

  return energy;
}

/// Computes spectral flux onset envelope using STFT.
///
/// Analyzes how spectral energy changes between frames. More sophisticated
/// than energy-based detection, better at handling complex music.
///
/// [samples] - Input audio samples
/// [sampleRate] - Sample rate in Hz
/// [fftSize] - FFT size (default: 2048)
/// [hopSize] - Hop size in samples (default: 512)
/// [normalize] - Normalize to 0-1 range
///
/// Returns onset strength envelope (one value per frame).
Float32List spectralFluxOnsetEnvelope(
  Float32List samples,
  int sampleRate, {
  int fftSize = 2048,
  int hopSize = 512,
  bool normalize = true,
}) {
  return computeSpectralFlux(
    samples,
    sampleRate,
    fftSize: fftSize,
    hopSize: hopSize,
    normalize: normalize,
  );
}

/// Picks peaks from an onset envelope using adaptive thresholding.
///
/// Identifies local maxima that exceed an adaptive threshold based on
/// local statistics. Good for finding beat positions.
///
/// [envelope] - Onset strength envelope
/// [sampleRate] - Sample rate of envelope (e.g., frame rate)
/// [adaptiveThreshold] - Threshold as multiple of (mean + std) (default: 0.3)
/// [minIntervalMs] - Minimum time between peaks in milliseconds (default: 300ms)
/// [timeScale] - Time scaling factor to convert indices to seconds
///
/// Returns list of detected peaks.
List<Peak> pickPeaks(
  Float32List envelope, {
  required double sampleRate,
  double adaptiveThreshold = 0.3,
  double minIntervalMs = 300.0,
  double timeScale = 1.0,
}) {
  if (envelope.length < 3) return [];

  // Calculate mean and standard deviation for adaptive threshold
  double sum = 0.0;
  double sumSquares = 0.0;
  for (final value in envelope) {
    sum += value;
    sumSquares += value * value;
  }

  final mean = sum / envelope.length;
  final variance = sumSquares / envelope.length - mean * mean;
  final std = math.sqrt(variance.abs());

  final threshold = mean + adaptiveThreshold * std;
  final minInterval = (minIntervalMs * sampleRate / 1000).round();

  final peaks = <Peak>[];
  int lastPeakIdx = -minInterval;

  // Find local maxima above threshold
  for (int i = 1; i < envelope.length - 1; i++) {
    final current = envelope[i];
    final prev = envelope[i - 1];
    final next = envelope[i + 1];

    // Check if local maximum above threshold
    if (current > threshold &&
        current >= prev &&
        current >= next &&
        i - lastPeakIdx >= minInterval) {
      peaks.add(Peak(
        index: i,
        value: current,
        timeSeconds: i * timeScale,
      ));
      lastPeakIdx = i;
    }
  }

  return peaks;
}

/// Picks peaks with more sophisticated multi-pass approach.
///
/// Uses multiple threshold levels and validates peaks based on
/// their prominence and isolation.
///
/// [envelope] - Onset strength envelope
/// [sampleRate] - Sample rate of envelope
/// [minIntervalMs] - Minimum time between peaks in milliseconds
/// [timeScale] - Time scaling factor to convert indices to seconds
///
/// Returns list of detected peaks.
List<Peak> pickPeaksAdvanced(
  Float32List envelope, {
  required double sampleRate,
  double minIntervalMs = 300.0,
  double timeScale = 1.0,
}) {
  if (envelope.length < 3) return [];

  // Calculate statistics
  double sum = 0.0;
  double max = double.negativeInfinity;
  for (final value in envelope) {
    sum += value;
    if (value > max) max = value;
  }
  final mean = sum / envelope.length;

  final minInterval = (minIntervalMs * sampleRate / 1000).round();

  // Multi-threshold approach
  final candidates = <Peak>[];

  // Find all local maxima
  for (int i = 1; i < envelope.length - 1; i++) {
    final current = envelope[i];
    final prev = envelope[i - 1];
    final next = envelope[i + 1];

    if (current >= prev && current >= next) {
      candidates.add(Peak(
        index: i,
        value: current,
        timeSeconds: i * timeScale,
      ));
    }
  }

  // Filter by dynamic threshold and spacing
  final peaks = <Peak>[];

  // Sort candidates by strength (descending)
  candidates.sort((a, b) => b.value.compareTo(a.value));

  for (final candidate in candidates) {
    // Check threshold (at least mean + 20% of range)
    final threshold = mean + 0.2 * (max - mean);
    if (candidate.value < threshold) continue;

    // Check spacing from existing peaks
    bool tooClose = false;
    for (final peak in peaks) {
      if ((candidate.index - peak.index).abs() < minInterval) {
        tooClose = true;
        break;
      }
    }

    if (!tooClose) {
      peaks.add(candidate);
    }
  }

  // Sort by time
  peaks.sort((a, b) => a.index.compareTo(b.index));

  return peaks;
}

/// Computes inter-onset intervals (IOIs) from peaks.
///
/// Returns the time differences between consecutive peaks.
///
/// [peaks] - List of detected peaks
///
/// Returns list of intervals in seconds.
List<double> computeInterOnsetIntervals(List<Peak> peaks) {
  if (peaks.length < 2) return [];

  final intervals = <double>[];
  for (int i = 1; i < peaks.length; i++) {
    intervals.add(peaks[i].timeSeconds - peaks[i - 1].timeSeconds);
  }

  return intervals;
}

/// Estimates tempo from inter-onset intervals.
///
/// Converts median IOI to BPM and returns confidence based on
/// IOI variance.
///
/// [peaks] - List of detected peaks
/// [minBpm] - Minimum valid BPM
/// [maxBpm] - Maximum valid BPM
///
/// Returns (bpm, confidence) tuple, or null if estimation fails.
({double bpm, double confidence})? estimateTempoFromPeaks(
  List<Peak> peaks, {
  double minBpm = 50.0,
  double maxBpm = 200.0,
}) {
  final intervals = computeInterOnsetIntervals(peaks);
  if (intervals.length < 3) return null;

  // Calculate median interval
  final sortedIntervals = List<double>.from(intervals)..sort();
  final median = sortedIntervals[sortedIntervals.length ~/ 2];

  if (median <= 0) return null;

  // Convert to BPM
  double bpm = 60.0 / median;

  // Handle octave errors
  while (bpm < minBpm) {
    bpm *= 2;
  }
  while (bpm > maxBpm) {
    bpm /= 2;
  }

  if (bpm < minBpm || bpm > maxBpm) return null;

  // Calculate confidence from IOI variance
  double sumSquares = 0.0;
  for (final interval in intervals) {
    final diff = interval - median;
    sumSquares += diff * diff;
  }
  final variance = sumSquares / intervals.length;
  final confidence = 1.0 / (1.0 + variance / 0.5);

  return (bpm: bpm, confidence: confidence.clamp(0.0, 1.0));
}
