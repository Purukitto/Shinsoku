import 'package:flutter/material.dart';

abstract final class SColors {
  // surfaces — warm near-black premium monochrome
  static const bg0 = Color(0xFF141317);
  static const bg1 = Color(0xFF1A191E);
  static const bg2 = Color(0xFF201E25);
  static const bg3 = Color(0xFF28262E);
  static const bg4 = Color(0xFF322F39);

  // hairlines
  static const line = Color(0xFF2C2A32);
  static const lineHi = Color(0xFF3A3742);

  // text hierarchy
  static const hi = Color(0xFFF3F1F7);
  static const mid = Color(0xFF9D99A6);
  static const low = Color(0xFF6A6672);
  static const faint = Color(0xFF48454F);

  // the one accent — "voltage" lightning gradient violet → magenta → amber
  static const voltViolet = Color(0xFFB079FF);
  static const voltPink = Color(0xFFFF77C0);
  static const voltAmber = Color(0xFFFFCE4D);

  // semantic
  static const amber = Color(0xFFFFC24D);
  static const mint = Color(0xFF7FE0B0);
  static const danger = Color(0xFFFF7A6B);

  // gradients
  static const voltGradient = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    transform: GradientRotation(118 * 3.14159 / 180),
    colors: [Color(0xFFA25CFF), Color(0xFFFF63B6), Color(0xFFFFCE4D)],
    stops: [0.0, 0.46, 1.0],
  );

  static const voltSoftGradient = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    transform: GradientRotation(118 * 3.14159 / 180),
    colors: [
      Color(0x29A25CFF),
      Color(0x24FF63B6),
      Color(0x29FFCE4D),
    ],
    stops: [0.0, 0.5, 1.0],
  );

  static BoxDecoration voltBoxDecoration({BorderRadius? radius}) => BoxDecoration(
    gradient: voltGradient,
    borderRadius: radius,
  );

  static BoxDecoration voltSoftBoxDecoration({BorderRadius? radius}) => BoxDecoration(
    gradient: voltSoftGradient,
    borderRadius: radius,
  );
}
