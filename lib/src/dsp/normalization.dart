import 'dart:math' as math;
import 'dart:typed_data';

/// Normalization utilities for audio signal processing.
///
/// Provides RMS normalization, peak normalization, and dynamic range compression
/// to prepare signals for BPM detection.

/// Normalizes samples to a target RMS level in dBFS.
///
/// RMS (Root Mean Square) normalization ensures consistent loudness across
/// different audio sources. Target level of -18 dBFS is a good default for
/// music analysis.
///
/// [samples] - Input audio samples
/// [targetDbFS] - Target RMS level in decibels full scale (default: -18.0)
///
/// Returns normalized samples with consistent RMS level.
Float32List normalizeRMS(Float32List samples, {double targetDbFS = -18.0}) {
  if (samples.isEmpty) return Float32List(0);

  // Calculate current RMS
  double sumSquares = 0.0;
  for (final sample in samples) {
    sumSquares += sample * sample;
  }
  final rms = math.sqrt(sumSquares / samples.length);

  // Avoid division by zero
  if (rms < 1e-10) {
    return Float32List.fromList(samples);
  }

  // Convert target dBFS to linear scale
  final targetLinear = math.pow(10.0, targetDbFS / 20.0).toDouble();

  // Calculate gain needed to reach target RMS
  final gain = targetLinear / rms;

  // Apply gain and clip to prevent overflow
  final result = Float32List(samples.length);
  for (int i = 0; i < samples.length; i++) {
    result[i] = (samples[i] * gain).clamp(-1.0, 1.0);
  }

  return result;
}

/// Normalizes samples to a target peak amplitude.
///
/// Peak normalization scales the signal so the maximum absolute value
/// reaches the target peak level. Simpler than RMS but can be affected
/// by outlier samples.
///
/// [samples] - Input audio samples
/// [targetPeak] - Target peak amplitude (default: 0.9 to leave headroom)
///
/// Returns normalized samples with specified peak amplitude.
Float32List normalizePeak(Float32List samples, {double targetPeak = 0.9}) {
  if (samples.isEmpty) return Float32List(0);

  // Find current peak
  double peak = 0.0;
  for (final sample in samples) {
    final abs = sample.abs();
    if (abs > peak) peak = abs;
  }

  // Avoid division by zero
  if (peak < 1e-10) {
    return Float32List.fromList(samples);
  }

  // Calculate gain and apply
  final gain = targetPeak / peak;
  final result = Float32List(samples.length);
  for (int i = 0; i < samples.length; i++) {
    result[i] = samples[i] * gain;
  }

  return result;
}

/// Applies dynamic range compression to reduce amplitude variation.
///
/// Compression reduces the dynamic range by attenuating signals above a
/// threshold. Useful for making quiet beats more prominent and loud beats
/// less dominant in the analysis.
///
/// [samples] - Input audio samples
/// [threshold] - Amplitude threshold above which compression is applied (0.0-1.0)
/// [ratio] - Compression ratio (e.g., 4.0 means 4:1 compression)
/// [makeupGain] - Gain applied after compression to restore level
///
/// Returns compressed samples.
Float32List compress(
  Float32List samples, {
  double threshold = 0.5,
  double ratio = 4.0,
  double makeupGain = 1.0,
}) {
  if (samples.isEmpty) return Float32List(0);

  final result = Float32List(samples.length);

  for (int i = 0; i < samples.length; i++) {
    final sample = samples[i];
    final abs = sample.abs();

    if (abs > threshold) {
      // Calculate compressed amplitude
      final excess = abs - threshold;
      final compressedExcess = excess / ratio;
      final compressedAbs = threshold + compressedExcess;

      // Preserve sign, apply makeup gain
      result[i] = (sample.sign * compressedAbs * makeupGain).clamp(-1.0, 1.0);
    } else {
      // Below threshold, just apply makeup gain
      result[i] = (sample * makeupGain).clamp(-1.0, 1.0);
    }
  }

  return result;
}

/// Calculates the RMS (Root Mean Square) value of samples.
///
/// RMS represents the effective "power" or loudness of the signal.
///
/// [samples] - Input audio samples
///
/// Returns RMS value.
double calculateRMS(Float32List samples) {
  if (samples.isEmpty) return 0.0;

  double sumSquares = 0.0;
  for (final sample in samples) {
    sumSquares += sample * sample;
  }

  return math.sqrt(sumSquares / samples.length);
}

/// Calculates the RMS value in decibels full scale (dBFS).
///
/// [samples] - Input audio samples
///
/// Returns RMS in dBFS, or -infinity for silence.
double calculateRMSdB(Float32List samples) {
  final rms = calculateRMS(samples);
  if (rms < 1e-10) return double.negativeInfinity;
  return 20.0 * math.log(rms) / math.ln10;
}

/// Removes DC offset by subtracting the mean.
///
/// DC offset is a constant value added to all samples, which can interfere
/// with some DSP operations.
///
/// [samples] - Input audio samples
///
/// Returns samples with zero mean.
Float32List removeDC(Float32List samples) {
  if (samples.isEmpty) return Float32List(0);

  // Calculate mean
  double sum = 0.0;
  for (final sample in samples) {
    sum += sample;
  }
  final mean = sum / samples.length;

  // Subtract mean from each sample
  final result = Float32List(samples.length);
  for (int i = 0; i < samples.length; i++) {
    result[i] = samples[i] - mean;
  }

  return result;
}
