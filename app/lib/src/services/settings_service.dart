import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// User-tunable engine + app settings. Engine-applied values (connections,
/// simultaneous, download limit, categorize, off-peak) are pushed into the Rust
/// core on load and on change; the rest gate app-side behaviour (clipboard
/// monitor) or are stored for a feature not yet active (upload cap — there is no
/// seeding/upload path in the engine yet).
class AppSettings {
  const AppSettings({
    this.maxConnections = 8,
    this.maxSimultaneous = 3,
    this.downloadLimitMbps = 0,
    this.categorize = true,
    this.clipboardMonitor = true,
    this.uploadCap = true,
    this.uploadLimitMbps = 20,
    this.offPeak = true,
    this.offPeakStartMin = 23 * 60,
    this.offPeakEndMin = 7 * 60,
  });

  final int maxConnections; // segments per download
  final int maxSimultaneous;
  final int downloadLimitMbps; // 0 = unlimited
  final bool categorize;
  final bool clipboardMonitor;
  final bool uploadCap;
  final int uploadLimitMbps;
  final bool offPeak;
  final int offPeakStartMin; // minutes since midnight
  final int offPeakEndMin;

  AppSettings copyWith({
    int? maxConnections,
    int? maxSimultaneous,
    int? downloadLimitMbps,
    bool? categorize,
    bool? clipboardMonitor,
    bool? uploadCap,
    int? uploadLimitMbps,
    bool? offPeak,
    int? offPeakStartMin,
    int? offPeakEndMin,
  }) =>
      AppSettings(
        maxConnections: maxConnections ?? this.maxConnections,
        maxSimultaneous: maxSimultaneous ?? this.maxSimultaneous,
        downloadLimitMbps: downloadLimitMbps ?? this.downloadLimitMbps,
        categorize: categorize ?? this.categorize,
        clipboardMonitor: clipboardMonitor ?? this.clipboardMonitor,
        uploadCap: uploadCap ?? this.uploadCap,
        uploadLimitMbps: uploadLimitMbps ?? this.uploadLimitMbps,
        offPeak: offPeak ?? this.offPeak,
        offPeakStartMin: offPeakStartMin ?? this.offPeakStartMin,
        offPeakEndMin: offPeakEndMin ?? this.offPeakEndMin,
      );

  Map<String, dynamic> toJson() => {
        'maxConnections': maxConnections,
        'maxSimultaneous': maxSimultaneous,
        'downloadLimitMbps': downloadLimitMbps,
        'categorize': categorize,
        'clipboardMonitor': clipboardMonitor,
        'uploadCap': uploadCap,
        'uploadLimitMbps': uploadLimitMbps,
        'offPeak': offPeak,
        'offPeakStartMin': offPeakStartMin,
        'offPeakEndMin': offPeakEndMin,
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
      offPeak: m['offPeak'] as bool? ?? d.offPeak,
      offPeakStartMin: m['offPeakStartMin'] as int? ?? d.offPeakStartMin,
      offPeakEndMin: m['offPeakEndMin'] as int? ?? d.offPeakEndMin,
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
    } catch (_) {/* fall through to defaults */}
    return const AppSettings();
  }

  static Future<void> save(AppSettings s) async {
    try {
      final f = await _file();
      await f.writeAsString(jsonEncode(s.toJson()));
    } catch (_) {/* best-effort; in-memory state still drives the session */}
  }
}
