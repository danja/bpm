import 'package:bpm/src/state/bpm_state.dart';
import 'package:flutter/material.dart';

class AlgorithmReadingsList extends StatelessWidget {
  const AlgorithmReadingsList({super.key, required this.state});

  final BpmState state;

  @override
  Widget build(BuildContext context) {
    final readings = state.readings;
    if (readings.isEmpty) {
      return const SizedBox.shrink();
    }

    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const ListTile(
            title: Text('Algorithm Breakdown'),
            subtitle: Text('Confidence-weighted BPM estimates'),
          ),
          const Divider(height: 0),
          ...readings.map(
            (reading) => ListTile(
              title: Text(reading.algorithmName),
              subtitle: Text(
                'Confidence ${(reading.confidence * 100).toStringAsFixed(0)}%',
              ),
              trailing: Text(
                reading.bpm.toStringAsFixed(1),
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
