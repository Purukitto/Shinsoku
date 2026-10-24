import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shinsoku/src/services/settings_service.dart';
import 'package:shinsoku/src/theme/app_theme.dart';
import 'package:shinsoku/src/theme/colors.dart';

/// WCAG contrast ratio between two opaque colours.
double _contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  final (hi, lo) = la > lb ? (la, lb) : (lb, la);
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  final palettes = {
    for (final a in SAccent.all) ...{
      '${a.name} dark': SColors.dark(a),
      '${a.name} pure black': SColors.dark(a, pureBlack: true),
      '${a.name} light': SColors.light(a),
    },
  };

  for (final MapEntry(key: name, value: c) in palettes.entries) {
    test('$name: text stays readable on the page and on panels', () {
      for (final surface in [c.bg0, c.bg1]) {
        expect(_contrast(c.hi, surface), greaterThanOrEqualTo(7), reason: 'hi');
        expect(_contrast(c.mid, surface), greaterThanOrEqualTo(4.5), reason: 'mid');
        expect(_contrast(c.low, surface), greaterThanOrEqualTo(3), reason: 'low');
        for (final (label, hue) in [
          ('accent', c.accent),
          ('accentStart', c.accentStart),
          ('danger', c.danger),
          ('mint', c.mint),
          ('amber', c.amber),
        ]) {
          expect(_contrast(hue, surface), greaterThanOrEqualTo(3), reason: label);
        }
      }
      expect(_contrast(c.accentInk, c.accentFill[1]), greaterThanOrEqualTo(4.5), reason: 'ink');
    });
  }

  test('a palette blends halfway and ends on its target', () {
    final dark = SColors.dark(SAccent.volt), light = SColors.light(SAccent.volt);
    expect(dark.lerp(light, 0.5).bg0, Color.lerp(dark.bg0, light.bg0, 0.5));
    expect(dark.lerp(null, 0.5), same(dark));
  });

  test('an unknown accent falls back to the default', () {
    expect(SAccent.byId('gone'), same(SAccent.volt));
  });

  testWidgets('widgets get the palette for the theme in use', (tester) async {
    late SColors seen;
    Widget app(ThemeMode mode) => MaterialApp(
      theme: AppTheme.light(SAccent.volt),
      darkTheme: AppTheme.dark(SAccent.volt, pureBlack: true),
      themeMode: mode,
      home: Builder(
        builder: (context) {
          seen = context.colors;
          return const SizedBox();
        },
      ),
    );

    await tester.pumpWidget(app(ThemeMode.light));
    expect(seen.bg0, SColors.light(SAccent.volt).bg0);
    await tester.pumpWidget(app(ThemeMode.dark));
    await tester.pumpAndSettle(); // the switch fades
    expect(seen.bg0, const Color(0xFF000000));
  });

  group('appearance settings', () {
    test('survive a save and load', () {
      const s = AppSettings(themeMode: ThemeMode.light, pureBlack: true, accent: 'volt');
      final back = AppSettings.fromJson(s.toJson());
      expect(back.themeMode, ThemeMode.light);
      expect(back.pureBlack, isTrue);
      expect(back.accent, 'volt');
    });

    test('default to following the system from older or odd files', () {
      final old = AppSettings.fromJson({'maxConnections': 4});
      expect(old.themeMode, ThemeMode.system);
      expect(old.pureBlack, isFalse);
      expect(old.accent, 'volt');
      expect(AppSettings.fromJson({'themeMode': 'sepia'}).themeMode, ThemeMode.system);
    });
  });
}
