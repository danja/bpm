import 'package:bpm/src/algorithms/algorithm_registry.dart';
import 'package:bpm/src/algorithms/autocorrelation_algorithm.dart';
import 'package:bpm/src/algorithms/bpm_detection_algorithm.dart';
import 'package:bpm/src/algorithms/detection_context.dart';
import 'package:bpm/src/algorithms/fft_spectrum_algorithm.dart';
import 'package:bpm/src/algorithms/simple_onset_algorithm.dart';
import 'package:bpm/src/algorithms/wavelet_energy_algorithm.dart';
import 'package:bpm/src/audio/audio_stream_source.dart';
import 'package:bpm/src/audio/record_audio_stream_source.dart';
import 'package:bpm/src/core/bpm_detector_coordinator.dart';
import 'package:bpm/src/core/robust_consensus_engine.dart';
import 'package:bpm/src/repository/bpm_repository.dart';
import 'package:bpm/src/state/bpm_cubit.dart';
import 'package:bpm/src/ui/screens/home_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

class BpmApp extends StatelessWidget {
  const BpmApp({super.key});

  @override
  Widget build(BuildContext context) {
    const enableAutocorrelation = true;
    const enableFftSpectrum = true;
    const enableWavelet = true;
    final algorithms = <BpmDetectionAlgorithm>[
      SimpleOnsetAlgorithm(), // Fast energy-based detection (now more sensitive)
    ];
    if (enableFftSpectrum) {
      algorithms.add(FftSpectrumAlgorithm());
    }
    if (enableAutocorrelation) {
      algorithms.add(AutocorrelationAlgorithm());
    }
    if (enableWavelet) {
      algorithms.add(WaveletEnergyAlgorithm(levels: 2)); // Optimized to 2 levels for speed
    }

    final registry = AlgorithmRegistry(algorithms);

    final audioSource = RecordAudioStreamSource();
    final coordinator = BpmDetectorCoordinator(
      audioSource: audioSource,
      registry: registry,
      consensusEngine: RobustConsensusEngine(
        historySize: 10, // Track last 10 readings per algorithm
        minReadingsForOutlierDetection: 3, // Need 3 readings before rejecting outliers
        algorithmOutlierThreshold: 8.0, // Reject if >8 BPM from algorithm's own median
        clusterTolerance: 3.0, // Algorithms within 3 BPM cluster together
        minClusterSize: 2, // Need 2+ algorithms agreeing
        smoothingFactor: 0.25, // Moderate smoothing
      ),
      bufferWindow:
          const Duration(seconds: 4), // Shorter window for faster updates
    );

    final repository = BpmRepository(
      coordinator: coordinator,
      streamConfig: const AudioStreamConfig(),
      context: const DetectionContext(
        sampleRate: 44100,
        minBpm: 50,
        maxBpm: 250,
        windowDuration: Duration(seconds: 6),
      ),
    );

    return RepositoryProvider.value(
      value: repository,
      child: BlocProvider(
        create: (_) => BpmCubit(repository),
        child: MaterialApp(
          title: 'BPM Detector',
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
            useMaterial3: true,
          ),
          home: const HomeScreen(),
        ),
      ),
    );
  }
}
