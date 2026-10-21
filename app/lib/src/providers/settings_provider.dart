import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rust/api.dart' as rust;
import '../services/settings_service.dart';
import 'downloads_provider.dart';

const _bytesPerMb = 1024 * 1024;

/// Holds [AppSettings], pushes engine-side values into the Rust core, and
/// persists changes. Engine writes are immediate (cheap atomics); the disk write
/// is debounced so dragging a slider doesn't thrash the file.
class SettingsNotifier extends Notifier<AppSettings> {
  Timer? _saveDebounce;

  @override
  AppSettings build() {
    ref.onDispose(() => _saveDebounce?.cancel());
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
    rust.setOffPeak(
      engine: e,
      enabled: s.offPeak,
      startMin: s.offPeakStartMin,
      endMin: s.offPeakEndMin,
    );
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

  void setOffPeak(bool on) {
    rust.setOffPeak(
      engine: _engine,
      enabled: on,
      startMin: state.offPeakStartMin,
      endMin: state.offPeakEndMin,
    );
    _set(state.copyWith(offPeak: on));
  }

  void setOffPeakWindow(int startMin, int endMin) {
    rust.setOffPeak(engine: _engine, enabled: state.offPeak, startMin: startMin, endMin: endMin);
    _set(state.copyWith(offPeakStartMin: startMin, offPeakEndMin: endMin));
  }
}

final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(SettingsNotifier.new);
