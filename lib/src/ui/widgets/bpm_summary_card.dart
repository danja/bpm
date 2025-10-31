import 'package:bpm/src/models/bpm_models.dart';
import 'package:bpm/src/state/bpm_state.dart';
import 'package:flutter/material.dart';

class BpmSummaryCard extends StatelessWidget {
  const BpmSummaryCard({super.key, required this.state});

  final BpmState state;

  @override
  Widget build(BuildContext context) {
    final consensus = state.consensus;
    final textTheme = Theme.of(context).textTheme;
    final plpPanel = state.plpBpm != null
        ? _PlpPanel(
            bpm: state.plpBpm!,
            strength: state.plpStrength,
            trace: state.plpTrace,
          )
        : null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ..._algorithmRows(context),
            if (plpPanel != null) ...[
              const SizedBox(height: 8),
              plpPanel,
            ],
            const Divider(height: 20),
            Text('Consensus BPM', style: textTheme.titleMedium),
            const SizedBox(height: 4),
            if (consensus == null)
              Text(
                state.status == DetectionStatus.listening
                    ? 'Listening...'
                    : 'No reading yet',
                style: textTheme.bodyMedium,
              )
            else
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    consensus.bpm.toStringAsFixed(1),
                    style: textTheme.displayMedium,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'BPM',
                    style: textTheme.titleMedium,
                  ),
                ],
              ),
            if (consensus != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: LinearProgressIndicator(
                  value: consensus.confidence,
                  minHeight: 6,
                ),
              ),
          ],
        ),
      ),
    );
  }

  List<Widget> _algorithmRows(BuildContext context) {
    const algorithms = [
      ('simple_onset', 'Onset Energy'),
      ('autocorrelation', 'Autocorrelation'),
      ('fft_spectrum', 'FFT Spectrum'),
      ('wavelet_energy', 'Wavelet Energy'),
    ];

    final readingById = {
      for (final reading in state.readings) reading.algorithmId: reading
    };

    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;

    return algorithms
        .map(
          (entry) {
            final reading = readingById[entry.$1];
            final bpmText = reading != null
                ? '${reading.bpm.toStringAsFixed(1)} BPM'
                : '— BPM';
            final confidence = reading?.confidence ?? 0;

            return Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          entry.$2,
                          style: textTheme.titleSmall,
                        ),
                      ),
                      Text(
                        bpmText,
                        style: textTheme.titleMedium,
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  LinearProgressIndicator(
                    value: confidence.clamp(0.0, 1.0),
                    minHeight: 4,
                  ),
                ],
              ),
            );
          },
        )
        .toList();
  }
}

class _PlpPanel extends StatelessWidget {
  const _PlpPanel({
    required this.bpm,
    this.strength,
    required this.trace,
  });

  final double bpm;
  final double? strength;
  final List<double> trace;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final recent = trace.isNotEmpty ? trace[trace.length - 1] : null;
    final sampleCount = trace.length;
    final startIndex = sampleCount > 20 ? sampleCount - 20 : 0;
    double? minValue;
    double? maxValue;
    for (var i = startIndex; i < sampleCount; i++) {
      final value = trace[i];
      minValue = minValue == null ? value : value < minValue ? value : minValue;
      maxValue = maxValue == null ? value : value > maxValue ? value : maxValue;
    }
    final strengthPercent = strength == null
        ? null
        : (strength!.clamp(0.0, 1.0) * 100).toStringAsFixed(0);

    String rangeText;
    if (minValue != null && maxValue != null && (maxValue - minValue) > 0.1) {
      rangeText =
          'Range ≈ ${minValue.toStringAsFixed(0)} – ${maxValue.toStringAsFixed(0)} BPM';
    } else {
      rangeText = 'Stable at ${recent?.toStringAsFixed(1) ?? bpm.toStringAsFixed(1)} BPM';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Predominant Pulse (PLP)',
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.onSecondaryContainer,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                bpm.toStringAsFixed(1),
                style: theme.textTheme.headlineMedium?.copyWith(
                  color: theme.colorScheme.onSecondaryContainer,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                'BPM',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.onSecondaryContainer,
                ),
              ),
              if (strengthPercent != null) ...[
                const SizedBox(width: 12),
                Text(
                  'Strength $strengthPercent%',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSecondaryContainer,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),
          Text(
            rangeText,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSecondaryContainer.withOpacity(0.8),
            ),
          ),
        ],
      ),
    );
  }
}
