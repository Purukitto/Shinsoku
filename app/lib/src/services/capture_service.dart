import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path_provider/path_provider.dart';

/// Persisted browser-capture settings: whether the loopback server is on, the
/// port the extension posts to, and the shared token guarding it.
class CaptureConfig {
  const CaptureConfig({required this.enabled, required this.port, required this.token});

  final bool enabled;
  final int port;
  final String token;

  CaptureConfig copyWith({bool? enabled, int? port, String? token}) => CaptureConfig(
    enabled: enabled ?? this.enabled,
    port: port ?? this.port,
    token: token ?? this.token,
  );
}

/// Loads/saves [CaptureConfig] as JSON in the app support dir. The token is
/// generated once on first run so the extension pairs against a stable secret.
class CaptureService {
  static const _defaultPort = 7878;

  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/capture.json');
  }

  static Future<CaptureConfig> load() async {
    try {
      final f = await _file();
      if (await f.exists()) {
        final m = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        final token = (m['token'] as String?)?.trim();
        if (token != null && token.isNotEmpty) {
          return CaptureConfig(
            enabled: m['enabled'] as bool? ?? false,
            port: m['port'] as int? ?? _defaultPort,
            token: token,
          );
        }
      }
    } catch (_) {
      /* fall through to fresh defaults */
    }
    final fresh = CaptureConfig(enabled: false, port: _defaultPort, token: _genToken());
    await save(fresh);
    return fresh;
  }

  static Future<void> save(CaptureConfig c) async {
    try {
      final f = await _file();
      await f.writeAsString(jsonEncode({'enabled': c.enabled, 'port': c.port, 'token': c.token}));
    } catch (_) {
      /* best-effort; in-memory state still drives the session */
    }
  }

  static String _genToken() {
    final r = Random.secure();
    return List<int>.generate(
      16,
      (_) => r.nextInt(256),
    ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
