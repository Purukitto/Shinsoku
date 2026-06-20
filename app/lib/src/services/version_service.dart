import 'dart:convert';
import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';

/// A newer GitHub release than what's running.
class UpdateInfo {
  const UpdateInfo({required this.current, required this.latest, required this.url});

  final String current; // running version, e.g. "0.1.0"
  final String latest; // release version without the leading "v"
  final String url; // release page (html_url)
}

/// Reads the bundled app version and checks the GitHub Releases feed for a newer
/// one. Network/parse failures are swallowed — an update prompt is best-effort.
class VersionService {
  static const _owner = 'purukitto';
  static const _repo = 'Shinsoku';

  static Future<String> current() async {
    final info = await PackageInfo.fromPlatform();
    return info.version;
  }

  /// The latest release if it's newer than [current]; otherwise null.
  static Future<UpdateInfo?> checkForUpdate(String current) async {
    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
      final req = await client.getUrl(
        Uri.https('api.github.com', '/repos/$_owner/$_repo/releases/latest'),
      );
      req.headers
        ..set(HttpHeaders.userAgentHeader, 'Shinsoku-UpdateCheck')
        ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      final res = await req.close();
      if (res.statusCode != 200) return null; // no releases yet, rate-limited, etc.
      final body = await res.transform(utf8.decoder).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      final latest = (json['tag_name'] as String? ?? '').trim().replaceFirst(RegExp(r'^v'), '');
      final url = (json['html_url'] as String? ?? '').trim();
      if (latest.isEmpty || url.isEmpty) return null;
      return _isNewer(latest, current)
          ? UpdateInfo(current: current, latest: latest, url: url)
          : null;
    } catch (_) {
      return null;
    } finally {
      client?.close(force: true);
    }
  }

  static bool _isNewer(String a, String b) {
    final pa = _parse(a), pb = _parse(b);
    for (var i = 0; i < 3; i++) {
      if (pa[i] != pb[i]) return pa[i] > pb[i];
    }
    return false;
  }

  // "X.Y.Z" → [X, Y, Z], dropping any pre-release/build suffix.
  static List<int> _parse(String v) {
    final core = v.split(RegExp(r'[-+]')).first.split('.');
    return List<int>.generate(3, (i) => i < core.length ? int.tryParse(core[i]) ?? 0 : 0);
  }
}
