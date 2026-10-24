import 'package:flutter/material.dart';

/// An accent the app can wear: the gradient it fills with, the colour drawn on
/// that fill, and the hues taken from it for text and icons. Light surfaces need
/// those hues deeper than dark ones do.
@immutable
class SAccent {
  const SAccent({
    required this.id,
    required this.name,
    required this.fill,
    required this.ink,
    required this.onDark,
    required this.onLight,
  });

  final String id; // what settings store
  final String name;

  /// Gradient stops: start, middle, end.
  final List<Color> fill;

  /// Text and icons drawn on [fill].
  final Color ink;

  /// Start, middle and end hues for text and icons on dark and on light surfaces.
  final List<Color> onDark;
  final List<Color> onLight;

  /// The "voltage" lightning gradient: violet → magenta → amber.
  static const volt = SAccent(
    id: 'volt',
    name: 'Volt',
    fill: [Color(0xFFA25CFF), Color(0xFFFF63B6), Color(0xFFFFCE4D)],
    ink: Color(0xFF1B1020),
    onDark: [Color(0xFFB079FF), Color(0xFFFF77C0), Color(0xFFFFCE4D)],
    onLight: [Color(0xFF7B3FE0), Color(0xFFC72C80), Color(0xFF9A6400)],
  );

  static const all = [volt];

  static SAccent byId(String id) => all.firstWhere((a) => a.id == id, orElse: () => volt);
}

/// The app's colours for one brightness and accent. [AppTheme] installs it as a
/// theme extension and widgets read it with `context.colors`, so switching theme
/// or accent rebuilds whatever reads it.
@immutable
class SColors extends ThemeExtension<SColors> {
  const SColors({
    required this.bg0,
    required this.bg1,
    required this.bg2,
    required this.bg3,
    required this.bg4,
    required this.line,
    required this.lineHi,
    required this.hi,
    required this.mid,
    required this.low,
    required this.faint,
    required this.amber,
    required this.mint,
    required this.danger,
    required this.accentStart,
    required this.accent,
    required this.accentEnd,
    required this.accentInk,
    required this.accentFill,
  });

  /// Warm near-black monochrome.
  factory SColors.dark(SAccent a, {bool pureBlack = false}) => SColors(
    bg0: pureBlack ? const Color(0xFF000000) : const Color(0xFF141317),
    bg1: pureBlack ? const Color(0xFF0C0B0E) : const Color(0xFF1A191E),
    bg2: pureBlack ? const Color(0xFF141317) : const Color(0xFF201E25),
    bg3: pureBlack ? const Color(0xFF1E1D22) : const Color(0xFF28262E),
    bg4: pureBlack ? const Color(0xFF2A2830) : const Color(0xFF322F39),
    line: pureBlack ? const Color(0xFF1F1E23) : const Color(0xFF2C2A32),
    lineHi: pureBlack ? const Color(0xFF2E2C34) : const Color(0xFF3A3742),
    hi: const Color(0xFFF3F1F7),
    mid: const Color(0xFF9D99A6),
    low: const Color(0xFF6A6672),
    faint: const Color(0xFF48454F),
    amber: const Color(0xFFFFC24D),
    mint: const Color(0xFF7FE0B0),
    danger: const Color(0xFFFF7A6B),
    accentStart: a.onDark[0],
    accent: a.onDark[1],
    accentEnd: a.onDark[2],
    accentInk: a.ink,
    accentFill: a.fill,
  );

  /// Warm off-white: grey page, white panels, darker greys for what's raised or
  /// pressed into it.
  factory SColors.light(SAccent a) => SColors(
    bg0: const Color(0xFFF3F2F6),
    bg1: const Color(0xFFFFFFFF),
    bg2: const Color(0xFFF8F7FA),
    bg3: const Color(0xFFECEAF0),
    bg4: const Color(0xFFDCD9E2),
    line: const Color(0xFFE4E2E8),
    lineHi: const Color(0xFFD5D2DB),
    hi: const Color(0xFF18161C),
    mid: const Color(0xFF5E5A67),
    low: const Color(0xFF878390),
    faint: const Color(0xFFB4B0BC),
    amber: const Color(0xFFA86A00),
    mint: const Color(0xFF178A55),
    danger: const Color(0xFFD93D2E),
    accentStart: a.onLight[0],
    accent: a.onLight[1],
    accentEnd: a.onLight[2],
    accentInk: a.ink,
    accentFill: a.fill,
  );

  // surfaces: page, panels, hover, selected, tracks
  final Color bg0;
  final Color bg1;
  final Color bg2;
  final Color bg3;
  final Color bg4;

  // hairlines
  final Color line;
  final Color lineHi;

  // text hierarchy
  final Color hi;
  final Color mid;
  final Color low;
  final Color faint;

  // semantic
  final Color amber;
  final Color mint;
  final Color danger;

  // accent hues for text and icons; [accent] is the main one
  final Color accentStart;
  final Color accent;
  final Color accentEnd;

  /// Text and icons drawn on [accentGradient].
  final Color accentInk;

  /// Gradient stops: start, middle, end.
  final List<Color> accentFill;

  static const _gradientRotation = GradientRotation(118 * 3.14159 / 180);

  LinearGradient get accentGradient => LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    transform: _gradientRotation,
    colors: accentFill,
    stops: const [0.0, 0.46, 1.0],
  );

  LinearGradient get accentSoftGradient => LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    transform: _gradientRotation,
    colors: [
      accentFill[0].withValues(alpha: 0.16),
      accentFill[1].withValues(alpha: 0.14),
      accentFill[2].withValues(alpha: 0.16),
    ],
    stops: const [0.0, 0.5, 1.0],
  );

  @override
  SColors copyWith({
    Color? bg0,
    Color? bg1,
    Color? bg2,
    Color? bg3,
    Color? bg4,
    Color? line,
    Color? lineHi,
    Color? hi,
    Color? mid,
    Color? low,
    Color? faint,
    Color? amber,
    Color? mint,
    Color? danger,
    Color? accentStart,
    Color? accent,
    Color? accentEnd,
    Color? accentInk,
    List<Color>? accentFill,
  }) => SColors(
    bg0: bg0 ?? this.bg0,
    bg1: bg1 ?? this.bg1,
    bg2: bg2 ?? this.bg2,
    bg3: bg3 ?? this.bg3,
    bg4: bg4 ?? this.bg4,
    line: line ?? this.line,
    lineHi: lineHi ?? this.lineHi,
    hi: hi ?? this.hi,
    mid: mid ?? this.mid,
    low: low ?? this.low,
    faint: faint ?? this.faint,
    amber: amber ?? this.amber,
    mint: mint ?? this.mint,
    danger: danger ?? this.danger,
    accentStart: accentStart ?? this.accentStart,
    accent: accent ?? this.accent,
    accentEnd: accentEnd ?? this.accentEnd,
    accentInk: accentInk ?? this.accentInk,
    accentFill: accentFill ?? this.accentFill,
  );

  // Blends every colour, so a theme switch fades instead of jumping.
  @override
  SColors lerp(SColors? other, double t) {
    if (other == null) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return SColors(
      bg0: l(bg0, other.bg0),
      bg1: l(bg1, other.bg1),
      bg2: l(bg2, other.bg2),
      bg3: l(bg3, other.bg3),
      bg4: l(bg4, other.bg4),
      line: l(line, other.line),
      lineHi: l(lineHi, other.lineHi),
      hi: l(hi, other.hi),
      mid: l(mid, other.mid),
      low: l(low, other.low),
      faint: l(faint, other.faint),
      amber: l(amber, other.amber),
      mint: l(mint, other.mint),
      danger: l(danger, other.danger),
      accentStart: l(accentStart, other.accentStart),
      accent: l(accent, other.accent),
      accentEnd: l(accentEnd, other.accentEnd),
      accentInk: l(accentInk, other.accentInk),
      accentFill: [for (var i = 0; i < 3; i++) l(accentFill[i], other.accentFill[i])],
    );
  }
}

extension SColorsOf on BuildContext {
  /// The palette of the nearest theme; the default dark one outside a themed tree.
  SColors get colors => Theme.of(this).extension<SColors>() ?? _fallback;
}

final _fallback = SColors.dark(SAccent.volt);
