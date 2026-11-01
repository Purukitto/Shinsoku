import 'download_item.dart';
import 'format.dart';

/// One notification for downloads that finished, or failed, at about the same
/// time.
class FinishNotice {
  const FinishNotice(this.items, {required this.failed});

  /// One notice for the downloads in [items] that finished and one for those
  /// that failed, leaving out a notice with nothing in it.
  static List<FinishNotice> of(List<DownloadItem> items) {
    final done = [
      for (final it in items)
        if (it.status == DownloadStatus.completed) it,
    ];
    final failed = [
      for (final it in items)
        if (it.status == DownloadStatus.error) it,
    ];
    return [
      if (done.isNotEmpty) FinishNotice(done, failed: false),
      if (failed.isNotEmpty) FinishNotice(failed, failed: true),
    ];
  }

  final List<DownloadItem> items;
  final bool failed;

  /// The download, when the notice is about only one.
  DownloadItem? get single => items.length == 1 ? items.single : null;

  /// "ubuntu.iso", or "3 downloads complete".
  String get title => single?.name ?? '${items.length} downloads ${failed ? 'failed' : 'complete'}';

  /// "Download complete · 4.7 GB", "Download failed · why", or the names.
  String get body {
    final one = single;
    if (one == null) return names([for (final it in items) it.name]);
    if (failed) return one.error == null ? 'Download failed' : 'Download failed · ${one.error}';
    return one.totalBytes > 0
        ? 'Download complete · ${fmtBytes(one.totalBytes)}'
        : 'Download complete';
  }

  /// Notifications with the same key replace each other, so a download that
  /// failed and then finished leaves only the second. Kept clear of the
  /// Android progress notification's small id.
  int get key =>
      (single?.id ?? items.map((i) => i.id).join(' ')).hashCode & 0x3fffffff | 0x40000000;

  /// "a, b and c", or "a, b and 2 more".
  static String names(List<String> names) {
    if (names.length <= 1) return names.join();
    if (names.length <= 3) {
      return '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
    }
    return '${names.take(2).join(', ')} and ${names.length - 2} more';
  }
}
