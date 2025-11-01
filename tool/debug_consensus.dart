import 'package:bpm/src/core/robust_consensus_engine.dart';
import 'package:bpm/src/models/bpm_models.dart';

void main() {
  _runScenario(
    '3 fundamentals vs 1 subharmonic',
    [
      _reading('simple_onset', 155),
      _reading('autocorrelation', 155),
      _reading('fft_spectrum', 155),
      _reading('wavelet_energy', 50),
    ],
  );

  _runScenario(
    '2 fundamentals vs 2 subharmonics',
    [
      _reading('simple_onset', 155),
      _reading('fft_spectrum', 155),
      _reading('autocorrelation', 51.6),
      _reading('wavelet_energy', 48.9),
    ],
  );

  _runScenario(
    '1 fundamental vs 3 subharmonics',
    [
      _reading('simple_onset', 155),
      _reading('fft_spectrum', 51.4),
      _reading('autocorrelation', 49.3),
      _reading('wavelet_energy', 52.1),
    ],
  );
}

void _runScenario(String title, List<BpmReading> readings) {
  final engine = RobustConsensusEngine();
  engine.reset();
  final result = engine.combine(readings);
  print('--- $title ---');
  print('Consensus BPM: ${result?.bpm}, confidence: ${result?.confidence}');
  if (result != null) {
    for (final entry in result.weights.entries) {
      print('  ${entry.key}: ${entry.value.toStringAsFixed(3)}');
    }
  }
}

BpmReading _reading(String id, double bpm) {
  return BpmReading(
    algorithmId: id,
    algorithmName: id,
    bpm: bpm,
    confidence: 0.6,
    timestamp: DateTime.now().toUtc(),
  );
}
