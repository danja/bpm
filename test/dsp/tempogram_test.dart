import 'dart:math' as math;
import 'dart:typed_data';

import 'package:bpm/src/algorithms/detection_context.dart';
import 'package:bpm/src/dsp/novelty.dart';
import 'package:bpm/src/dsp/preprocessing_pipeline.dart';
import 'package:bpm/src/dsp/tempogram.dart';
import 'package:test/test.dart';

import '../support/signal_factory.dart';

void main() {
  group('TempogramComputer', () {
    test('produces tempogram for rhythmic audio', () {
      const sampleRate = 44100;
      final samples = SignalFactory.beatSignal(
        bpm: 120,
        sampleRate: sampleRate,
        duration: const Duration(seconds: 6),
      );
      final frames = SignalFactory.framesFromSamples(
        samples,
        sampleRate: sampleRate,
      );
      final context = const DetectionContext(
        sampleRate: sampleRate,
        minBpm: 60,
        maxBpm: 200,
        windowDuration: Duration(seconds: 6),
      );

      const pipeline = PreprocessingPipeline();
      final signal = pipeline.process(window: frames, context: context);

      expect(signal.tempogram.isNotEmpty, isTrue);
      expect(signal.dominantTempoCurve.length, signal.tempogram.length);

      final dominant = signal.dominantTempoCurve.isNotEmpty
          ? signal.dominantTempoCurve.reduce((a, b) => a + b) /
              signal.dominantTempoCurve.length
          : 0.0;
      expect(dominant, inInclusiveRange(80, 140));
    });

    test('handles empty novelty curve gracefully', () {
      const computer = TempogramComputer();
      final result = computer.compute(noveltyCurve: Float32List(0), featureRate: 0);
      expect(result.matrix, isEmpty);
      expect(result.tempoAxis.length, 0);
      expect(result.times.length, 0);
      expect(result.dominantTempo.length, 0);
    });

    test('window and hop respect feature rate bounds', () {
      final curve = Float32List.fromList(List<double>.generate(100, (i) => math.sin(i / 5)));
      const computer = TempogramComputer();
      final result = computer.compute(
        noveltyCurve: curve,
        featureRate: 10,
        minBpm: 80,
        maxBpm: 160,
      );

      expect(result.tempoAxis.every((bpm) => bpm >= 80 && bpm <= 160), isTrue);
    });
  });
}
