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
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ..._algorithmRows(context),
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
                color: colorScheme.surfaceVariant,
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
                  const SizedBox(height: 4),
                  Text(
                    'Confidence ${(confidence * 100).toStringAsFixed(0)}%',
                    style: textTheme.bodySmall,
                  ),
                ],
              ),
            );
          },
        )
        .toList();
  }
}
