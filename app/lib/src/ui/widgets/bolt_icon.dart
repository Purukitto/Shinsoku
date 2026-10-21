import 'package:flutter/material.dart';
import '../../theme/colors.dart';

class BoltIcon extends StatelessWidget {
  const BoltIcon({super.key, this.size = 16, this.dim = false});

  final double size;
  final bool dim;

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (bounds) => SColors.voltGradient.createShader(bounds),
      child: Opacity(
        opacity: dim ? 0.5 : 1.0,
        child: CustomPaint(size: Size(size, size), painter: _BoltPainter()),
      ),
    );
  }
}

class _BoltPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;
    final path = Path()
      ..moveTo(size.width * 0.54, 0)
      ..lineTo(size.width * 0.17, size.height * 0.56)
      ..lineTo(size.width * 0.43, size.height * 0.56)
      ..lineTo(size.width * 0.30, size.height)
      ..lineTo(size.width * 0.83, size.height * 0.38)
      ..lineTo(size.width * 0.56, size.height * 0.38)
      ..lineTo(size.width * 0.68, 0)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_) => false;
}
