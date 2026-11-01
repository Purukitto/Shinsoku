import 'package:flutter/services.dart';

import '../models/finish_notice.dart';
import '../models/progress_summary.dart';
import '../providers/finish_provider.dart';
import '../providers/progress_provider.dart';

/// Android's foreground service (`DownloadService.kt`): while downloads run it
/// keeps the process from being frozen in the background, and its notification
/// shows their progress silently in the shade. Finished downloads get a
/// notification of their own (`FinishedNotice.kt`).
class DownloadService implements ProgressSink, FinishSink {
  DownloadService._();
  static final DownloadService instance = DownloadService._();

  static const _service = MethodChannel('shinsoku/downloads');

  /// Asking needs the window, so `MainActivity` answers this one.
  static const _permissions = MethodChannel('shinsoku/permissions');

  bool _asked = false;

  /// Android refused to start the service, as it does once the app is in the
  /// background; tried again the next time downloads start.
  bool _refused = false;

  @override
  void show(ProgressSummary summary) {
    if (_refused) return;
    if (!_asked) {
      _asked = true;
      _call(_permissions, 'notifications');
    }
    final p = summary.progress;
    _call<bool>(_service, 'show', {
      'title': summary.title,
      'text': summary.detail,
      // out of 1000; -1 while no size is known
      'progress': p == null ? -1 : (p * 1000).round(),
    }).then((started) => _refused = started == false);
  }

  @override
  void clear() {
    _refused = false;
    _call(_service, 'stop');
  }

  @override
  void notify(FinishNotice notice) {
    _call(_service, 'finished', {
      'id': notice.key,
      'title': notice.title,
      'text': notice.body,
      'failed': notice.failed,
      // tapping the notice for a finished file opens it
      if (!notice.failed && notice.single != null) 'path': notice.single!.path,
    });
  }

  /// No window to ask from, or no service to talk to, is not an error here.
  static Future<T?> _call<T>(MethodChannel channel, String method, [Object? args]) async {
    try {
      return await channel.invokeMethod<T>(method, args);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
