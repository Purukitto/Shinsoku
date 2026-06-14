import 'package:flutter/material.dart';
import '../../theme/colors.dart';
import '../../theme/text_styles.dart';

enum PillTone { defaultTone, volt, amber, mint }

class Pill extends StatelessWidget {
  const Pill({
    super.key,
    required this.child,
    this.tone = PillTone.defaultTone,
  });

  final Widget child;
  final PillTone tone;

  @override
  Widget build(BuildContext context) {
    final (bg, fg, border) = switch (tone) {
      PillTone.volt   => (const Color(0x1FFF63B6), SColors.voltPink, const Color(0x40FF63B6)),
      PillTone.amber  => (const Color(0x1FFFC24D), SColors.amber,    const Color(0x38FFC24D)),
      PillTone.mint   => (const Color(0x1F7FE0B0), SColors.mint,     const Color(0x387FE0B0)),
      _               => (SColors.bg3,              SColors.mid,      SColors.line),
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
        style: SText.monoSm(color: fg).copyWith(fontSize: 11, letterSpacing: 0.02 * 11),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [child],
        ),
      ),
    );
  }
}
