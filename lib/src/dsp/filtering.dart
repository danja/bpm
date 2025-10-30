import 'dart:math' as math;
import 'dart:typed_data';

/// Audio filtering utilities for signal preprocessing.
///
/// Provides high-pass, low-pass, and bandpass filters optimized for
/// rhythmic content extraction in BPM detection.

/// Applies a first-order high-pass filter to remove DC offset and low-frequency content.
///
/// High-pass filtering is essential for BPM detection to remove rumble,
/// DC offset, and sub-bass content that doesn't contribute to rhythm.
///
/// [samples] - Input audio samples
/// [sampleRate] - Sample rate in Hz
/// [cutoffHz] - Cutoff frequency in Hz (default: 20 Hz for DC removal)
///
/// Returns filtered samples with attenuated low frequencies.
Float32List highpassFilter(
  Float32List samples,
  int sampleRate, {
  double cutoffHz = 20.0,
}) {
  if (samples.isEmpty) return Float32List(0);

  // Calculate filter coefficient using RC high-pass formula
  final rc = 1.0 / (2.0 * math.pi * cutoffHz);
  final dt = 1.0 / sampleRate;
  final alpha = rc / (rc + dt);

  final result = Float32List(samples.length);
  result[0] = samples[0];

  // Apply recursive filter: y[i] = alpha * (y[i-1] + x[i] - x[i-1])
  for (int i = 1; i < samples.length; i++) {
    result[i] = alpha * (result[i - 1] + samples[i] - samples[i - 1]);
  }

  return result;
}

/// Applies a first-order low-pass filter to smooth the signal.
///
/// Low-pass filtering removes high-frequency noise and smooths
/// the signal envelope. Useful for creating smooth onset envelopes.
///
/// [samples] - Input audio samples
/// [sampleRate] - Sample rate in Hz
/// [cutoffHz] - Cutoff frequency in Hz
///
/// Returns filtered samples with attenuated high frequencies.
Float32List lowpassFilter(
  Float32List samples,
  int sampleRate, {
  required double cutoffHz,
}) {
  if (samples.isEmpty) return Float32List(0);

  // Calculate filter coefficient using RC low-pass formula
  final rc = 1.0 / (2.0 * math.pi * cutoffHz);
  final dt = 1.0 / sampleRate;
  final alpha = dt / (rc + dt);

  final result = Float32List(samples.length);
  result[0] = samples[0];

  // Apply recursive filter: y[i] = y[i-1] + alpha * (x[i] - y[i-1])
  for (int i = 1; i < samples.length; i++) {
    result[i] = result[i - 1] + alpha * (samples[i] - result[i - 1]);
  }

  return result;
}

/// Applies a bandpass filter to isolate rhythmic content.
///
/// Bandpass filtering focuses analysis on frequencies where musical rhythm
/// typically occurs (20-1500 Hz), removing both low-frequency rumble and
/// high-frequency harmonic content that don't contribute to beat detection.
///
/// [samples] - Input audio samples
/// [sampleRate] - Sample rate in Hz
/// [lowCutoff] - Low cutoff frequency in Hz (default: 20 Hz)
/// [highCutoff] - High cutoff frequency in Hz (default: 1500 Hz)
///
/// Returns filtered samples in the specified frequency band.
Float32List bandpassFilter(
  Float32List samples,
  int sampleRate, {
  double lowCutoff = 20.0,
  double highCutoff = 1500.0,
}) {
  if (samples.isEmpty) return Float32List(0);

  // Apply high-pass to remove frequencies below lowCutoff
  Float32List filtered = highpassFilter(samples, sampleRate, cutoffHz: lowCutoff);

  // Apply low-pass to remove frequencies above highCutoff
  filtered = lowpassFilter(filtered, sampleRate, cutoffHz: highCutoff);

  return filtered;
}

/// Applies an exponential moving average (EMA) smoothing filter.
///
/// EMA is a simple and efficient smoothing technique useful for
/// creating envelope followers and smoothing onset strength functions.
///
/// [samples] - Input audio samples
/// [alpha] - Smoothing factor (0.0-1.0). Lower = more smoothing
///
/// Returns smoothed samples.
Float32List exponentialSmooth(Float32List samples, {double alpha = 0.1}) {
  if (samples.isEmpty) return Float32List(0);
  if (alpha < 0.0 || alpha > 1.0) {
    throw ArgumentError('alpha must be between 0.0 and 1.0');
  }

  final result = Float32List(samples.length);
  result[0] = samples[0];

  for (int i = 1; i < samples.length; i++) {
    result[i] = alpha * samples[i] + (1.0 - alpha) * result[i - 1];
  }

  return result;
}

/// Applies a simple moving average filter for smoothing.
///
/// Moving average is a basic smoothing filter that averages nearby samples.
/// Good for reducing noise while preserving overall signal shape.
///
/// [samples] - Input audio samples
/// [windowSize] - Number of samples to average (must be odd)
///
/// Returns smoothed samples.
Float32List movingAverageFilter(Float32List samples, {int windowSize = 5}) {
  if (samples.isEmpty) return Float32List(0);
  if (windowSize % 2 == 0) windowSize++; // Ensure odd for symmetry

  final halfWindow = windowSize ~/ 2;
  final result = Float32List(samples.length);

  for (int i = 0; i < samples.length; i++) {
    double sum = 0.0;
    int count = 0;

    for (int j = -halfWindow; j <= halfWindow; j++) {
      final idx = i + j;
      if (idx >= 0 && idx < samples.length) {
        sum += samples[idx];
        count++;
      }
    }

    result[i] = sum / count;
  }

  return result;
}

/// Applies a median filter for noise reduction while preserving edges.
///
/// Median filtering is excellent for removing impulse noise and outliers
/// while preserving sharp transitions (like beat onsets).
///
/// [samples] - Input audio samples
/// [windowSize] - Size of the median window (must be odd)
///
/// Returns filtered samples.
Float32List medianFilter(Float32List samples, {int windowSize = 5}) {
  if (samples.isEmpty) return Float32List(0);
  if (windowSize % 2 == 0) windowSize++; // Ensure odd for symmetry

  final halfWindow = windowSize ~/ 2;
  final result = Float32List(samples.length);
  final window = <double>[];

  for (int i = 0; i < samples.length; i++) {
    window.clear();

    for (int j = -halfWindow; j <= halfWindow; j++) {
      final idx = i + j;
      if (idx >= 0 && idx < samples.length) {
        window.add(samples[idx]);
      }
    }

    // Find median
    window.sort();
    result[i] = window[window.length ~/ 2];
  }

  return result;
}

/// Estimates the noise floor of a signal using RMS of quiet sections.
///
/// Divides signal into frames and finds the RMS of the quietest frames
/// to estimate background noise level. Useful for adaptive thresholding.
///
/// [samples] - Input audio samples
/// [frameSize] - Size of frames for analysis (default: 2048)
/// [percentile] - Percentile of quiet frames to use (default: 10th percentile)
///
/// Returns estimated noise floor RMS value.
double estimateNoiseFloor(
  Float32List samples, {
  int frameSize = 2048,
  double percentile = 0.1,
}) {
  if (samples.length < frameSize) {
    // For short signals, just return overall RMS
    double sumSquares = 0.0;
    for (final sample in samples) {
      sumSquares += sample * sample;
    }
    return math.sqrt(sumSquares / samples.length);
  }

  // Calculate RMS for each frame
  final rmsValues = <double>[];
  for (int i = 0; i + frameSize <= samples.length; i += frameSize ~/ 2) {
    double sumSquares = 0.0;
    for (int j = 0; j < frameSize; j++) {
      final sample = samples[i + j];
      sumSquares += sample * sample;
    }
    rmsValues.add(math.sqrt(sumSquares / frameSize));
  }

  // Sort and find percentile
  rmsValues.sort();
  final idx = (rmsValues.length * percentile).floor().clamp(0, rmsValues.length - 1);
  return rmsValues[idx];
}
