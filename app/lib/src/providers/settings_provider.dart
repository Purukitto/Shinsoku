import 'dart:async';

import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rust/api.dart' as rust;
import '../services/settings_service.dart';
import 'downloads_provider.dart';

const _bytesPerMb = 1024 * 1024;

/// Holds [AppSettings], pushes engine-side values into the Rust core, and
/// persists changes. Engine writes are immediate (cheap atomics); the disk write
/// is debounced so dragging a slider doesn't thrash the file.
class SettingsNotifier extends Notifier<AppSettings> {
  /// [loaded] is what launch already read from disk, so the first frame has the
  /// right theme; without it, settings load after the first frame.
  SettingsNotifier([this._loaded]);

  final AppSettings? _loaded;
  Timer? _saveDebounce;

  @override
  AppSettings build() {
    ref.onDispose(() => _saveDebounce?.cancel());
    final loaded = _loaded;
    if (loaded != null) {
      _applyAll(loaded);
      return loaded;
    }
    Future.microtask(_init);
    return const AppSettings();
  }

  Future<void> _init() async {
    final s = await SettingsService.load();
    state = s;
    _applyAll(s);
  }

  rust.ShinsokuEngine get _engine => ref.read(engineProvider);

  /// Push every engine-applied setting into the core (startup sync).
  void _applyAll(AppSettings s) {
    final e = _engine;
    rust.setMaxConnections(engine: e, n: s.maxConnections);
    rust.setMaxSimultaneous(engine: e, n: s.maxSimultaneous);
    rust.setSpeedLimitBps(engine: e, bps: BigInt.from(s.downloadLimitMbps * _bytesPerMb));
    rust.setCategorize(engine: e, on_: s.categorize);
    _pushOffPeak(s);
  }

  void _pushOffPeak(AppSettings s) => rust.setOffPeak(
    engine: _engine,
    fullSpeed: s.offPeakFullSpeed,
    startMin: s.offPeakStartMin,
    endMin: s.offPeakEndMin,
    days: s.offPeakDays,
  );

  /// Off-peak changes all go to the engine together.
  void _setOffPeak(AppSettings next) {
    _pushOffPeak(next);
    _set(next);
  }

  void _set(AppSettings next) {
    state = next;
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 400), () => SettingsService.save(state));
  }

  void setMaxConnections(int n) {
    rust.setMaxConnections(engine: _engine, n: n);
    _set(state.copyWith(maxConnections: n));
  }

  void setMaxSimultaneous(int n) {
    rust.setMaxSimultaneous(engine: _engine, n: n);
    _set(state.copyWith(maxSimultaneous: n));
  }

  void setDownloadLimitMbps(int mbps) {
    rust.setSpeedLimitBps(engine: _engine, bps: BigInt.from(mbps * _bytesPerMb));
    _set(state.copyWith(downloadLimitMbps: mbps));
  }

  void setCategorize(bool on) {
    rust.setCategorize(engine: _engine, on_: on);
    _set(state.copyWith(categorize: on));
  }

  void setClipboardMonitor(bool on) => _set(state.copyWith(clipboardMonitor: on));

  void setUploadCap(bool on) => _set(state.copyWith(uploadCap: on));

  void setUploadLimitMbps(int mbps) => _set(state.copyWith(uploadLimitMbps: mbps));

  void setOffPeakFullSpeed(bool on) => _setOffPeak(state.copyWith(offPeakFullSpeed: on));

  void setOffPeakWindow(int startMin, int endMin) =>
      _setOffPeak(state.copyWith(offPeakStartMin: startMin, offPeakEndMin: endMin));

  void setOffPeakDays(int days) => _setOffPeak(state.copyWith(offPeakDays: days));

  void setThemeMode(ThemeMode mode) => _set(state.copyWith(themeMode: mode));

  void setPureBlack(bool on) => _set(state.copyWith(pureBlack: on));

  void setAccent(String id) => _set(state.copyWith(accent: id));
}

final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(SettingsNotifier.new);
