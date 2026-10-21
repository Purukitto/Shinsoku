import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rust/api.dart' as rust;
import '../services/capture_service.dart';
import 'downloads_provider.dart';

/// Live state of the browser-capture server. [port] is the actually-bound port
/// (the extension must use it); [running] is false if binding failed.
class CaptureState {
  const CaptureState({
    required this.enabled,
    required this.running,
    required this.port,
    required this.token,
  });

  final bool enabled;
  final bool running;
  final int port;
  final String token;

  CaptureState copyWith({bool? enabled, bool? running, int? port, String? token}) => CaptureState(
    enabled: enabled ?? this.enabled,
    running: running ?? this.running,
    port: port ?? this.port,
    token: token ?? this.token,
  );

  static const empty = CaptureState(enabled: false, running: false, port: 0, token: '');

  /// Single copy-paste pairing code carrying host+port+token; the extension
  /// decodes it to fill all its fields at once. The server always binds
  /// loopback, so host is fixed.
  String get pairingCode {
    if (token.isEmpty || port == 0) return '';
    final payload = jsonEncode({'h': '127.0.0.1', 'p': port, 't': token});
    return 'shnsk_${base64.encode(utf8.encode(payload))}';
  }
}

class CaptureNotifier extends Notifier<CaptureState> {
  @override
  CaptureState build() {
    Future.microtask(_init);
    return CaptureState.empty;
  }

  Future<void> _init() async {
    final cfg = await CaptureService.load();
    state = CaptureState(enabled: cfg.enabled, running: false, port: cfg.port, token: cfg.token);
    if (cfg.enabled) await _start();
  }

  /// Start the engine's capture server on the configured port. The engine may
  /// fall back to a nearby port if taken; persist whatever it bound so the
  /// displayed port stays stable across restarts.
  Future<void> _start() async {
    final engine = ref.read(engineProvider);
    final dir = await ref.read(downloadDirProvider.future);
    final bound = rust.startCaptureServer(
      engine: engine,
      port: state.port,
      token: state.token,
      destDir: dir,
    );
    if (bound == 0) {
      state = state.copyWith(running: false);
      return;
    }
    state = state.copyWith(running: true, port: bound);
    await CaptureService.save(
      CaptureConfig(enabled: state.enabled, port: bound, token: state.token),
    );
  }

  Future<void> setEnabled(bool on) async {
    state = state.copyWith(enabled: on);
    await CaptureService.save(CaptureConfig(enabled: on, port: state.port, token: state.token));
    if (on) {
      await _start();
    } else {
      rust.stopCaptureServer(engine: ref.read(engineProvider));
      state = state.copyWith(running: false);
    }
  }
}

final captureProvider = NotifierProvider<CaptureNotifier, CaptureState>(CaptureNotifier.new);

/// Polls live server activity (last-seen + capture count) while watched, so the
/// Settings panel can show "Browser connected". Auto-disposes when not visible.
final captureStatusProvider = StreamProvider.autoDispose<rust.CaptureStatus>((ref) async* {
  final engine = ref.watch(engineProvider);
  while (true) {
    yield rust.captureStatus(engine: engine);
    await Future<void>.delayed(const Duration(milliseconds: 1500));
  }
});
