import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shinsoku/src/models/download_item.dart';
import 'package:shinsoku/src/providers/downloads_provider.dart';
import 'package:shinsoku/src/ui/desktop/screens/detail_screen.dart';
import 'package:shinsoku/src/ui/desktop/widgets/download_row.dart';

/// In-memory list; records resumes instead of calling the engine.
class _FakeDownloads extends DownloadsNotifier {
  _FakeDownloads(this.items);

  final List<DownloadItem> items;
  final List<String> resumed = [];

  @override
  List<DownloadItem> build() => items;

  @override
  void resume(String id) => resumed.add(id);
}

final _failed = DownloadItem(
  id: 'a',
  name: 'ubuntu.iso',
  host: 'releases.example.com',
  fileType: FileType.iso,
  totalBytes: 1000,
  downloadedBytes: 400,
  speedBps: 0,
  peakBps: 0,
  status: DownloadStatus.error,
  connections: 8,
  segments: const [SegmentInfo(index: 0, progress: 0.4)],
  speedHistory: List.filled(60, 0),
  addedAt: DateTime(2026),
  error: 'Connection lost; gave up after 10 attempts',
  retryCount: 10,
);

void main() {
  testWidgets('a failed row shows why and offers Retry', (tester) async {
    final downloads = _FakeDownloads([_failed]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [downloadsProvider.overrideWith(() => downloads)],
        child: MaterialApp(
          home: Scaffold(
            body: DownloadRow(id: 'a', onOpen: () {}),
          ),
        ),
      ),
    );

    expect(find.textContaining('gave up after 10 attempts'), findsOneWidget);
    expect(find.byTooltip('Resume'), findsNothing);
    await tester.tap(find.byTooltip('Retry'));
    expect(downloads.resumed, ['a']);
  });

  testWidgets('a failed download detail shows the error and reconnects', (tester) async {
    tester.view.physicalSize = const Size(1400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          downloadsProvider.overrideWith(() => _FakeDownloads([_failed])),
          liveDownloadProvider.overrideWith((ref, id) => Stream.value(_failed)),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: DetailScreen(itemId: 'a', onBack: () {}),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Connection lost; gave up after 10 attempts'), findsOneWidget);
    expect(find.text('Reconnects'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Resume'), findsNothing);
  });
}
