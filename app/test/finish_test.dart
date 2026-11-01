import 'package:flutter_test/flutter_test.dart';
import 'package:shinsoku/src/models/download_item.dart';
import 'package:shinsoku/src/models/finish_notice.dart';
import 'package:shinsoku/src/providers/finish_provider.dart';
import 'package:shinsoku/src/services/desktop_notices.dart';
import 'package:shinsoku/src/services/settings_service.dart';

const _mb = 1024 * 1024;
final _launch = DateTime(2026, 11, 1, 12);

DownloadItem _item(
  String name,
  DownloadStatus status, {
  int total = 100 * _mb,
  String? error,
  DateTime? completedAt,
}) => DownloadItem(
  id: name,
  name: name,
  path: '/downloads/$name',
  host: 'example.com',
  fileType: FileType.unknown,
  totalBytes: total,
  downloadedBytes: status == DownloadStatus.completed ? total : 0,
  speedBps: 0,
  peakBps: 0,
  status: status,
  connections: 8,
  segments: const [],
  speedHistory: const [],
  addedAt: DateTime(2026),
  completedAt: completedAt,
  error: error,
);

/// Records the notices the reporter passes on.
class _Sink implements FinishSink {
  final notices = <String>[];

  @override
  void notify(FinishNotice notice) => notices.add('${notice.title}: ${notice.body}');
}

/// Lets the reporter's zero delay run out.
Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 1));

void main() {
  group('FinishNotice', () {
    test('one finished download names the file and its size', () {
      final n = FinishNotice([_item('ubuntu.iso', DownloadStatus.completed)], failed: false);
      expect(n.title, 'ubuntu.iso');
      expect(n.body, 'Download complete · 100 MB');
    });

    test('a size never learned is left out', () {
      final n = FinishNotice([_item('a', DownloadStatus.completed, total: 0)], failed: false);
      expect(n.body, 'Download complete');
    });

    test('one failed download says why', () {
      final n = FinishNotice([
        _item('a.zip', DownloadStatus.error, error: 'Disk full'),
      ], failed: true);
      expect(n.title, 'a.zip');
      expect(n.body, 'Download failed · Disk full');
    });

    test('several are counted and named', () {
      final n = FinishNotice([
        for (final name in ['a', 'b', 'c']) _item(name, DownloadStatus.completed),
      ], failed: false);
      expect(n.title, '3 downloads complete');
      expect(n.body, 'a, b and c');
      expect(FinishNotice.names(['a', 'b']), 'a and b');
      expect(FinishNotice.names(['a', 'b', 'c', 'd', 'e']), 'a, b and 3 more');
    });

    test('finished and failed ones get a notice each', () {
      final notices = FinishNotice.of([
        _item('a', DownloadStatus.completed),
        _item('b', DownloadStatus.error),
        _item('c', DownloadStatus.completed),
        _item('d', DownloadStatus.paused),
      ]);
      expect(notices.map((n) => n.title), ['2 downloads complete', 'b']);
      expect(notices.last.failed, isTrue);
    });

    test('the same download keeps its key, clear of the progress notification', () {
      final failed = FinishNotice([_item('a', DownloadStatus.error)], failed: true);
      final done = FinishNotice([_item('a', DownloadStatus.completed)], failed: false);
      expect(failed.key, done.key);
      expect(done.key, greaterThan(1));
    });
  });

  group('FinishReporter', () {
    late _Sink sink;
    late FinishReporter reporter;

    setUp(() {
      sink = _Sink();
      reporter = FinishReporter(sink, since: _launch, delay: Duration.zero);
    });
    tearDown(() => reporter.dispose());

    test('downloads already done at launch are not news', () async {
      reporter.update([
        _item('old.iso', DownloadStatus.completed, completedAt: DateTime(2026, 10)),
        _item('broken.zip', DownloadStatus.error),
      ]);
      await _settle();
      expect(sink.notices, isEmpty);
    });

    test('a download that finishes is announced once', () async {
      reporter.update([_item('a', DownloadStatus.downloading)]);
      reporter.update([_item('a', DownloadStatus.completed)]);
      reporter.update([_item('a', DownloadStatus.completed)]);
      await _settle();
      expect(sink.notices, ['a: Download complete · 100 MB']);
    });

    test('one first seen finished counts if it finished after launch', () async {
      reporter.update([
        _item(
          'quick',
          DownloadStatus.completed,
          completedAt: _launch.add(const Duration(minutes: 1)),
        ),
      ]);
      await _settle();
      expect(sink.notices, ['quick: Download complete · 100 MB']);
    });

    test('a failure is announced with its reason', () async {
      reporter.update([_item('a', DownloadStatus.downloading)]);
      reporter.update([_item('a', DownloadStatus.error, error: 'Disk full')]);
      await _settle();
      expect(sink.notices, ['a: Download failed · Disk full']);
    });

    test('a pause is not', () async {
      reporter.update([_item('a', DownloadStatus.downloading)]);
      reporter.update([_item('a', DownloadStatus.paused)]);
      await _settle();
      expect(sink.notices, isEmpty);
    });

    test('a burst that ends together makes one notification', () async {
      reporter.update([
        for (final n in ['a', 'b', 'c']) _item(n, DownloadStatus.downloading),
      ]);
      reporter.update([
        _item('a', DownloadStatus.completed),
        _item('b', DownloadStatus.downloading),
        _item('c', DownloadStatus.downloading),
      ]);
      reporter.update([
        for (final n in ['a', 'b', 'c']) _item(n, DownloadStatus.completed),
      ]);
      await _settle();
      expect(sink.notices, ['3 downloads complete: a, b and c']);
    });

    test('it names the download as it is when the notice goes out', () async {
      reporter.update([_item('video.m3u8', DownloadStatus.downloading).copyWith(id: 'x')]);
      reporter.update([_item('video.m3u8', DownloadStatus.completed).copyWith(id: 'x')]);
      reporter.update([_item('video.ts', DownloadStatus.completed).copyWith(id: 'x')]);
      await _settle();
      expect(sink.notices, ['video.ts: Download complete · 100 MB']);
    });

    test('one retried before the notice goes out drops out', () async {
      reporter.update([_item('a', DownloadStatus.downloading)]);
      reporter.update([_item('a', DownloadStatus.error)]);
      reporter.update([_item('a', DownloadStatus.queued)]);
      await _settle();
      expect(sink.notices, isEmpty);
    });

    test('turned off, nothing is announced, then or once it is back on', () async {
      reporter.enabled = false;
      reporter.update([_item('a', DownloadStatus.downloading)]);
      reporter.update([_item('a', DownloadStatus.completed)]);
      await _settle();
      reporter.enabled = true;
      reporter.update([_item('a', DownloadStatus.completed)]);
      await _settle();
      expect(sink.notices, isEmpty);
    });
  });

  group('Windows toast', () {
    test('a finished file gets Open and Show in folder, its path escaped', () {
      final xml = DesktopNotices.toastXml(
        FinishNotice([
          _item(
            'Tom & Jerry.mp4',
            DownloadStatus.completed,
          ).copyWith(path: r'C:\Videos\Tom & Jerry.mp4'),
        ], failed: false),
      );
      expect(xml, startsWith('<toast launch="show">'));
      expect(xml, contains('<text>Tom &amp; Jerry.mp4</text>'));
      expect(xml, contains(r'arguments="open|C:\Videos\Tom &amp; Jerry.mp4"'));
      expect(xml, contains(r'arguments="folder|C:\Videos\Tom &amp; Jerry.mp4"'));
    });

    test('a failure or a batch has no buttons', () {
      final failed = DesktopNotices.toastXml(
        FinishNotice([
          _item('a', DownloadStatus.error, error: 'HTTP 404 <Not Found>'),
        ], failed: true),
      );
      expect(failed, contains('<text>Download failed · HTTP 404 &lt;Not Found&gt;</text>'));
      expect(failed, isNot(contains('<actions>')));
      final batch = DesktopNotices.toastXml(
        FinishNotice([
          for (final n in ['a', 'b']) _item(n, DownloadStatus.completed),
        ], failed: false),
      );
      expect(batch, isNot(contains('<actions>')));
    });
  });

  test('notifications are on unless turned off, also from older settings files', () {
    expect(AppSettings.fromJson({}).notifyWhenDone, isTrue);
    final off = AppSettings.fromJson(const AppSettings(notifyWhenDone: false).toJson());
    expect(off.notifyWhenDone, isFalse);
  });
}
