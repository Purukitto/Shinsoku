enum DownloadStatus { queued, downloading, paused, completed, error }

enum FileType { video, archive, app, audio, image, doc, iso, unknown }

class SegmentInfo {
  final int index;
  final double progress; // 0.0–1.0

  const SegmentInfo({required this.index, required this.progress});

  SegmentInfo copyWith({int? index, double? progress}) =>
      SegmentInfo(index: index ?? this.index, progress: progress ?? this.progress);
}

class DownloadItem {
  final String id;
  final String name;
  final String url;

  /// Page the download came from (its `Referer` header), when known.
  final String? referrer;
  final String host;
  final FileType fileType;
  final int totalBytes;
  final int downloadedBytes;
  final int speedBps;
  final int peakBps;
  final DownloadStatus status;
  final int connections;
  final List<SegmentInfo> segments;
  final List<int> speedHistory;
  final DateTime addedAt;
  final DateTime? completedAt;
  final String? checksum;
  final String? checksumAlgo;
  final bool? checksumVerified;

  /// HLS stream download (concatenated M3U8 segments) vs a plain byte-range file.
  final bool isHls;

  /// HLS only: total media segments / segments completed (0 for plain downloads).
  final int segmentTotal;
  final int segmentDone;

  /// Why the download stopped, when its status is [DownloadStatus.error].
  final String? error;

  /// Reconnects after dropped or stalled connections during the latest run.
  final int retryCount;

  /// Runs only during off-peak hours.
  final bool scheduled;

  const DownloadItem({
    required this.id,
    required this.name,
    this.url = '',
    this.referrer,
    required this.host,
    required this.fileType,
    required this.totalBytes,
    required this.downloadedBytes,
    required this.speedBps,
    required this.peakBps,
    required this.status,
    required this.connections,
    required this.segments,
    required this.speedHistory,
    required this.addedAt,
    this.completedAt,
    this.checksum,
    this.checksumAlgo,
    this.checksumVerified,
    this.isHls = false,
    this.segmentTotal = 0,
    this.segmentDone = 0,
    this.error,
    this.retryCount = 0,
    this.scheduled = false,
  });

  double get progress => totalBytes > 0 ? downloadedBytes / totalBytes : 0.0;

  /// Scheduled and waiting for off-peak hours to begin.
  bool get waitingForOffPeak => scheduled && status == DownloadStatus.queued;

  int? get etaSeconds {
    if (speedBps <= 0 || status != DownloadStatus.downloading) return null;
    return ((totalBytes - downloadedBytes) / speedBps).ceil();
  }

  DownloadItem copyWith({
    String? id,
    String? name,
    String? url,
    String? referrer,
    String? host,
    FileType? fileType,
    int? totalBytes,
    int? downloadedBytes,
    int? speedBps,
    int? peakBps,
    DownloadStatus? status,
    int? connections,
    List<SegmentInfo>? segments,
    List<int>? speedHistory,
    DateTime? addedAt,
    DateTime? completedAt,
    String? checksum,
    String? checksumAlgo,
    bool? checksumVerified,
    bool? isHls,
    int? segmentTotal,
    int? segmentDone,
    String? error,
    int? retryCount,
    bool? scheduled,
  }) => DownloadItem(
    id: id ?? this.id,
    name: name ?? this.name,
    url: url ?? this.url,
    referrer: referrer ?? this.referrer,
    host: host ?? this.host,
    fileType: fileType ?? this.fileType,
    totalBytes: totalBytes ?? this.totalBytes,
    downloadedBytes: downloadedBytes ?? this.downloadedBytes,
    speedBps: speedBps ?? this.speedBps,
    peakBps: peakBps ?? this.peakBps,
    status: status ?? this.status,
    connections: connections ?? this.connections,
    segments: segments ?? this.segments,
    speedHistory: speedHistory ?? this.speedHistory,
    addedAt: addedAt ?? this.addedAt,
    completedAt: completedAt ?? this.completedAt,
    checksum: checksum ?? this.checksum,
    checksumAlgo: checksumAlgo ?? this.checksumAlgo,
    checksumVerified: checksumVerified ?? this.checksumVerified,
    isHls: isHls ?? this.isHls,
    segmentTotal: segmentTotal ?? this.segmentTotal,
    segmentDone: segmentDone ?? this.segmentDone,
    error: error ?? this.error,
    retryCount: retryCount ?? this.retryCount,
    scheduled: scheduled ?? this.scheduled,
  );
}

class CompletedDownload {
  final String name;
  final String host;
  final FileType fileType;
  final int totalBytes;
  final int avgSpeedBps;
  final DateTime completedAt;

  const CompletedDownload({
    required this.name,
    required this.host,
    required this.fileType,
    required this.totalBytes,
    required this.avgSpeedBps,
    required this.completedAt,
  });
}
