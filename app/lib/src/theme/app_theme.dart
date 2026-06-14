import 'package:flutter/material.dart';
import 'colors.dart';
import 'text_styles.dart';

abstract final class AppTheme {
  static ThemeData get dark => ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: SColors.bg0,
    fontFamily: kFontUi,
    colorScheme: const ColorScheme.dark(
      surface: SColors.bg0,
      surfaceContainerHighest: SColors.bg3,
      primary: SColors.voltViolet,
      secondary: SColors.voltPink,
      tertiary: SColors.voltAmber,
      onSurface: SColors.hi,
      outline: SColors.line,
    ),
    textTheme: ThemeData.dark().textTheme.apply(fontFamily: kFontUi).copyWith(
      bodyMedium: const TextStyle(fontFamily: kFontUi, color: SColors.mid),
    ),
    dividerColor: SColors.line,
    dividerTheme: const DividerThemeData(color: SColors.line, thickness: 1, space: 0),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStateProperty.all(SColors.bg4),
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
  );
}
