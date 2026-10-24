import 'package:flutter/material.dart';
import '../../theme/colors.dart';

class VoltBar extends StatelessWidget {
  const VoltBar({super.key, required this.value, this.height = 6, this.dim = false});

  final double value; // 0.0–1.0
  final double height;
  final bool dim;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final pct = value.clamp(0.0, 1.0);
    // FractionallySizedBox sizes the fill from the parent width directly — no
    // LayoutBuilder pass. TweenAnimationBuilder keeps the fill animating smoothly.
    return SizedBox(
      height: height,
      width: double.infinity,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(height),
        child: Stack(
          children: [
            Positioned.fill(child: ColoredBox(color: c.bg3)),
            TweenAnimationBuilder<double>(
              duration: const Duration(milliseconds: 450),
              curve: Curves.easeInOut,
              tween: Tween<double>(end: pct),
              builder: (_, v, _) => Align(
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: v.clamp(0.0, 1.0),
                  heightFactor: 1.0,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: dim ? null : c.accentGradient,
                      color: dim ? c.bg4 : null,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
