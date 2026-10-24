import 'package:flutter/material.dart';
import '../../theme/colors.dart';
import '../../theme/text_styles.dart';

enum PillTone { defaultTone, volt, amber, mint }

class Pill extends StatelessWidget {
  const Pill({super.key, required this.child, this.tone = PillTone.defaultTone});

  final Widget child;
  final PillTone tone;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final (bg, fg, border) = switch (tone) {
      PillTone.volt => (
        c.accent.withValues(alpha: 0.12),
        c.accent,
        c.accent.withValues(alpha: 0.25),
      ),
      PillTone.amber => (c.amber.withValues(alpha: 0.12), c.amber, c.amber.withValues(alpha: 0.22)),
      PillTone.mint => (c.mint.withValues(alpha: 0.12), c.mint, c.mint.withValues(alpha: 0.22)),
      _ => (c.bg3, c.mid, c.line),
    };
    return Container(
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: 9),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: border, width: 1),
      ),
      child: DefaultTextStyle(
        style: c.text.monoSm(color: fg).copyWith(fontSize: 11, letterSpacing: 0.02 * 11),
        child: Row(mainAxisSize: MainAxisSize.min, children: [child]),
      ),
    );
  }
}
