import 'package:flutter/material.dart';
import '../../theme/colors.dart';
import '../../theme/text_styles.dart';

class ShinsokuLogo extends StatelessWidget {
  const ShinsokuLogo({super.key, this.size = 34, this.showWordmark = true, this.color});

  final double size;
  final bool showWordmark;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final wordColor = color ?? c.hi;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // kanji tile
        Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            gradient: c.accentGradient,
            borderRadius: BorderRadius.circular(size * 0.28),
            boxShadow: [
              BoxShadow(
                color: c.accentFill[0].withValues(alpha: 0.35),
                blurRadius: 16,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          alignment: Alignment.center,
          child: Text(
            '速',
            style: TextStyle(
              fontFamily: kFontUi,
              fontSize: size * 0.52,
              fontWeight: FontWeight.w600,
              color: c.accentInk,
              height: 1,
            ),
          ),
        ),
        if (showWordmark) ...[
          SizedBox(width: 11),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Shinsoku',
                style: TextStyle(
                  fontFamily: kFontUi,
                  fontSize: size * 0.5,
                  fontWeight: FontWeight.w600,
                  color: wordColor,
                  letterSpacing: -0.01 * size * 0.5,
                  height: 1,
                ),
              ),
              SizedBox(height: 3),
              Text(
                '神速 · GODSPEED',
                style: c.text
                    .monoXs(color: c.low)
                    .copyWith(fontSize: size * 0.235, letterSpacing: 0.18 * size * 0.235),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
