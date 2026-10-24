import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart' show AnyhowException;
import 'package:path_provider/path_provider.dart';
import '../models/download_item.dart';
import '../rust/api.dart' as rust;
import '../rust/engine/download.dart' as rd;

/// Single engine instance. Requires `RustLib.init()` (see main). Overridden in
/// `main()` with the persistent store path; this fallback runs in-memory.
final engineProvider = Provider<rust.ShinsokuEngine>((ref) => rust.createEngine(dbPath: ''));

/// Android side of storage (see `MainActivity.kt`).
const _storage = MethodChannel('shinsoku/storage');

/// Default dest: a Shinsoku folder in the shared Download folder on Android, the
/// OS Downloads dir on desktop, else app documents.
final downloadDirProvider = FutureProvider<String>((ref) async {
  if (Platform.isAndroid) {
    try {
      final root = await _storage.invokeMethod<String>('downloadsDir');
      final dir = await Directory('$root/Shinsoku').create(recursive: true);
      return dir.path;
    } catch (_) {
      /* shared storage unavailable: fall back to the app's own folder below */
    }
  }
  try {
    final dir = await getDownloadsDirectory();
    if (dir != null) return dir.path;
  } catch (_) {
    /* not supported on this platform */
  }
  return (await getApplicationDocumentsDirectory()).path;
});

/// Completed downloads, newest first. Repopulated on launch from the engine's
/// persisted store (see `_refresh`), so history survives restarts.
final List<CompletedDownload> completedDownloads = [];

// ── mapping: Rust types → Dart view model ─────────────────────────────────────

DownloadStatus _status(rd.DownloadStatus s) => switch (s) {
  rd.DownloadStatus.queued => DownloadStatus.queued,
  rd.DownloadStatus.downloading => DownloadStatus.downloading,
  rd.DownloadStatus.paused => DownloadStatus.paused,
  rd.DownloadStatus.completed => DownloadStatus.completed,
  rd.DownloadStatus.error => DownloadStatus.error,
};

FileType _fileType(String s) => switch (s) {
  'video' => FileType.video,
  'archive' => FileType.archive,
  'app' => FileType.app,
  'audio' => FileType.audio,
  'image' => FileType.image,
  'doc' => FileType.doc,
  'iso' => FileType.iso,
  _ => FileType.unknown,
};

double _segProgress(rd.SegmentInfo s) {
  final range = (s.endByte - s.startByte).toInt();
  if (range <= 0) return 0.0;
  return (s.downloadedBytes.toInt() / range).clamp(0.0, 1.0);
}

String? _header(List<(String, String)> headers, String name) {
  for (final (k, v) in headers) {
    if (k.toLowerCase() == name) return v;
  }
  return null;
}

DownloadItem _map(rd.DownloadItem r) => DownloadItem(
  id: r.id,
  name: r.filename,
  url: r.url,
  referrer: _header(r.headers, 'referer'),
  host: r.host,
  fileType: _fileType(r.fileType),
  totalBytes: r.totalBytes.toInt(),
  downloadedBytes: r.downloadedBytes.toInt(),
  speedBps: r.speedBps.toInt(),
  peakBps: r.peakBps.toInt(),
  status: _status(r.status),
  connections: r.connections,
  segments: r.segments.map((s) => SegmentInfo(index: s.index, progress: _segProgress(s))).toList(),
  speedHistory: r.speedHistory.map((e) => e.toInt()).toList(),
  addedAt: DateTime.fromMillisecondsSinceEpoch(r.addedAtMs),
  completedAt: r.completedAtMs == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(r.completedAtMs!),
  checksum: r.checksum,
  checksumAlgo: r.checksumAlgo,
  checksumVerified: r.checksumVerified,
  isHls: r.kind == rd.DownloadKind.hls,
  segmentTotal: r.segmentTotal,
  segmentDone: r.segmentDone,
  error: r.error,
  retryCount: r.retryCount,
  scheduled: r.scheduled,
);

// ── live download list ────────────────────────────────────────────────────────

class DownloadsNotifier extends Notifier<List<DownloadItem>> {
  StreamSubscription<rd.DownloadProgress>? _sub;
  bool _refreshScheduled = false;
  final Set<String> _recordedComplete = {};

  @override
  List<DownloadItem> build() {
    final engine = ref.watch(engineProvider);
    _sub = rust.subscribeProgress(engine: engine).listen(_onProgress);
    ref.onDispose(() => _sub?.cancel());
    _refresh();
    return const [];
  }

  /// Full sync from the engine (startup + structural changes).
  Future<void> _refresh() async {
    final engine = ref.read(engineProvider);
    final items = (await rust.getDownloads(engine: engine)).map(_map).toList();
    for (final it in items) {
      if (it.status == DownloadStatus.completed) _recordComplete(it);
    }
    state = items;
  }

  void _scheduleRefresh() {
    if (_refreshScheduled) return;
    _refreshScheduled = true;
    Future.microtask(() {
      _refreshScheduled = false;
      _refresh();
    });
  }

  void _onProgress(rd.DownloadProgress p) {
    final idx = state.indexWhere((i) => i.id == p.id);
    if (idx < 0) {
      _scheduleRefresh(); // new id → fetch full details
      return;
    }
    final cur = state[idx];
    final newStatus = _status(p.status);
    final total = p.totalBytes.toInt();
    final speed = p.speedBps.toInt();
    // status flip or size becoming known ⇒ refetch full item (name/type/segments)
    final structural = newStatus != cur.status || (cur.totalBytes == 0 && total > 0);

    final next = [...state];
    next[idx] = cur.copyWith(
      downloadedBytes: p.downloadedBytes.toInt(),
      totalBytes: total,
      speedBps: speed,
      peakBps: speed > cur.peakBps ? speed : cur.peakBps,
      status: newStatus,
    );
    state = next;

    if (newStatus == DownloadStatus.completed) _recordComplete(next[idx]);
    if (structural) _scheduleRefresh();
  }

  void _recordComplete(DownloadItem it) {
    if (_recordedComplete.add(it.id)) {
      completedDownloads.insert(
        0,
        CompletedDownload(
          name: it.name,
          host: it.host,
          fileType: it.fileType,
          totalBytes: it.totalBytes,
          avgSpeedBps: it.peakBps,
          completedAt: it.completedAt ?? DateTime.now(),
        ),
      );
    }
  }

  Future<void> add({
    required String url,
    required int connections,
    List<(String, String)> headers = const [],
    String? expectedChecksum,
    bool scheduled = false,
  }) async {
    final engine = ref.read(engineProvider);
    final dir = await ref.read(downloadDirProvider.future);
    rust.addDownload(
      engine: engine,
      url: url,
      destDir: dir,
      connections: connections,
      headers: headers,
      expectedChecksum: expectedChecksum,
      scheduled: scheduled,
    );
    _refresh();
  }

  /// Queue an HLS (M3U8) stream; the engine resolves the playlist and downloads
  /// the highest-bitrate variant. Connection count is engine-chosen.
  Future<void> addStream({
    required String url,
    List<(String, String)> headers = const [],
    String? title,
    bool scheduled = false,
  }) async {
    final engine = ref.read(engineProvider);
    final dir = await ref.read(downloadDirProvider.future);
    rust.addStream(
      engine: engine,
      url: url,
      destDir: dir,
      headers: headers,
      title: title,
      scheduled: scheduled,
    );
    _refresh();
  }

  void pause(String id) {
    rust.pauseDownload(engine: ref.read(engineProvider), id: id);
    _patchStatus(id, DownloadStatus.paused, zeroSpeed: true);
  }

  void resume(String id) {
    rust.resumeDownload(engine: ref.read(engineProvider), id: id);
    _patchStatus(id, DownloadStatus.downloading);
  }

  void remove(String id) {
    rust.removeDownload(engine: ref.read(engineProvider), id: id);
    state = state.where((i) => i.id != id).toList();
  }

  /// Run [id] only during off-peak hours, or (`on == false`) as soon as a slot
  /// is free. The engine may also change its status, so refetch it.
  void setScheduled(String id, bool on) {
    rust.setScheduled(engine: ref.read(engineProvider), id: id, on_: on);
    final idx = state.indexWhere((i) => i.id == id);
    if (idx >= 0) state = [...state]..[idx] = state[idx].copyWith(scheduled: on);
    _refresh();
  }

  /// Point a stopped download at a new link for the same file and resume it.
  /// Returns why the engine refused the link, or null once it is in use.
  Future<String?> refreshLink(String id, String url) async {
    try {
      await rust.refreshDownload(engine: ref.read(engineProvider), id: id, url: url);
    } on AnyhowException catch (e) {
      return e.message;
    }
    _refresh();
    return null;
  }

  /// While [id] is set, the next link the browser extension captures goes to
  /// that download instead of a new one.
  void awaitLink(String? id) => rust.awaitLink(engine: ref.read(engineProvider), id: id);

  /// The download waiting for a captured link; null once one has been taken.
  rust.LinkWait? linkWait() => rust.linkWait(engine: ref.read(engineProvider));

  void _patchStatus(String id, DownloadStatus s, {bool zeroSpeed = false}) {
    final idx = state.indexWhere((i) => i.id == id);
    if (idx < 0) return;
    final next = [...state];
    next[idx] = state[idx].copyWith(status: s, speedBps: zeroSpeed ? 0 : state[idx].speedBps);
    state = next;
  }

  /// No-op: engine runs independent of UI lifecycle (kept for lifecycle callers).
  void setRunning(bool running) {}
}

final downloadsProvider = NotifierProvider<DownloadsNotifier, List<DownloadItem>>(
  DownloadsNotifier.new,
);

/// Throughput sparkline; own timer so only the chart rebuilds.
class GlobalSpeedNotifier extends Notifier<List<int>> {
  Timer? _timer;
  static const _ms = 600;

  @override
  List<int> build() {
    _timer = Timer.periodic(const Duration(milliseconds: _ms), (_) => _tick());
    ref.onDispose(() => _timer?.cancel());
    return List<int>.filled(60, 0);
  }

  void setRunning(bool running) {
    if (running) {
      _timer ??= Timer.periodic(const Duration(milliseconds: _ms), (_) => _tick());
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  void _tick() {
    final sum = ref
        .read(downloadsProvider)
        .where((i) => i.status == DownloadStatus.downloading)
        .fold<int>(0, (a, i) => a + i.speedBps);
    state = [...state.skip(1), sum];
  }
}

final globalSpeedHistoryProvider = NotifierProvider<GlobalSpeedNotifier, List<int>>(
  GlobalSpeedNotifier.new,
);

int _statusOrder(DownloadStatus s) => switch (s) {
  DownloadStatus.downloading => 0,
  DownloadStatus.paused => 1,
  DownloadStatus.error => 1,
  DownloadStatus.queued => 2,
  DownloadStatus.completed => 3,
};

/// Single download by id; rows watch via `select`.
final downloadItemProvider = Provider.autoDispose.family<DownloadItem?, String>((ref, id) {
  return ref.watch(
    downloadsProvider.select((list) {
      for (final i in list) {
        if (i.id == id) return i;
      }
      return null;
    }),
  );
});

/// Ordered ids of non-completed downloads as one value-equal string, so the list
/// only rebuilds on structural changes, not every tick.
final visibleDownloadIdsProvider = Provider.autoDispose<List<String>>((ref) {
  final csv = ref.watch(
    downloadsProvider.select((list) {
      final v = list.where((i) => i.status != DownloadStatus.completed).toList()
        ..sort((a, b) => _statusOrder(a.status).compareTo(_statusOrder(b.status)));
      return v.map((i) => i.id).join(' ');
    }),
  );
  return csv.isEmpty ? const <String>[] : csv.split(' ');
});

/// Live full item for detail; polls while open, auto-disposes.
final liveDownloadProvider = StreamProvider.autoDispose.family<DownloadItem?, String>((ref, id) {
  final engine = ref.watch(engineProvider);
  late final StreamController<DownloadItem?> ctrl;
  Timer? timer;

  Future<void> poll() async {
    final it = await rust.getDownload(engine: engine, id: id);
    if (!ctrl.isClosed) ctrl.add(it == null ? null : _map(it));
  }

  ctrl = StreamController<DownloadItem?>(
    onListen: () {
      poll();
      timer = Timer.periodic(const Duration(milliseconds: 400), (_) => poll());
    },
  );
  ref.onDispose(() {
    timer?.cancel();
    ctrl.close();
  });
  return ctrl.stream;
});
