import 'package:bpm/src/models/bpm_models.dart';
import 'package:flutter/material.dart';

class BpmTrendSparkline extends StatelessWidget {
  const BpmTrendSparkline({
    super.key,
    required this.history,
  });

  final List<BpmHistoryPoint> history;

  @override
  Widget build(BuildContext context) {
    if (history.length < 2) {
      return const SizedBox.shrink();
    }

    final color = Theme.of(context).colorScheme.primary;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Recent trend',
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 72,
              child: CustomPaint(
                painter: _SparklinePainter(
                  history: history,
                  lineColor: color,
                  fillColor: color.withOpacity(0.15),
                ),
                size: Size.infinite,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  _SparklinePainter({
    required this.history,
    required this.lineColor,
    required this.fillColor,
  });

  final List<BpmHistoryPoint> history;
  final Color lineColor;
  final Color fillColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (history.length < 2) return;
    final bpmValues = history.map((point) => point.bpm).toList();
    final minBpm = bpmValues.reduce((a, b) => a < b ? a : b);
    final maxBpm = bpmValues.reduce((a, b) => a > b ? a : b);
    final range = (maxBpm - minBpm).abs() < 0.001 ? 1 : (maxBpm - minBpm);

    final path = Path();
    final fillPath = Path();
    final dx = size.width / (history.length - 1);

    for (var i = 0; i < history.length; i++) {
      final bpm = history[i].bpm;
      final normalized = (bpm - minBpm) / range;
      final x = i * dx;
      final y = size.height - (normalized * size.height);

      if (i == 0) {
        path.moveTo(x, y);
        fillPath.moveTo(x, size.height);
        fillPath.lineTo(x, y);
      } else {
        path.lineTo(x, y);
        fillPath.lineTo(x, y);
      }
      if (i == history.length - 1) {
        fillPath.lineTo(x, size.height);
        fillPath.close();
      }
    }

    final fillPaint = Paint()
      ..color = fillColor
      ..style = PaintingStyle.fill;
    canvas.drawPath(fillPath, fillPaint);

    final linePaint = Paint()
      ..color = lineColor
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(path, linePaint);
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter oldDelegate) =>
      oldDelegate.history != history ||
      oldDelegate.lineColor != lineColor ||
      oldDelegate.fillColor != fillColor;
}
