import 'package:flutter_test/flutter_test.dart';
import 'package:shinsoku/src/models/download_item.dart';
import 'package:shinsoku/src/models/progress_summary.dart';
import 'package:shinsoku/src/providers/progress_provider.dart';

const _mb = 1024 * 1024;

DownloadItem _item(
  String name,
  DownloadStatus status, {
  int total = 100 * _mb,
  int done = 0,
  int speed = 0,
  bool scheduled = false,
}) => DownloadItem(
  id: name,
  name: name,
  host: 'example.com',
  fileType: FileType.unknown,
  totalBytes: total,
  downloadedBytes: done,
  speedBps: speed,
  peakBps: speed,
  status: status,
  connections: 8,
  segments: const [],
  speedHistory: const [],
  addedAt: DateTime(2026),
  scheduled: scheduled,
);

/// Records what the reporter passes on.
class _Sink implements ProgressSink {
  final calls = <String>[];

  @override
  void show(ProgressSummary summary) => calls.add('show ${summary.title}: ${summary.detail}');

  @override
  void clear() => calls.add('clear');
}

void main() {
  group('ProgressSummary', () {
    test('one download names the file', () {
      final s = ProgressSummary.of([
        _item('ubuntu.iso', DownloadStatus.downloading, done: 45 * _mb, speed: 5 * _mb),
      ]);
      expect(s.title, 'ubuntu.iso');
      expect(s.detail, '45.0% · 5.0 MB/s · 11s left');
      expect(s.progress, closeTo(0.45, 1e-9));
    });

    test('several add up, and queued ones count', () {
      final s = ProgressSummary.of([
        _item('a', DownloadStatus.downloading, done: 50 * _mb, speed: 2 * _mb),
        _item('b', DownloadStatus.downloading, done: 30 * _mb, speed: 2 * _mb),
        _item('c', DownloadStatus.queued),
      ]);
      expect(s.title, '3 downloads');
      expect(s.active, 3);
      expect(s.running, 2);
      expect(s.progress, closeTo(80 / 300, 1e-9));
      expect(s.speedBps, 4 * _mb);
    });

    test('paused, failed, finished and scheduled downloads are left out', () {
      final s = ProgressSummary.of([
        _item('paused', DownloadStatus.paused, done: 10 * _mb),
        _item('failed', DownloadStatus.error),
        _item('done', DownloadStatus.completed, done: 100 * _mb),
        _item('tonight', DownloadStatus.queued, scheduled: true),
      ]);
      expect(s.isIdle, isTrue);
      expect(s, ProgressSummary.idle);
    });

    test('an unknown size leaves the total alone', () {
      final s = ProgressSummary.of([
        _item('stream', DownloadStatus.downloading, total: 0, done: 5 * _mb, speed: _mb),
      ]);
      expect(s.progress, isNull);
      expect(s.etaSeconds, isNull);
      expect(s.detail, '1.0 MB/s');
    });

    test('only queued waits to start', () {
      final s = ProgressSummary.of([_item('next', DownloadStatus.queued)]);
      expect(s.detail, 'Waiting to start');
    });
  });

  test('the reporter passes on changes only, and clears once idle', () {
    final sink = _Sink();
    final reporter = ProgressReporter(sink);
    final running = ProgressSummary.of([
      _item('ubuntu.iso', DownloadStatus.downloading, done: 45 * _mb, speed: 5 * _mb),
    ]);

    reporter.report(ProgressSummary.idle);
    reporter.report(running);
    reporter.report(running);
    reporter.report(ProgressSummary.idle);
    reporter.report(ProgressSummary.idle);

    expect(sink.calls, ['show ubuntu.iso: 45.0% · 5.0 MB/s · 11s left', 'clear']);
  });
}
