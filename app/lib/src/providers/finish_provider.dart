import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/download_item.dart';
import '../models/finish_notice.dart';
import '../platform.dart';
import '../services/desktop_notices.dart';
import '../services/download_service.dart';
import 'downloads_provider.dart';
import 'settings_provider.dart';

/// Where finished and failed downloads are announced: a desktop notification,
/// or an Android one.
abstract interface class FinishSink {
  void notify(FinishNotice notice);
}

/// Spots downloads that finish or fail from one download list to the next, and
/// holds them for [delay] so a burst that ends together makes one notification.
class FinishReporter {
  FinishReporter(this.sink, {DateTime? since, this.delay = const Duration(milliseconds: 1500)})
    : _since = since ?? DateTime.now();

  final FinishSink sink;
  final Duration delay;

  /// Off: nothing is announced, but what finishes is still tracked, so turning
  /// it back on doesn't announce old downloads.
  bool enabled = true;

  /// Restored downloads that were already done by then aren't news.
  final DateTime _since;

  var _seen = <String, DownloadStatus>{};
  var _next = <String, DownloadStatus>{};
  final _pending = <String>{};
  List<DownloadItem> _latest = const [];
  Timer? _timer;

  void update(List<DownloadItem> items) {
    _latest = items;
    for (final it in items) {
      final was = _seen[it.id];
      _next[it.id] = it.status;
      if (it.status == was || !enabled) continue;
      final news = switch (it.status) {
        // one first seen finished, say added and done between two refreshes
        DownloadStatus.completed => was != null || (it.completedAt?.isAfter(_since) ?? false),
        DownloadStatus.error => was != null,
        _ => false,
      };
      if (news) _pending.add(it.id);
    }
    final seen = _seen..clear();
    _seen = _next;
    _next = seen;
    if (_pending.isNotEmpty) _timer ??= Timer(delay, _flush);
  }

  /// Reads the items from the latest list, which by now has their final name
  /// and path; one retried in the meantime drops out.
  void _flush() {
    _timer = null;
    final items = [
      for (final it in _latest)
        if (_pending.contains(it.id)) it,
    ];
    _pending.clear();
    if (!enabled) return;
    for (final notice in FinishNotice.of(items)) {
      sink.notify(notice);
    }
  }

  void dispose() => _timer?.cancel();
}

/// Announces downloads as they finish, while the window is hidden or closed
/// too, unless notifications are turned off in Settings.
final finishReporterProvider = Provider<FinishReporter>((ref) {
  final reporter = FinishReporter(isDesktop ? DesktopNotices.instance : DownloadService.instance);
  ref.onDispose(reporter.dispose);
  reporter.enabled = ref.read(settingsProvider).notifyWhenDone;
  ref.listen(settingsProvider.select((s) => s.notifyWhenDone), (_, on) => reporter.enabled = on);
  ref.listen(downloadsProvider, (_, items) => reporter.update(items), fireImmediately: true);
  return reporter;
});
