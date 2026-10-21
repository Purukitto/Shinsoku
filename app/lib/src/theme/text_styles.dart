import 'package:flutter/material.dart';
import 'colors.dart';

/// Bundled fonts (declared in pubspec). Using plain [TextStyle] with a
/// `fontFamily` avoids any runtime font fetching and the per-call lookup
/// overhead of a runtime font package.
const String _ui = 'SpaceGrotesk';
const String _mono = 'JetBrainsMono';

/// Public aliases so other widgets/themes reference the bundled families
/// without re-typing the magic strings.
const String kFontUi = _ui;
const String kFontMono = _mono;

abstract final class SText {
  static const TextStyle ui = TextStyle(fontFamily: _ui, color: SColors.hi);
  static const TextStyle mono = TextStyle(fontFamily: _mono, color: SColors.hi);

  // ui scale
  static TextStyle uiSm({Color? color}) =>
      TextStyle(fontFamily: _ui, fontSize: 12, color: color ?? SColors.mid);
  static TextStyle uiBase({Color? color, FontWeight? weight}) =>
      TextStyle(fontFamily: _ui, fontSize: 13.5, color: color ?? SColors.hi, fontWeight: weight);
  static TextStyle uiMd({Color? color, FontWeight? weight}) => TextStyle(
    fontFamily: _ui,
    fontSize: 14.5,
    color: color ?? SColors.hi,
    fontWeight: weight ?? FontWeight.w500,
  );
  static TextStyle uiLg({Color? color, FontWeight? weight}) => TextStyle(
    fontFamily: _ui,
    fontSize: 18,
    color: color ?? SColors.hi,
    fontWeight: weight ?? FontWeight.w600,
    letterSpacing: -0.01 * 18,
  );
  static TextStyle uiXl({Color? color, FontWeight? weight}) => TextStyle(
    fontFamily: _ui,
    fontSize: 21,
    color: color ?? SColors.hi,
    fontWeight: weight ?? FontWeight.w600,
    letterSpacing: -0.01 * 21,
  );

  // mono scale
  static TextStyle monoXs({Color? color}) => TextStyle(
    fontFamily: _mono,
    fontSize: 10,
    color: color ?? SColors.low,
    letterSpacing: 0.12 * 10,
  );
  static TextStyle monoSm({Color? color}) =>
      TextStyle(fontFamily: _mono, fontSize: 11.5, color: color ?? SColors.low);
  static TextStyle monoBase({Color? color, FontWeight? weight}) =>
      TextStyle(fontFamily: _mono, fontSize: 12.5, color: color ?? SColors.hi, fontWeight: weight);
  static TextStyle monoMd({Color? color, FontWeight? weight}) =>
      TextStyle(fontFamily: _mono, fontSize: 14, color: color ?? SColors.hi, fontWeight: weight);
  static TextStyle monoLg({Color? color, FontWeight? weight}) => TextStyle(
    fontFamily: _mono,
    fontSize: 19,
    color: color ?? SColors.hi,
    fontWeight: weight ?? FontWeight.w600,
    letterSpacing: -0.02 * 19,
  );
  static TextStyle monoXl({Color? color, FontWeight? weight}) => TextStyle(
    fontFamily: _mono,
    fontSize: 38,
    color: color ?? SColors.hi,
    fontWeight: weight ?? FontWeight.w600,
    letterSpacing: -0.02 * 38,
  );
  static TextStyle monoHero({Color? color}) => TextStyle(
    fontFamily: _mono,
    fontSize: 44,
    color: color ?? SColors.hi,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.02 * 44,
  );

  static TextStyle label({Color? color}) => TextStyle(
    fontFamily: _mono,
    fontSize: 11,
    color: color ?? SColors.low,
    letterSpacing: 0.14 * 11,
  );
}
