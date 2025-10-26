import 'package:bpm/src/models/bpm_models.dart';
import 'package:bpm/src/state/bpm_cubit.dart';
import 'package:bpm/src/state/bpm_state.dart';
import 'package:bpm/src/ui/widgets/algorithm_readings_list.dart';
import 'package:bpm/src/ui/widgets/audio_oscilloscope.dart';
import 'package:bpm/src/ui/widgets/bpm_summary_card.dart';
import 'package:bpm/src/ui/widgets/bpm_trend_sparkline.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<BpmCubit, BpmState>(
      builder: (context, state) {
        return Scaffold(
          appBar: AppBar(
            title: const Text('Real-time BPM Detector'),
          ),
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: ListView(
              children: [
                AudioOscilloscope(
                  samples: state.previewSamples,
                  status: state.status,
                ),
                const SizedBox(height: 12),
                BpmSummaryCard(state: state),
                const SizedBox(height: 12),
                if (state.history.length >= 2) ...[
                  BpmTrendSparkline(history: state.history),
                  const SizedBox(height: 12),
                ],
                AlgorithmReadingsList(state: state),
                const SizedBox(height: 12),
                _StatusBanner(state: state),
              ],
            ),
          ),
          floatingActionButton: _DetectionFab(state: state),
        );
      },
    );
  }
}

class _DetectionFab extends StatelessWidget {
  const _DetectionFab({required this.state});

  final BpmState state;

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<BpmCubit>();
    final isActive = state.status != DetectionStatus.idle &&
        state.status != DetectionStatus.error;

    if (isActive) {
      return FloatingActionButton.extended(
        onPressed: cubit.stop,
        icon: const Icon(Icons.stop),
        label: const Text('Stop'),
        backgroundColor: Colors.redAccent,
      );
    }

    return FloatingActionButton.extended(
      onPressed: cubit.start,
      icon: const Icon(Icons.play_arrow),
      label: const Text('Start'),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.state});

  final BpmState state;

  @override
  Widget build(BuildContext context) {
    final color = switch (state.status) {
      DetectionStatus.error => Colors.red.shade100,
      DetectionStatus.streamingResults => Colors.green.shade100,
      DetectionStatus.analyzing => Colors.blue.shade100,
      _ => Colors.grey.shade200,
    };

    final text = state.message ??
        switch (state.status) {
          DetectionStatus.idle => 'Idle. Tap start to begin listening.',
          DetectionStatus.listening => 'Listening and buffering audio…',
          DetectionStatus.buffering => 'Buffering audio for analysis…',
          DetectionStatus.analyzing => 'Running algorithms…',
          DetectionStatus.streamingResults => 'Streaming live estimates.',
          DetectionStatus.error => 'Error encountered during processing.',
        };

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(text),
    );
  }
}
