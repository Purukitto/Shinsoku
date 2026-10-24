import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart' show ThemeMode;
import 'package:path_provider/path_provider.dart';

import '../models/off_peak.dart';

/// User-tunable engine + app settings. Engine-applied values (connections,
/// simultaneous, download limit, categorize, off-peak hours) are pushed into the Rust
/// core on load and on change; the rest gate app-side behaviour (clipboard
/// monitor, appearance) or are stored for a feature not yet active (upload cap —
/// there is no seeding/upload path in the engine yet).
class AppSettings {
  const AppSettings({
    this.maxConnections = 8,
    this.maxSimultaneous = 3,
    this.downloadLimitMbps = 0,
    this.categorize = true,
    this.clipboardMonitor = true,
    this.uploadCap = true,
    this.uploadLimitMbps = 20,
    this.offPeakFullSpeed = true,
    this.offPeakStartMin = 23 * 60,
    this.offPeakEndMin = 7 * 60,
    this.offPeakDays = OffPeakHours.everyDay,
    this.themeMode = ThemeMode.system,
    this.pureBlack = false,
    this.accent = 'volt',
  });

  final int maxConnections; // segments per download
  final int maxSimultaneous;
  final int downloadLimitMbps; // 0 = unlimited
  final bool categorize;
  final bool clipboardMonitor;
  final bool uploadCap;
  final int uploadLimitMbps;

  /// Lift the download limit during off-peak hours.
  final bool offPeakFullSpeed;
  final int offPeakStartMin; // minutes since midnight
  final int offPeakEndMin;

  /// Days off-peak hours begin on: bit 0 = Monday … bit 6 = Sunday.
  final int offPeakDays;

  final ThemeMode themeMode;

  /// True black instead of near-black in dark mode, for OLED screens.
  final bool pureBlack;

  final String accent; // an SAccent id

  OffPeakHours get offPeakHours =>
      OffPeakHours(startMin: offPeakStartMin, endMin: offPeakEndMin, days: offPeakDays);

  AppSettings copyWith({
    int? maxConnections,
    int? maxSimultaneous,
    int? downloadLimitMbps,
    bool? categorize,
    bool? clipboardMonitor,
    bool? uploadCap,
    int? uploadLimitMbps,
    bool? offPeakFullSpeed,
    int? offPeakStartMin,
    int? offPeakEndMin,
    int? offPeakDays,
    ThemeMode? themeMode,
    bool? pureBlack,
    String? accent,
  }) => AppSettings(
    maxConnections: maxConnections ?? this.maxConnections,
    maxSimultaneous: maxSimultaneous ?? this.maxSimultaneous,
    downloadLimitMbps: downloadLimitMbps ?? this.downloadLimitMbps,
    categorize: categorize ?? this.categorize,
    clipboardMonitor: clipboardMonitor ?? this.clipboardMonitor,
    uploadCap: uploadCap ?? this.uploadCap,
    uploadLimitMbps: uploadLimitMbps ?? this.uploadLimitMbps,
    offPeakFullSpeed: offPeakFullSpeed ?? this.offPeakFullSpeed,
    offPeakStartMin: offPeakStartMin ?? this.offPeakStartMin,
    offPeakEndMin: offPeakEndMin ?? this.offPeakEndMin,
    offPeakDays: offPeakDays ?? this.offPeakDays,
    themeMode: themeMode ?? this.themeMode,
    pureBlack: pureBlack ?? this.pureBlack,
    accent: accent ?? this.accent,
  );

  Map<String, dynamic> toJson() => {
    'maxConnections': maxConnections,
    'maxSimultaneous': maxSimultaneous,
    'downloadLimitMbps': downloadLimitMbps,
    'categorize': categorize,
    'clipboardMonitor': clipboardMonitor,
    'uploadCap': uploadCap,
    'uploadLimitMbps': uploadLimitMbps,
    // named before the hours also scheduled downloads
    'offPeak': offPeakFullSpeed,
    'offPeakStartMin': offPeakStartMin,
    'offPeakEndMin': offPeakEndMin,
    'offPeakDays': offPeakDays,
    'themeMode': themeMode.name,
    'pureBlack': pureBlack,
    'accent': accent,
  };

  factory AppSettings.fromJson(Map<String, dynamic> m) {
    const d = AppSettings();
    return AppSettings(
      maxConnections: m['maxConnections'] as int? ?? d.maxConnections,
      maxSimultaneous: m['maxSimultaneous'] as int? ?? d.maxSimultaneous,
      downloadLimitMbps: m['downloadLimitMbps'] as int? ?? d.downloadLimitMbps,
      categorize: m['categorize'] as bool? ?? d.categorize,
      clipboardMonitor: m['clipboardMonitor'] as bool? ?? d.clipboardMonitor,
      uploadCap: m['uploadCap'] as bool? ?? d.uploadCap,
      uploadLimitMbps: m['uploadLimitMbps'] as int? ?? d.uploadLimitMbps,
      offPeakFullSpeed: m['offPeak'] as bool? ?? d.offPeakFullSpeed,
      offPeakStartMin: m['offPeakStartMin'] as int? ?? d.offPeakStartMin,
      offPeakEndMin: m['offPeakEndMin'] as int? ?? d.offPeakEndMin,
      offPeakDays: m['offPeakDays'] as int? ?? d.offPeakDays,
      themeMode: ThemeMode.values.asNameMap()[m['themeMode']] ?? d.themeMode,
      pureBlack: m['pureBlack'] as bool? ?? d.pureBlack,
      accent: m['accent'] as String? ?? d.accent,
    );
  }
}

/// Loads/saves [AppSettings] as JSON in the app support dir (sibling to the
/// download store and capture config).
class SettingsService {
  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/settings.json');
  }

  static Future<AppSettings> load() async {
    try {
      final f = await _file();
      if (await f.exists()) {
        final m = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        return AppSettings.fromJson(m);
      }
    } catch (_) {
      /* fall through to defaults */
    }
    return const AppSettings();
  }

  static Future<void> save(AppSettings s) async {
    try {
      final f = await _file();
      await f.writeAsString(jsonEncode(s.toJson()));
    } catch (_) {
      /* best-effort; in-memory state still drives the session */
    }
  }
}
