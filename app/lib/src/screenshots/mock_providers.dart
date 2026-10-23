// Riverpod overrides that swap every engine-backed provider for the frozen mock
// dataset. Applied only by lib/main_screenshots.dart. Each notifier overrides
// `build()` so the Rust engine is never touched, and the mutators stay in-memory
// so a stray click during capture can't hit the engine or write the shared
// settings/capture JSON files.
import 'dart:async';

import 'package:flutter_riverpod/misc.dart';

import '../models/download_item.dart';
import '../providers/autostart_provider.dart';
import '../providers/capture_provider.dart';
import '../providers/downloads_provider.dart';
import '../providers/settings_provider.dart';
import '../services/autostart_service.dart';
import '../services/settings_service.dart';
import 'mock_data.dart';

class _MockDownloads extends DownloadsNotifier {
  @override
  List<DownloadItem> build() => List<DownloadItem>.of(mockDownloads);

  void _patch(String id, DownloadStatus s, {bool zeroSpeed = false}) {
    final i = state.indexWhere((d) => d.id == id);
    if (i < 0) return;
    final next = [...state];
    next[i] = state[i].copyWith(status: s, speedBps: zeroSpeed ? 0 : state[i].speedBps);
    state = next;
  }

  @override
  void pause(String id) => _patch(id, DownloadStatus.paused, zeroSpeed: true);

  @override
  void resume(String id) => _patch(id, DownloadStatus.downloading);

  @override
  void remove(String id) => state = state.where((d) => d.id != id).toList();

  @override
  Future<void> add({
    required String url,
    required int connections,
    List<(String, String)> headers = const [],
    String? expectedChecksum,
    bool scheduled = false,
  }) async {}

  @override
  Future<void> addStream({
    required String url,
    List<(String, String)> headers = const [],
    String? title,
    bool scheduled = false,
  }) async {}

  @override
  void setScheduled(String id, bool on) {
    final i = state.indexWhere((d) => d.id == id);
    if (i < 0) return;
    state = [...state]..[i] = state[i].copyWith(scheduled: on);
  }

  @override
  void setRunning(bool running) {}
}

class _MockGlobalSpeed extends GlobalSpeedNotifier {
  @override
  List<int> build() => mockGlobalSpeed;

  @override
  void setRunning(bool running) {}
}

class _MockSettings extends SettingsNotifier {
  @override
  AppSettings build() => mockSettings;

  // All setters stay in-memory: no engine push, no disk write (the screenshot
  // app shares the real app's settings.json — never clobber it).
  @override
  void setMaxConnections(int n) => state = state.copyWith(maxConnections: n);
  @override
  void setMaxSimultaneous(int n) => state = state.copyWith(maxSimultaneous: n);
  @override
  void setDownloadLimitMbps(int mbps) => state = state.copyWith(downloadLimitMbps: mbps);
  @override
  void setCategorize(bool on) => state = state.copyWith(categorize: on);
  @override
  void setClipboardMonitor(bool on) => state = state.copyWith(clipboardMonitor: on);
  @override
  void setUploadCap(bool on) => state = state.copyWith(uploadCap: on);
  @override
  void setUploadLimitMbps(int mbps) => state = state.copyWith(uploadLimitMbps: mbps);
  @override
  void setOffPeakFullSpeed(bool on) => state = state.copyWith(offPeakFullSpeed: on);
  @override
  void setOffPeakWindow(int startMin, int endMin) =>
      state = state.copyWith(offPeakStartMin: startMin, offPeakEndMin: endMin);
  @override
  void setOffPeakDays(int days) => state = state.copyWith(offPeakDays: days);
}

/// Startup entry kept in memory, never written to the system.
class _MockAutostart implements AutostartService {
  bool _on = false;

  @override
  bool get supported => true;

  @override
  bool isEnabled() => _on;

  @override
  void setEnabled(bool on) => _on = on;
}

class _MockCapture extends CaptureNotifier {
  @override
  CaptureState build() => mockCapture;

  @override
  Future<void> setEnabled(bool on) async => state = state.copyWith(enabled: on);
}

/// Drop-in for `ProviderScope(overrides: ...)` in the screenshot entry point.
final List<Override> screenshotOverrides = <Override>[
  downloadsProvider.overrideWith(_MockDownloads.new),
  globalSpeedHistoryProvider.overrideWith(_MockGlobalSpeed.new),
  settingsProvider.overrideWith(_MockSettings.new),
  captureProvider.overrideWith(_MockCapture.new),
  autostartServiceProvider.overrideWithValue(_MockAutostart()),
  // Detail screen's live poll — track the (mock) list instead of the engine.
  liveDownloadProvider.overrideWith(
    (ref, id) => Stream<DownloadItem?>.value(ref.watch(downloadItemProvider(id))),
  ),
  captureStatusProvider.overrideWith((ref) => Stream.value(mockCaptureStatus)),
];
