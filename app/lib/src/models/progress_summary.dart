import 'download_item.dart';
import 'format.dart';

/// Every download that is running or about to start, rolled into the one line
/// the Android notification and the desktop tray show.
class ProgressSummary {
  const ProgressSummary({
    required this.active,
    required this.running,
    required this.downloadedBytes,
    required this.totalBytes,
    required this.speedBps,
    this.name,
  });

  static const idle = ProgressSummary(
    active: 0,
    running: 0,
    downloadedBytes: 0,
    totalBytes: 0,
    speedBps: 0,
  );

  /// Downloading, or queued to start as soon as a slot frees up. Paused,
  /// failed and scheduled downloads don't count: nothing is happening to them.
  factory ProgressSummary.of(Iterable<DownloadItem> items) {
    var active = 0, running = 0, downloaded = 0, total = 0, speed = 0;
    String? name;
    for (final it in items) {
      final isRunning = it.status == DownloadStatus.downloading;
      if (!isRunning && (it.status != DownloadStatus.queued || it.waitingForOffPeak)) continue;
      active++;
      name = it.name;
      if (isRunning) {
        running++;
        speed += it.speedBps;
      }
      // a download of unknown size can't count towards the total
      if (it.totalBytes > 0) {
        downloaded += it.downloadedBytes;
        total += it.totalBytes;
      }
    }
    return ProgressSummary(
      active: active,
      running: running,
      downloadedBytes: downloaded,
      totalBytes: total,
      speedBps: speed,
      name: active == 1 ? name : null,
    );
  }

  final int active;
  final int running;
  final int downloadedBytes;
  final int totalBytes;
  final int speedBps;

  /// The file's name when exactly one download is active.
  final String? name;

  bool get isIdle => active == 0;

  /// Share of the known bytes done, or null while no size is known.
  double? get progress => totalBytes > 0 ? (downloadedBytes / totalBytes).clamp(0.0, 1.0) : null;

  int? get etaSeconds {
    if (speedBps <= 0 || totalBytes <= 0) return null;
    return ((totalBytes - downloadedBytes) / speedBps).ceil();
  }

  /// "ubuntu.iso", or "3 downloads".
  String get title => name ?? '$active downloads';

  /// "45.0% · 12.3 MB/s · 2m 10s left".
  String get detail {
    if (running == 0) return 'Waiting to start';
    final p = progress;
    final eta = etaSeconds;
    return [
      if (p != null) fmtPct(p),
      fmtSpeed(speedBps),
      if (eta != null) '${fmtEta(eta)} left',
    ].join(' · ');
  }

  @override
  bool operator ==(Object other) =>
      other is ProgressSummary &&
      other.active == active &&
      other.running == running &&
      other.downloadedBytes == downloadedBytes &&
      other.totalBytes == totalBytes &&
      other.speedBps == speedBps &&
      other.name == name;

  @override
  int get hashCode => Object.hash(active, running, downloadedBytes, totalBytes, speedBps, name);
}
