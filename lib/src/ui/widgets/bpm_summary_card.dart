import 'package:bpm/src/state/bpm_state.dart';
import 'package:flutter/material.dart';

class BpmSummaryCard extends StatelessWidget {
  const BpmSummaryCard({super.key, required this.state});

  final BpmState state;

  @override
  Widget build(BuildContext context) {
    final consensus = state.consensus;
    final textTheme = Theme.of(context).textTheme;
    final previous = state.history.length >= 2
        ? state.history[state.history.length - 2]
        : null;
    final delta = previous != null && consensus != null
        ? consensus.bpm - previous.bpm
        : null;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
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
            if (previous != null && consensus != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Row(
                  children: [
                    Text(
                      'Previous ${previous.bpm.toStringAsFixed(1)} BPM',
                      style: textTheme.bodyMedium,
                    ),
                    const Spacer(),
                    if (delta != null)
                      Text(
                        delta >= 0
                            ? '+${delta.toStringAsFixed(1)}'
                            : delta.toStringAsFixed(1),
                        style: textTheme.bodyMedium?.copyWith(
                          color: delta >= 0
                              ? Colors.green.shade600
                              : Colors.red.shade400,
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
