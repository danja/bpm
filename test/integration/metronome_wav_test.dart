import 'package:bpm/src/algorithms/autocorrelation_algorithm.dart';
import 'package:bpm/src/algorithms/detection_context.dart';
import 'package:bpm/src/algorithms/fft_spectrum_algorithm.dart';
import 'package:bpm/src/algorithms/simple_onset_algorithm.dart';
import 'package:bpm/src/algorithms/wavelet_energy_algorithm.dart';
import 'package:bpm/src/core/robust_consensus_engine.dart';
import 'package:bpm/src/dsp/preprocessing_pipeline.dart';
import 'package:bpm/src/models/bpm_models.dart';
import 'package:test/test.dart';

import '../support/signal_factory.dart';
import '../support/wav_loader.dart';

void main() {
  const expectedBpm = 98.0;
  late WavData wavData;
  late DetectionContext detectionContext;
  late PreprocessedSignal signal;
  late List<AudioFrame> frames;

  setUpAll(() {
    wavData = loadPcm16Wav('data/metronome_98.wav');
    frames = SignalFactory.framesFromSamples(
      wavData.samples,
      sampleRate: wavData.sampleRate,
    );
    detectionContext = DetectionContext(
      sampleRate: wavData.sampleRate,
      minBpm: 70,
      maxBpm: 150,
      windowDuration: Duration(
        microseconds:
            (wavData.samples.length / wavData.sampleRate * 1000000).round(),
      ),
    );
    signal = const PreprocessingPipeline().process(
      window: frames,
      context: detectionContext,
    );
  });

  Future<void> expectMetronomeReading(
    Future<BpmReading?> readingFuture, {
    double tolerance = 2.0,
    double minConfidence = 0.2,
    String? label,
  }) async {
    final reading = await readingFuture;
    expect(reading, isNotNull, reason: '$label produced null reading');
    expect(
      (reading!.bpm - expectedBpm).abs(),
      lessThan(tolerance),
      reason: '$label bpm off by ${(reading.bpm - expectedBpm).abs()}',
    );
    expect(
      reading.confidence,
      greaterThan(minConfidence),
      reason: '$label confidence too low (${reading.confidence})',
    );
  }

  test('SimpleOnset matches metronome wav', () async {
    final algorithm = SimpleOnsetAlgorithm();
    await expectMetronomeReading(
      algorithm.analyze(signal: signal),
      label: 'SimpleOnset',
      tolerance: 2.5,
    );
  });

  test('Autocorrelation matches metronome wav', () async {
    final algorithm = AutocorrelationAlgorithm();
    await expectMetronomeReading(
      algorithm.analyze(signal: signal),
      label: 'Autocorrelation',
      tolerance: 2.5,
      minConfidence: 0.15,
    );
  });

  test('FFT spectrum matches metronome wav', () async {
    final algorithm = FftSpectrumAlgorithm();
    await expectMetronomeReading(
      algorithm.analyze(signal: signal),
      label: 'FFT spectrum',
      tolerance: 2.5,
      minConfidence: 0.15,
    );
  });

  test('Wavelet energy matches metronome wav', () async {
    final algorithm = WaveletEnergyAlgorithm(levels: 2);
    await expectMetronomeReading(
      algorithm.analyze(signal: signal),
      label: 'Wavelet energy',
      tolerance: 3.0,
      minConfidence: 0.1,
    );
  });

  test('Robust consensus matches metronome wav', () async {
    final algorithms = [
      SimpleOnsetAlgorithm(),
      AutocorrelationAlgorithm(),
      FftSpectrumAlgorithm(),
      WaveletEnergyAlgorithm(levels: 2),
    ];

    final readings = <BpmReading>[];
    for (final algorithm in algorithms) {
      final reading = await algorithm.analyze(signal: signal);
      if (reading != null) {
        readings.add(reading);
      }
    }

    expect(readings, isNotEmpty, reason: 'No algorithm produced a reading');

    final engine = RobustConsensusEngine();
    engine.reset();
    final result = engine.combine(readings);

    expect(result, isNotNull, reason: 'Consensus engine returned null');
    expect(
      (result!.bpm - expectedBpm).abs(),
      lessThan(2.5),
      reason: 'Consensus BPM off by ${(result.bpm - expectedBpm).abs()}',
    );
    expect(
      result.confidence,
      greaterThan(0.25),
      reason: 'Consensus confidence too low (${result.confidence})',
    );
  });
}
