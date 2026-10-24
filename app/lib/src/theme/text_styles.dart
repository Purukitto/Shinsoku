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

/// The type scale, coloured from a palette: `context.colors.text.uiBase()`.
class SText {
  const SText(this._c);

  final SColors _c;

  // ui scale
  TextStyle uiSm({Color? color}) =>
      TextStyle(fontFamily: _ui, fontSize: 12, color: color ?? _c.mid);
  TextStyle uiBase({Color? color, FontWeight? weight}) =>
      TextStyle(fontFamily: _ui, fontSize: 13.5, color: color ?? _c.hi, fontWeight: weight);
  TextStyle uiMd({Color? color, FontWeight? weight}) => TextStyle(
    fontFamily: _ui,
    fontSize: 14.5,
    color: color ?? _c.hi,
    fontWeight: weight ?? FontWeight.w500,
  );
  TextStyle uiLg({Color? color, FontWeight? weight}) => TextStyle(
    fontFamily: _ui,
    fontSize: 18,
    color: color ?? _c.hi,
    fontWeight: weight ?? FontWeight.w600,
    letterSpacing: -0.01 * 18,
  );
  TextStyle uiXl({Color? color, FontWeight? weight}) => TextStyle(
    fontFamily: _ui,
    fontSize: 21,
    color: color ?? _c.hi,
    fontWeight: weight ?? FontWeight.w600,
    letterSpacing: -0.01 * 21,
  );

  // mono scale
  TextStyle monoXs({Color? color}) =>
      TextStyle(fontFamily: _mono, fontSize: 10, color: color ?? _c.low, letterSpacing: 0.12 * 10);
  TextStyle monoSm({Color? color}) =>
      TextStyle(fontFamily: _mono, fontSize: 11.5, color: color ?? _c.low);
  TextStyle monoBase({Color? color, FontWeight? weight}) =>
      TextStyle(fontFamily: _mono, fontSize: 12.5, color: color ?? _c.hi, fontWeight: weight);
  TextStyle monoMd({Color? color, FontWeight? weight}) =>
      TextStyle(fontFamily: _mono, fontSize: 14, color: color ?? _c.hi, fontWeight: weight);
  TextStyle monoLg({Color? color, FontWeight? weight}) => TextStyle(
    fontFamily: _mono,
    fontSize: 19,
    color: color ?? _c.hi,
    fontWeight: weight ?? FontWeight.w600,
    letterSpacing: -0.02 * 19,
  );
  TextStyle monoXl({Color? color, FontWeight? weight}) => TextStyle(
    fontFamily: _mono,
    fontSize: 38,
    color: color ?? _c.hi,
    fontWeight: weight ?? FontWeight.w600,
    letterSpacing: -0.02 * 38,
  );
  TextStyle monoHero({Color? color}) => TextStyle(
    fontFamily: _mono,
    fontSize: 44,
    color: color ?? _c.hi,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.02 * 44,
  );

  TextStyle label({Color? color}) =>
      TextStyle(fontFamily: _mono, fontSize: 11, color: color ?? _c.low, letterSpacing: 0.14 * 11);
}

extension SColorsText on SColors {
  SText get text => SText(this);
}
