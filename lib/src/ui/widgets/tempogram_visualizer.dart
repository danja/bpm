import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:bpm/src/models/bpm_models.dart';
import 'package:flutter/material.dart';

/// Tempogram visualization showing tempo over time as a heatmap
/// with the predominant pulse (PLP) trace overlaid.
class TempogramVisualizer extends StatelessWidget {
  const TempogramVisualizer({
    super.key,
    required this.tempogram,
    required this.status,
    this.height = 200,
  });

  final TempogramSnapshot? tempogram;
  final String status;
  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    // Show placeholder when no tempogram data
    if (tempogram == null || tempogram!.isEmpty) {
      return Container(
        height: height,
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: colorScheme.outline.withOpacity(0.2),
            width: 1,
          ),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.graphic_eq,
                size: 48,
                color: colorScheme.onSurfaceVariant.withOpacity(0.3),
              ),
              const SizedBox(height: 8),
              Text(
                status == 'idle'
                    ? 'Tempogram (tap start)'
                    : 'Waiting for data...',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant.withOpacity(0.6),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      height: height,
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: colorScheme.outline.withOpacity(0.2),
          width: 1,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest,
                border: Border(
                  bottom: BorderSide(
                    color: colorScheme.outline.withOpacity(0.2),
                    width: 1,
                  ),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.graphic_eq,
                    size: 16,
                    color: colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Tempogram',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: colorScheme.onSurface,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  if (tempogram!.latestTempo != null)
                    Text(
                      'PLP: ${tempogram!.latestTempo!.toStringAsFixed(1)} BPM',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                ],
              ),
            ),
            // Visualization
            Expanded(
              child: CustomPaint(
                painter: _TempogramPainter(
                  tempogram: tempogram!,
                  colorScheme: colorScheme,
                ),
                child: Container(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TempogramPainter extends CustomPainter {
  _TempogramPainter({
    required this.tempogram,
    required this.colorScheme,
  });

  final TempogramSnapshot tempogram;
  final ColorScheme colorScheme;

  @override
  void paint(Canvas canvas, Size size) {
    if (tempogram.isEmpty) return;

    final matrix = tempogram.matrix;
    final tempoAxis = tempogram.tempoAxis;
    final times = tempogram.times;
    final dominantTempo = tempogram.dominantTempo;

    if (matrix.isEmpty || tempoAxis.isEmpty || times.isEmpty) return;

    final width = size.width;
    final height = size.height;

    // Reserve space for axes
    const leftMargin = 40.0;
    const rightMargin = 10.0;
    const topMargin = 10.0;
    const bottomMargin = 25.0;

    final plotWidth = width - leftMargin - rightMargin;
    final plotHeight = height - topMargin - bottomMargin;

    // Find data ranges
    final minTempo = tempoAxis.reduce(math.min);
    final maxTempo = tempoAxis.reduce(math.max);
    final minTime = times.reduce(math.min);
    final maxTime = times.reduce(math.max);

    // Find max intensity for normalization
    double maxIntensity = 0.0;
    for (final row in matrix) {
      for (final val in row) {
        if (val.isFinite && val > maxIntensity) {
          maxIntensity = val;
        }
      }
    }
    if (maxIntensity == 0) maxIntensity = 1.0;

    // Draw heatmap
    final timeCount = times.length;
    final tempoCount = tempoAxis.length;

    if (timeCount > 0 && tempoCount > 0) {
      final cellWidth = plotWidth / timeCount;
      final cellHeight = plotHeight / tempoCount;

      for (var ti = 0; ti < timeCount && ti < matrix.length; ti++) {
        final row = matrix[ti];
        for (var fi = 0; fi < tempoCount && fi < row.length; fi++) {
          final intensity = row[fi] / maxIntensity;
          if (!intensity.isFinite || intensity <= 0) continue;

          final x = leftMargin + ti * cellWidth;
          final y = topMargin + (tempoCount - 1 - fi) * cellHeight;

          final paint = Paint()
            ..color = _intensityToColor(intensity.clamp(0.0, 1.0))
            ..style = PaintingStyle.fill;

          canvas.drawRect(
            Rect.fromLTWH(x, y, cellWidth.ceilToDouble(), cellHeight.ceilToDouble()),
            paint,
          );
        }
      }
    }

    // Draw PLP trace
    if (dominantTempo.isNotEmpty && dominantTempo.length == times.length) {
      final path = Path();
      bool started = false;

      for (var i = 0; i < dominantTempo.length; i++) {
        final tempo = dominantTempo[i];
        if (!tempo.isFinite || tempo < minTempo || tempo > maxTempo) continue;

        final x = leftMargin + (i / (timeCount - 1)) * plotWidth;
        final y = topMargin + plotHeight - ((tempo - minTempo) / (maxTempo - minTempo)) * plotHeight;

        if (!started) {
          path.moveTo(x, y);
          started = true;
        } else {
          path.lineTo(x, y);
        }
      }

      final tracePaint = Paint()
        ..color = colorScheme.primary
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;

      canvas.drawPath(path, tracePaint);
    }

    // Draw axes
    _drawAxes(canvas, size, leftMargin, rightMargin, topMargin, bottomMargin,
        minTempo, maxTempo, minTime, maxTime);
  }

  void _drawAxes(
    Canvas canvas,
    Size size,
    double leftMargin,
    double rightMargin,
    double topMargin,
    double bottomMargin,
    double minTempo,
    double maxTempo,
    double minTime,
    double maxTime,
  ) {
    final textStyle = TextStyle(
      color: colorScheme.onSurface.withOpacity(0.7),
      fontSize: 10,
      fontFeatures: const [ui.FontFeature.tabularFigures()],
    );

    final axisPaint = Paint()
      ..color = colorScheme.outline.withOpacity(0.3)
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;

    // Y-axis (tempo)
    canvas.drawLine(
      Offset(leftMargin, topMargin),
      Offset(leftMargin, size.height - bottomMargin),
      axisPaint,
    );

    // Y-axis labels (tempo)
    final tempoTicks = [minTempo, (minTempo + maxTempo) / 2, maxTempo];
    for (final tempo in tempoTicks) {
      final y = topMargin + (size.height - topMargin - bottomMargin) * (1 - (tempo - minTempo) / (maxTempo - minTempo));

      final textPainter = TextPainter(
        text: TextSpan(text: tempo.toStringAsFixed(0), style: textStyle),
        textDirection: TextDirection.ltr,
      )..layout();

      textPainter.paint(
        canvas,
        Offset(leftMargin - textPainter.width - 5, y - textPainter.height / 2),
      );

      // Grid line
      final gridPaint = Paint()
        ..color = colorScheme.outline.withOpacity(0.1)
        ..strokeWidth = 1;
      canvas.drawLine(
        Offset(leftMargin, y),
        Offset(size.width - rightMargin, y),
        gridPaint,
      );
    }

    // X-axis (time)
    canvas.drawLine(
      Offset(leftMargin, size.height - bottomMargin),
      Offset(size.width - rightMargin, size.height - bottomMargin),
      axisPaint,
    );

    // X-axis label
    final timeTextPainter = TextPainter(
      text: TextSpan(text: 'Time (s)', style: textStyle),
      textDirection: TextDirection.ltr,
    )..layout();

    timeTextPainter.paint(
      canvas,
      Offset(
        (size.width - timeTextPainter.width) / 2,
        size.height - bottomMargin + 5,
      ),
    );

    // Y-axis label
    canvas.save();
    canvas.translate(10, size.height / 2);
    canvas.rotate(-math.pi / 2);

    final tempoLabelPainter = TextPainter(
      text: TextSpan(text: 'Tempo (BPM)', style: textStyle),
      textDirection: TextDirection.ltr,
    )..layout();

    tempoLabelPainter.paint(
      canvas,
      Offset(-tempoLabelPainter.width / 2, 0),
    );

    canvas.restore();
  }

  Color _intensityToColor(double intensity) {
    // Use a perceptually uniform color scheme
    // Low intensity: dark blue -> High intensity: yellow/white
    final hue = 240 - (intensity * 60); // Blue (240) to cyan (180)
    final saturation = 1.0 - (intensity * 0.3); // Desaturate at high intensity
    final lightness = 0.2 + (intensity * 0.7); // Dark to bright

    return HSLColor.fromAHSL(1.0, hue, saturation, lightness).toColor();
  }

  @override
  bool shouldRepaint(_TempogramPainter oldDelegate) {
    return oldDelegate.tempogram != tempogram ||
        oldDelegate.colorScheme != colorScheme;
  }
}
