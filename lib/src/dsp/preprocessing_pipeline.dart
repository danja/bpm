import 'dart:math' as math;
import 'dart:typed_data';

import '../algorithms/detection_context.dart';
import '../models/bpm_models.dart';
import 'filtering.dart';
import 'mel_spectrogram.dart';
import 'novelty.dart';
import 'normalization.dart';
import 'onset_detection.dart';
import 'signal_utils.dart';
import 'tempogram.dart';

/// Onset envelope computed for a specific frequency band.
class BandOnsetEnvelope {
  const BandOnsetEnvelope({
    required this.label,
    required this.lowCutoff,
    required this.highCutoff,
    required this.weight,
    required this.envelope,
  });

  /// Human-readable label (e.g., `low`, `mid`, `high`).
  final String label;

  /// Lower cutoff frequency in Hz.
  final double lowCutoff;

  /// Upper cutoff frequency in Hz.
  final double highCutoff;

  /// Weight used when combining this band into the aggregate onset envelope.
  final double weight;

  /// Normalized onset envelope for this band.
  final Float32List envelope;

  /// Center frequency helper.
  double get centerFrequency => (lowCutoff + highCutoff) * 0.5;
}

/// Preprocessed signal with derived features for algorithm analysis.
///
/// Contains multiple representations of the audio signal optimized for
/// different BPM detection algorithms, computed once and shared to avoid
/// redundant processing.
class PreprocessedSignal {
  const PreprocessedSignal({
    required this.rawSamples,
    required this.normalizedSamples,
    required this.filteredSamples,
    required this.onsetEnvelope,
    required this.multiBandOnsetEnvelopes,
    required this.samples8kHz,
    required this.samples400Hz,
    required this.melSpectrogram,
    required this.melBandMeans,
    required this.noveltyCurve,
    required this.noveltyFeatureRate,
    required this.tempogram,
    required this.tempoAxis,
    required this.tempogramTimes,
    required this.dominantTempoCurve,
    required this.dominantTempoStrength,
    required this.originalSampleRate,
    required this.duration,
    required this.context,
    required this.noiseFloor,
  });

  /// Original unprocessed samples
  final Float32List rawSamples;

  /// RMS-normalized samples (-18 dBFS target)
  final Float32List normalizedSamples;

  /// Bandpass filtered samples (20-1500 Hz, rhythmic content)
  final Float32List filteredSamples;

  /// Energy-based onset strength envelope
  final Float32List onsetEnvelope;

  /// Band-specific onset envelopes (low/mid/high rhythm emphasis)
  final List<BandOnsetEnvelope> multiBandOnsetEnvelopes;

  /// Downsampled to 8 kHz (for autocorrelation)
  final Float32List samples8kHz;

  /// Downsampled to 400 Hz (for FFT tempo analysis)
  final Float32List samples400Hz;

  /// Mel-spectrogram frames (mel bands × time)
  final List<Float32List> melSpectrogram;

  /// Mean mel-band energy profile (length == number of mel bands)
  final Float32List melBandMeans;

  /// Spectral-flux novelty curve (Tempogram toolbox inspired)
  final Float32List noveltyCurve;

  /// Feature rate of novelty curve (Hz)
  final double noveltyFeatureRate;

  /// Tempogram magnitude matrix (rows=time, cols=tempo bins)
  final List<Float32List> tempogram;

  /// Tempo axis for tempogram (BPM)
  final Float32List tempoAxis;

  /// Time axis for tempogram frames (seconds)
  final Float32List tempogramTimes;

  /// Dominant tempo per frame (BPM)
  final Float32List dominantTempoCurve;
  final Float32List dominantTempoStrength;

  /// Original sample rate in Hz
  final int originalSampleRate;

  /// Duration of signal
  final Duration duration;

  /// Detection context (BPM range, etc.)
  final DetectionContext context;

  /// Estimated noise floor RMS
  final double noiseFloor;

  /// Number of samples in original signal
  int get length => rawSamples.length;

  /// Time scale for onset envelope (seconds per sample)
  double get onsetTimeScale {
    // Onset envelope is computed with 10ms hop, so ~100 samples per second
    return 0.01; // 10ms hop size
  }
}

/// Preprocessing pipeline that computes shared features for BPM detection.
///
/// Transforms raw audio frames into a PreprocessedSignal containing
/// multiple optimized representations. This eliminates redundant computations
/// across different algorithms.
class PreprocessingPipeline {
  const PreprocessingPipeline();

  static final NoveltyComputer _noveltyComputer = NoveltyComputer();
  static final TempogramComputer _tempogramComputer = TempogramComputer();
  static const List<_OnsetBandConfig> _onsetBandConfigs = [
    _OnsetBandConfig(
      label: 'low',
      lowCutoff: 20.0,
      highCutoff: 140.0,
      weight: 0.50, // ENHANCEMENT: Increase bass/kick weight (was 0.45)
      frameSizeMs: 40.0,
      hopSizeMs: 12.0,
    ),
    _OnsetBandConfig(
      label: 'mid',
      lowCutoff: 140.0,
      highCutoff: 480.0,
      weight: 0.38, // ENHANCEMENT: Increase mid/snare weight (was 0.35)
      frameSizeMs: 28.0,
      hopSizeMs: 9.0,
    ),
    _OnsetBandConfig(
      label: 'high',
      lowCutoff: 480.0,
      highCutoff: 1500.0,
      weight: 0.12, // ENHANCEMENT: Reduce high-hat weight (was 0.20)
      frameSizeMs: 22.0,
      hopSizeMs: 8.0,
    ),
  ];

  /// Processes audio frames into preprocessed signal.
  ///
  /// [window] - List of audio frames to process
  /// [context] - Detection context (sample rate, BPM range, etc.)
  ///
  /// Returns PreprocessedSignal with computed features.
  PreprocessedSignal process({
    required List<AudioFrame> window,
    required DetectionContext context,
  }) {
    // Concatenate all frame samples into single buffer
    final allSamples = <double>[];
    for (final frame in window) {
      allSamples.addAll(frame.samples);
    }

    if (allSamples.isEmpty) {
      return _emptySignal(context);
    }

    final rawSamples = Float32List.fromList(allSamples);
    final sampleRate = window.first.sampleRate;
    final duration = Duration(
      microseconds: (rawSamples.length * 1000000 / sampleRate).round(),
    );

    // Step 1: Estimate noise floor before normalization
    final noiseFloor = estimateNoiseFloor(rawSamples);

    // Step 2: RMS Normalization to -18 dBFS
    final normalized = normalizeRMS(rawSamples, targetDbFS: -18.0);

    // Step 3: Remove DC offset and bandpass filter (20-1500 Hz)
    final filtered = bandpassFilter(
      normalized,
      sampleRate,
      lowCutoff: 20.0,
      highCutoff: 1500.0,
    );

    // Step 4: Compute baseline and multi-band onset envelopes
    final baseOnset = energyOnsetEnvelope(
      filtered,
      sampleRate,
      frameSizeMs: 30.0,
      hopSizeMs: 10.0,
      smooth: true,
    );

    final multiBand = _computeMultiBandOnsets(
      samples: normalized,
      sampleRate: sampleRate,
      referenceLength: baseOnset.length,
    );

    final onset = multiBand != null
        ? _blendEnvelopes(
            primary: baseOnset,
            secondary: multiBand.combined,
            secondaryMix: 0.7, // ENHANCEMENT: Use multi-band onset (was 0.0)
          )
        : baseOnset;

    // Step 5: Create downsampled variants for efficiency
    final samples8kHz = _downsampleTo(filtered, sampleRate, targetRate: 8000);
    final samples400Hz = _downsampleTo(filtered, sampleRate, targetRate: 400);

    // Step 6: Compute mel-spectrum (perceptual emphasis)
    final melFeatures = computeMelSpectrogram(
      filtered,
      sampleRate: sampleRate,
      fftSize: 1024,
      hopSize: 512,
      melBands: 40,
      minFrequency: 20,
      maxFrequency: math.min(5000, sampleRate / 2),
    );

    // Step 7: Compute spectral-flux novelty curve (bandwise)
    final novelty = _noveltyComputer.compute(
      frames: window,
      context: context,
    );

    TempogramResult? tempogram;
    if (novelty.curve.isNotEmpty && novelty.featureRate > 0) {
      tempogram = _tempogramComputer.compute(
        noveltyCurve: novelty.curve,
        featureRate: novelty.featureRate,
        minBpm: context.minBpm,
        maxBpm: context.maxBpm,
      );
    }

    return PreprocessedSignal(
      rawSamples: rawSamples,
      normalizedSamples: normalized,
      filteredSamples: filtered,
      onsetEnvelope: onset,
      multiBandOnsetEnvelopes: multiBand?.bands ?? const [],
      samples8kHz: samples8kHz,
      samples400Hz: samples400Hz,
      melSpectrogram: melFeatures.frames,
      melBandMeans: melFeatures.meanBands,
      noveltyCurve: novelty.curve,
      noveltyFeatureRate: novelty.featureRate,
      tempogram: tempogram?.matrix ?? const [],
      tempoAxis: tempogram?.tempoAxis ?? Float32List(0),
      tempogramTimes: tempogram?.times ?? Float32List(0),
      dominantTempoCurve: tempogram?.dominantTempo ?? Float32List(0),
      dominantTempoStrength: tempogram?.dominantStrength ?? Float32List(0),
      originalSampleRate: sampleRate,
      duration: duration,
      context: context,
      noiseFloor: noiseFloor,
    );
  }

  /// Downsamples signal to target sample rate.
  Float32List _downsampleTo(
    Float32List samples,
    int currentRate, {
    required int targetRate,
  }) {
    if (currentRate <= targetRate) {
      return samples;
    }

    final factor = (currentRate / targetRate).round();
    final downsampled = SignalUtils.downsample(
      List<double>.from(samples),
      factor,
    );

    return Float32List.fromList(downsampled);
  }

  _MultiBandOnsetResult? _computeMultiBandOnsets({
    required Float32List samples,
    required int sampleRate,
    required int referenceLength,
  }) {
    if (samples.isEmpty || sampleRate <= 0) {
      return null;
    }

    final nyquist = sampleRate * 0.5;
    final bands = <BandOnsetEnvelope>[];
    Float32List? aggregate;
    double weightSum = 0.0;

    for (final config in _onsetBandConfigs) {
      final highCut = math.min(config.highCutoff, nyquist - 20.0);
      if (highCut <= config.lowCutoff + 5.0) {
        continue;
      }

      final bandFiltered = bandpassFilter(
        samples,
        sampleRate,
        lowCutoff: config.lowCutoff,
        highCutoff: highCut,
      );
      if (bandFiltered.isEmpty) {
        continue;
      }

      final envelope = energyOnsetEnvelope(
        bandFiltered,
        sampleRate,
        frameSizeMs: config.frameSizeMs,
        hopSizeMs: config.hopSizeMs,
        smooth: true,
      );
      if (envelope.isEmpty) {
        continue;
      }

      var normalized = _normalizeEnvelope(envelope);
      if (normalized.isEmpty) {
        continue;
      }

      bands.add(
        BandOnsetEnvelope(
          label: config.label,
          lowCutoff: config.lowCutoff,
          highCutoff: highCut,
          weight: config.weight,
          envelope: normalized,
        ),
      );

      if (referenceLength > 0 && normalized.length != referenceLength) {
        normalized = _resizeEnvelope(normalized, referenceLength);
      }

      aggregate ??= Float32List(normalized.length);
      final length = math.min(aggregate.length, normalized.length);
      for (var i = 0; i < length; i++) {
        aggregate[i] += normalized[i] * config.weight;
      }
      weightSum += config.weight;
    }

    if (bands.isEmpty || aggregate == null || aggregate.isEmpty) {
      return null;
    }

    if (weightSum > 0) {
      for (var i = 0; i < aggregate.length; i++) {
        aggregate[i] /= weightSum;
      }
    }

    Float32List aggregateResized = aggregate;
    if (referenceLength > 0 && aggregate.length != referenceLength) {
      aggregateResized = _resizeEnvelope(aggregate, referenceLength);
    }

    final normalizedAggregate = _normalizeEnvelope(aggregateResized);
    if (normalizedAggregate.isEmpty) {
      return null;
    }

    final smoothed = exponentialSmooth(normalizedAggregate, alpha: 0.18);

    return _MultiBandOnsetResult(
      bands: bands,
      combined: smoothed,
    );
  }

  Float32List _normalizeEnvelope(Float32List envelope) {
    if (envelope.isEmpty) {
      return Float32List(0);
    }

    var maxValue = 0.0;
    for (final value in envelope) {
      if (value > maxValue) {
        maxValue = value;
      }
    }

    if (maxValue <= 1e-9) {
      return Float32List(envelope.length);
    }

    final normalized = Float32List(envelope.length);
    for (var i = 0; i < envelope.length; i++) {
      normalized[i] = (envelope[i] / maxValue).clamp(0.0, 1.0);
    }

    return normalized;
  }

  Float32List _resizeEnvelope(Float32List envelope, int targetLength) {
    if (targetLength <= 0) {
      return Float32List(0);
    }
    if (envelope.length == targetLength) {
      return envelope;
    }

    final resized = Float32List(targetLength);
    final ratio = envelope.length / targetLength;
    for (var i = 0; i < targetLength; i++) {
      final sourceIndex = (i * ratio).floor().clamp(0, envelope.length - 1);
      resized[i] = envelope[sourceIndex];
    }
    return resized;
  }

  Float32List _blendEnvelopes({
    required Float32List primary,
    required Float32List secondary,
    required double secondaryMix,
  }) {
    if (primary.isEmpty) {
      return Float32List(0);
    }

    final mix = secondaryMix.clamp(0.0, 1.0);
    if (mix <= 1e-6 || secondary.isEmpty) {
      return primary;
    }

    final primaryNorm = _normalizeEnvelope(primary);
    final secondaryNorm = _normalizeEnvelope(
      secondary.length == primaryNorm.length
          ? secondary
          : _resizeEnvelope(secondary, primaryNorm.length),
    );

    final blended = Float32List(primaryNorm.length);
    for (var i = 0; i < blended.length; i++) {
      blended[i] =
          ((1 - mix) * primaryNorm[i] + mix * secondaryNorm[i]).clamp(0.0, 1.0);
    }
    return blended;
  }

  /// Creates an empty preprocessed signal for edge cases.
  PreprocessedSignal _emptySignal(DetectionContext context) {
    final empty = Float32List(0);
    return PreprocessedSignal(
      rawSamples: empty,
      normalizedSamples: empty,
      filteredSamples: empty,
      onsetEnvelope: empty,
      samples8kHz: empty,
      samples400Hz: empty,
      melSpectrogram: const [],
      melBandMeans: Float32List(0),
      noveltyCurve: empty,
      noveltyFeatureRate: 0,
      tempogram: const [],
      tempoAxis: Float32List(0),
      tempogramTimes: Float32List(0),
      dominantTempoCurve: Float32List(0),
      dominantTempoStrength: Float32List(0),
      originalSampleRate: context.sampleRate,
      duration: Duration.zero,
      context: context,
      noiseFloor: 0.0,
      multiBandOnsetEnvelopes: const [],
    );
  }
}

/// Singleton instance for convenience.
const preprocessingPipeline = PreprocessingPipeline();

class _MultiBandOnsetResult {
  const _MultiBandOnsetResult({
    required this.bands,
    required this.combined,
  });

  final List<BandOnsetEnvelope> bands;
  final Float32List combined;
}

class _OnsetBandConfig {
  const _OnsetBandConfig({
    required this.label,
    required this.lowCutoff,
    required this.highCutoff,
    required this.weight,
    this.frameSizeMs = 30.0,
    this.hopSizeMs = 10.0,
  });

  final String label;
  final double lowCutoff;
  final double highCutoff;
  final double weight;
  final double frameSizeMs;
  final double hopSizeMs;
}
