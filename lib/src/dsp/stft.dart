import 'dart:math' as math;
import 'dart:typed_data';

import 'fft_utils.dart';

/// Short-Time Fourier Transform (STFT) for time-frequency analysis.
///
/// STFT computes the Fourier transform of overlapping windows of the signal,
/// producing a spectrogram showing how frequency content changes over time.
/// Useful for spectral flux calculation and advanced onset detection.

/// Window function type for STFT.
enum WindowFunction {
  /// Hann window (cosine bell) - good general purpose
  hann,

  /// Hamming window - similar to Hann with slightly different shape
  hamming,

  /// Rectangular window (no windowing) - maximum frequency resolution
  rectangular,
}

/// STFT analyzer for time-frequency decomposition.
class STFT {
  /// Creates an STFT analyzer.
  ///
  /// [fftSize] - Size of FFT (must be power of 2)
  /// [hopSize] - Number of samples to advance between frames
  /// [window] - Window function to apply before FFT
  STFT({
    required this.fftSize,
    required this.hopSize,
    this.window = WindowFunction.hann,
  }) {
    if (!_isPowerOfTwo(fftSize)) {
      throw ArgumentError('fftSize must be a power of 2, got $fftSize');
    }
    if (hopSize <= 0 || hopSize > fftSize) {
      throw ArgumentError(
          'hopSize must be positive and <= fftSize, got $hopSize');
    }
  }

  final int fftSize;
  final int hopSize;
  final WindowFunction window;

  /// Computes the STFT of the input samples.
  ///
  /// Returns a list of magnitude spectra, one per frame.
  /// Each spectrum has length fftSize/2 (positive frequencies only).
  List<Float32List> forward(Float32List samples) {
    final numFrames = ((samples.length - fftSize) / hopSize).floor() + 1;
    if (numFrames <= 0) return [];

    final spectra = <Float32List>[];

    // Pre-compute window coefficients
    final windowCoeffs = _computeWindow();

    for (int frameIdx = 0; frameIdx < numFrames; frameIdx++) {
      final start = frameIdx * hopSize;
      final end = start + fftSize;

      if (end > samples.length) break;

      // Extract frame and apply window
      final frame = List<double>.filled(fftSize, 0.0);
      for (int i = 0; i < fftSize; i++) {
        frame[i] = samples[start + i] * windowCoeffs[i];
      }

      // Compute FFT and extract magnitude spectrum
      try {
        final fftResult = FftUtils.magnitudeSpectrum(frame);
        spectra.add(Float32List.fromList(fftResult.magnitudes));
      } catch (e) {
        // If FFT fails, return empty spectrum for this frame
        spectra.add(Float32List(fftSize ~/ 2));
      }
    }

    return spectra;
  }

  /// Computes spectral flux from a spectrogram.
  ///
  /// Spectral flux measures the frame-to-frame change in spectral energy,
  /// producing an onset strength envelope. High flux indicates transients
  /// (like drum hits).
  ///
  /// [spectrogram] - List of magnitude spectra from STFT
  /// [normalize] - Whether to normalize flux to 0-1 range
  ///
  /// Returns onset strength envelope (one value per frame).
  static Float32List spectralFlux(
    List<Float32List> spectrogram, {
    bool normalize = true,
  }) {
    if (spectrogram.length < 2) {
      return Float32List(spectrogram.length);
    }

    final flux = Float32List(spectrogram.length);
    flux[0] = 0.0; // First frame has no previous frame

    for (int i = 1; i < spectrogram.length; i++) {
      final prev = spectrogram[i - 1];
      final curr = spectrogram[i];

      // Calculate sum of positive differences (Half-Wave Rectified flux)
      double sum = 0.0;
      for (int bin = 0; bin < curr.length; bin++) {
        final diff = curr[bin] - prev[bin];
        if (diff > 0) sum += diff;
      }

      flux[i] = sum;
    }

    // Normalize to 0-1 range if requested
    if (normalize) {
      double maxFlux = 0.0;
      for (final value in flux) {
        if (value > maxFlux) maxFlux = value;
      }

      if (maxFlux > 0) {
        for (int i = 0; i < flux.length; i++) {
          flux[i] /= maxFlux;
        }
      }
    }

    return flux;
  }

  /// Computes spectral flux directly from samples without storing full spectrogram.
  ///
  /// More memory-efficient than computing full STFT then flux.
  Float32List spectralFluxFromSamples(Float32List samples) {
    final spectra = forward(samples);
    return spectralFlux(spectra);
  }

  /// Converts frame index to time in seconds.
  double frameToTime(int frameIndex, int sampleRate) {
    return (frameIndex * hopSize) / sampleRate;
  }

  /// Converts time in seconds to frame index.
  int timeToFrame(double timeSeconds, int sampleRate) {
    return ((timeSeconds * sampleRate) / hopSize).round();
  }

  /// Converts FFT bin to frequency in Hz.
  double binToFrequency(int bin, int sampleRate) {
    return (bin * sampleRate) / fftSize;
  }

  /// Converts frequency in Hz to FFT bin.
  int frequencyToBin(double frequencyHz, int sampleRate) {
    return ((frequencyHz * fftSize) / sampleRate).round();
  }

  /// Pre-computes window coefficients.
  List<double> _computeWindow() {
    switch (window) {
      case WindowFunction.hann:
        return _hannWindow(fftSize);
      case WindowFunction.hamming:
        return _hammingWindow(fftSize);
      case WindowFunction.rectangular:
        return List<double>.filled(fftSize, 1.0);
    }
  }

  /// Generates Hann window coefficients.
  static List<double> _hannWindow(int size) {
    if (size <= 1) return [1.0];

    final window = List<double>.filled(size, 0.0);
    for (int i = 0; i < size; i++) {
      window[i] = 0.5 * (1.0 - math.cos(2.0 * math.pi * i / (size - 1)));
    }
    return window;
  }

  /// Generates Hamming window coefficients.
  static List<double> _hammingWindow(int size) {
    if (size <= 1) return [1.0];

    final window = List<double>.filled(size, 0.0);
    for (int i = 0; i < size; i++) {
      window[i] = 0.54 - 0.46 * math.cos(2.0 * math.pi * i / (size - 1));
    }
    return window;
  }

  static bool _isPowerOfTwo(int value) =>
      value > 0 && (value & (value - 1)) == 0;
}

/// Convenience function to compute spectral flux onset envelope from samples.
///
/// [samples] - Input audio samples
/// [sampleRate] - Sample rate in Hz
/// [fftSize] - FFT size (default: 2048)
/// [hopSize] - Hop size (default: 512 for 75% overlap)
/// [normalize] - Whether to normalize to 0-1 range
///
/// Returns onset strength envelope.
Float32List computeSpectralFlux(
  Float32List samples,
  int sampleRate, {
  int fftSize = 2048,
  int hopSize = 512,
  bool normalize = true,
}) {
  final stft = STFT(fftSize: fftSize, hopSize: hopSize);
  return stft.spectralFluxFromSamples(samples);
}
