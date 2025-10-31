import 'dart:ui' show FontFeature;

import 'package:bpm/src/models/bpm_models.dart';
import 'package:bpm/src/state/bpm_cubit.dart';
import 'package:bpm/src/state/bpm_state.dart';
import 'package:bpm/src/ui/widgets/audio_oscilloscope.dart';
import 'package:bpm/src/ui/widgets/bpm_summary_card.dart';
import 'package:bpm/src/ui/widgets/bpm_trend_sparkline.dart';
import 'package:bpm/src/ui/widgets/app_console.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<BpmCubit, BpmState>(
      builder: (context, state) {
        return Scaffold(
          appBar: AppBar(
            centerTitle: false,
            title: const _TitleBar(),
          ),
          body: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.only(
                  left: 16,
                  right: 16,
                  top: 16,
                  bottom: 60, // Space for console
                ),
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
                    _StatusBanner(state: state),
                  ],
                ),
              ),
              // Console at bottom
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: const AppConsole(
                  initiallyExpanded: false,
                ),
              ),
            ],
          ),
          floatingActionButton: _DetectionFab(state: state),
        );
      },
    );
  }
}

class _TitleBar extends StatelessWidget {
  const _TitleBar();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.start,
      children: const [
        Expanded(
          child: Text(
            'Real-time BPM Detector',
            overflow: TextOverflow.ellipsis,
          ),
        ),
        SizedBox(width: 12),
        _ElapsedClock(),
      ],
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

class _ElapsedClock extends StatelessWidget {
  const _ElapsedClock();

  @override
  Widget build(BuildContext context) {
    return BlocSelector<BpmCubit, BpmState, _ClockViewModel>(
      selector: (state) => _ClockViewModel(
        elapsed: state.elapsed,
        isRunning: state.startedAt != null && state.status != DetectionStatus.idle,
      ),
      builder: (context, viewModel) {
        final minutes = viewModel.elapsed.inMinutes;
        final seconds = viewModel.elapsed.inSeconds.remainder(60);
        final safeMinutes = minutes.clamp(0, 999);
        final minuteText = safeMinutes is int
            ? safeMinutes.toString().padLeft(2, '0')
            : safeMinutes.round().toString().padLeft(2, '0');
        final text = '$minuteText:${seconds.toString().padLeft(2, '0')}';
        final theme = Theme.of(context);
        final baseStyle = theme.textTheme.titleMedium ??
            theme.textTheme.titleLarge ??
            const TextStyle(fontSize: 18);
        final color = viewModel.isRunning
            ? baseStyle.color
            : (theme.appBarTheme.foregroundColor ??
                theme.colorScheme.onPrimary.withOpacity(0.7));

        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: child,
          ),
          child: Text(
            text,
            key: ValueKey<String>(text),
            style: baseStyle.copyWith(
              color: color,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        );
      },
    );
  }
}

class _ClockViewModel extends Equatable {
  const _ClockViewModel({required this.elapsed, required this.isRunning});

  final Duration elapsed;
  final bool isRunning;

  @override
  List<Object?> get props => [elapsed.inSeconds, isRunning];
}
