import 'package:bpm/src/models/bpm_models.dart';
import 'package:flutter/material.dart';

class AudioOscilloscope extends StatelessWidget {
  const AudioOscilloscope({
    super.key,
    required this.samples,
    required this.status,
  });

  final List<double> samples;
  final DetectionStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;
    final color = theme.colorScheme.primary;
    final hasSamples = samples.isNotEmpty;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Input Monitor', style: textTheme.titleMedium),
                const SizedBox(width: 8),
                _StatusChip(status: status),
              ],
            ),
            const SizedBox(height: 12),
            if (!hasSamples)
              Text(
                'Waiting for microphone samples…',
                style: textTheme.bodyMedium,
              )
            else
              SizedBox(
                height: 96,
                child: CustomPaint(
                  painter: _OscilloscopePainter(
                    samples: samples,
                    color: color,
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

class _OscilloscopePainter extends CustomPainter {
  _OscilloscopePainter({
    required this.samples,
    required this.color,
  });

  final List<double> samples;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (samples.isEmpty) return;
    final path = Path();
    final len = samples.length;
    final dx = size.width / (len - 1);
    for (var i = 0; i < len; i++) {
      final x = i * dx;
      final value = samples[i].clamp(-1.0, 1.0).toDouble();
      final normalized = (value + 1) / 2; // map [-1,1] -> [0,1]
      final y = size.height - (normalized * size.height);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _OscilloscopePainter oldDelegate) =>
      oldDelegate.samples != samples || oldDelegate.color != color;
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final DetectionStatus status;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    Color background;
    String label;
    switch (status) {
      case DetectionStatus.streamingResults:
        background = colorScheme.secondaryContainer;
        label = 'Streaming';
        break;
      case DetectionStatus.analyzing:
        background = colorScheme.tertiaryContainer;
        label = 'Analyzing';
        break;
      case DetectionStatus.buffering:
        background = colorScheme.primaryContainer;
        label = 'Buffering';
        break;
      case DetectionStatus.listening:
        background = colorScheme.surfaceContainerHighest;
        label = 'Listening';
        break;
      default:
        background = colorScheme.errorContainer;
        label = 'Idle';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall,
      ),
    );
  }
}
