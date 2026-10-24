import 'package:flutter/material.dart';
import '../../theme/colors.dart';

class SpeedChart extends StatelessWidget {
  const SpeedChart({super.key, required this.data, this.strokeWidth = 2.0, this.showFill = true});

  final List<int> data;
  final double strokeWidth;
  final bool showFill;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (data.isEmpty) return const SizedBox.shrink();
    // Fill the space given; under loose constraints a bare CustomPaint is 0 wide.
    return CustomPaint(
      size: Size.infinite,
      painter: _SpeedPainter(data, strokeWidth, showFill, c.accentFill, c.accent),
    );
  }
}

class _SpeedPainter extends CustomPainter {
  const _SpeedPainter(this.data, this.strokeWidth, this.showFill, this.lineColors, this.areaColor);

  final List<int> data;
  final double strokeWidth;
  final bool showFill;
  final List<Color> lineColors;
  final Color areaColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (data.length < 2) return;
    final maxV = data.reduce((a, b) => a > b ? a : b).toDouble();
    if (maxV == 0) return;
    final n = data.length;

    Path linePath = Path();
    Path areaPath = Path();
    for (int i = 0; i < n; i++) {
      final x = (i / (n - 1)) * size.width;
      final y = size.height - (data[i] / maxV) * (size.height - strokeWidth) - strokeWidth / 2;
      if (i == 0) {
        linePath.moveTo(x, y);
        areaPath.moveTo(x, y);
      } else {
        linePath.lineTo(x, y);
        areaPath.lineTo(x, y);
      }
    }
    areaPath.lineTo(size.width, size.height);
    areaPath.lineTo(0, size.height);
    areaPath.close();

    if (showFill) {
      final fillPaint = Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [areaColor.withValues(alpha: 0.28), areaColor.withValues(alpha: 0)],
        ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));
      canvas.drawPath(areaPath, fillPaint);
    }

    final linePaint = Paint()
      ..shader = LinearGradient(
        colors: lineColors,
        stops: const [0.0, 0.5, 1.0],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height))
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    canvas.drawPath(linePath, linePaint);
  }

  @override
  bool shouldRepaint(_SpeedPainter old) =>
      old.data != data || old.areaColor != areaColor || old.lineColors != lineColors;
}
