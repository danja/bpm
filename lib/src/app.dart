import 'package:bpm/src/algorithms/algorithm_registry.dart';
import 'package:bpm/src/algorithms/autocorrelation_algorithm.dart';
import 'package:bpm/src/algorithms/detection_context.dart';
import 'package:bpm/src/algorithms/fft_spectrum_algorithm.dart';
import 'package:bpm/src/algorithms/simple_onset_algorithm.dart';
import 'package:bpm/src/algorithms/wavelet_energy_algorithm.dart';
import 'package:bpm/src/audio/audio_stream_source.dart';
import 'package:bpm/src/audio/record_audio_stream_source.dart';
import 'package:bpm/src/core/bpm_detector_coordinator.dart';
import 'package:bpm/src/core/consensus_engine.dart';
import 'package:bpm/src/repository/bpm_repository.dart';
import 'package:bpm/src/state/bpm_cubit.dart';
import 'package:bpm/src/ui/screens/home_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

class BpmApp extends StatelessWidget {
  const BpmApp({super.key});

  @override
  Widget build(BuildContext context) {
    final registry = AlgorithmRegistry(
      [
        SimpleOnsetAlgorithm(),
        AutocorrelationAlgorithm(),
        FftSpectrumAlgorithm(),
        WaveletEnergyAlgorithm(),
      ],
    );

    final audioSource = RecordAudioStreamSource();
    final coordinator = BpmDetectorCoordinator(
      audioSource: audioSource,
      registry: registry,
      consensusEngine: const ConsensusEngine(),
    );

    final repository = BpmRepository(
      coordinator: coordinator,
      streamConfig: const AudioStreamConfig(),
      context: const DetectionContext(
        sampleRate: 44100,
        minBpm: 50,
        maxBpm: 200,
        windowDuration: Duration(seconds: 10),
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
