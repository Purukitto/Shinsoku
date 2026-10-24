import 'package:flutter/material.dart';
import 'colors.dart';
import 'text_styles.dart';

abstract final class AppTheme {
  static ThemeData light(SAccent accent) => _build(SColors.light(accent), Brightness.light);

  static ThemeData dark(SAccent accent, {bool pureBlack = false}) =>
      _build(SColors.dark(accent, pureBlack: pureBlack), Brightness.dark);

  static ThemeData _build(SColors c, Brightness brightness) => ThemeData(
    brightness: brightness,
    scaffoldBackgroundColor: c.bg0,
    fontFamily: kFontUi,
    colorScheme: ColorScheme(
      brightness: brightness,
      surface: c.bg0,
      surfaceContainerHighest: c.bg3,
      primary: c.accentStart,
      onPrimary: c.accentInk,
      secondary: c.accent,
      onSecondary: c.accentInk,
      tertiary: c.accentEnd,
      error: c.danger,
      onError: c.bg0,
      onSurface: c.hi,
      outline: c.line,
    ),
    textTheme: ThemeData(brightness: brightness).textTheme
        .apply(fontFamily: kFontUi)
        .copyWith(
          bodyMedium: TextStyle(fontFamily: kFontUi, color: c.mid),
        ),
    dividerColor: c.line,
    dividerTheme: DividerThemeData(color: c.line, thickness: 1, space: 0),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStateProperty.all(c.bg4),
      radius: const Radius.circular(8),
      thickness: WidgetStateProperty.all(4),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.windows: FadeUpwardsPageTransitionsBuilder(),
        TargetPlatform.android: FadeUpwardsPageTransitionsBuilder(),
        TargetPlatform.linux: FadeUpwardsPageTransitionsBuilder(),
      },
    ),
    extensions: [c],
  );
}
