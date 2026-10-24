import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/progress_summary.dart';
import '../platform.dart';
import '../services/download_service.dart';
import '../services/tray_service.dart';
import 'downloads_provider.dart';

/// Where progress shows outside the window: the desktop tray, or the Android
/// notification.
abstract interface class ProgressSink {
  void show(ProgressSummary summary);

  /// Nothing is active any more.
  void clear();
}

/// Passes [ProgressSummary] on to [sink] only when it changes, and clears it
/// once nothing is active.
class ProgressReporter {
  ProgressReporter(this.sink);

  final ProgressSink sink;
  ProgressSummary _last = ProgressSummary.idle;

  void report(ProgressSummary summary) {
    if (summary == _last) return;
    _last = summary;
    if (summary.isIdle) {
      sink.clear();
    } else {
      sink.show(summary);
    }
  }
}

/// Reports about once a second, and at once when a download starts or stops,
/// so a new one appears without waiting for the tick. It keeps going while the
/// window is hidden or closed, which is when the tray and the notification
/// matter.
final progressReporterProvider = Provider<ProgressReporter>((ref) {
  final reporter = ProgressReporter(isDesktop ? TrayService.instance : DownloadService.instance);
  void report() => reporter.report(ProgressSummary.of(ref.read(downloadsProvider)));

  final timer = Timer.periodic(const Duration(seconds: 1), (_) => report());
  ref.onDispose(timer.cancel);
  ref.listen(downloadsProvider.select((l) => ProgressSummary.of(l).active), (_, _) => report());
  return reporter;
});
