import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shinsoku/src/models/download_item.dart';
import 'package:shinsoku/src/providers/autostart_provider.dart';
import 'package:shinsoku/src/providers/capture_provider.dart';
import 'package:shinsoku/src/providers/downloads_provider.dart';
import 'package:shinsoku/src/providers/settings_provider.dart';
import 'package:shinsoku/src/rust/api.dart' as rust;
import 'package:shinsoku/src/services/autostart_service.dart';
import 'package:shinsoku/src/services/settings_service.dart';
import 'package:shinsoku/src/ui/desktop/screens/detail_screen.dart';
import 'package:shinsoku/src/ui/desktop/screens/settings_screen.dart';
import 'package:shinsoku/src/ui/desktop/widgets/download_row.dart';
import 'package:shinsoku/src/ui/widgets/s_toggle.dart';

/// In-memory list; records calls instead of making them on the engine.
class _FakeDownloads extends DownloadsNotifier {
  _FakeDownloads(this.items);

  final List<DownloadItem> items;
  final List<String> resumed = [];
  final List<(String, String)> refreshed = [];
  final List<String?> awaited = [];
  final List<(String, bool)> scheduled = [];
  String? refuseWith;
  rust.LinkWait? wait;

  @override
  List<DownloadItem> build() => items;

  @override
  void resume(String id) => resumed.add(id);

  @override
  Future<String?> refreshLink(String id, String url) async {
    refreshed.add((id, url));
    return refuseWith;
  }

  @override
  void awaitLink(String? id) => awaited.add(id);

  @override
  void setScheduled(String id, bool on) => scheduled.add((id, on));

  @override
  rust.LinkWait? linkWait() => wait;
}

/// Default settings, never pushed to the engine or written to disk.
class _FakeSettings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings();
}

/// Startup entry in memory; records what Settings asked for.
class _FakeAutostart implements AutostartService {
  bool on = false;
  final List<bool> set = [];

  @override
  bool get supported => true;

  @override
  bool isEnabled() => on;

  @override
  void setEnabled(bool v) {
    set.add(v);
    on = v;
  }
}

class _FakeCapture extends CaptureNotifier {
  _FakeCapture({required this.running});

  final bool running;

  @override
  CaptureState build() => CaptureState(enabled: running, running: running, port: 7878, token: 't');
}

Future<void> _pumpRow(WidgetTester tester, _FakeDownloads downloads, {bool capture = false}) {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  return tester.pumpWidget(
    ProviderScope(
      overrides: [
        downloadsProvider.overrideWith(() => downloads),
        captureProvider.overrideWith(() => _FakeCapture(running: capture)),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: DownloadRow(id: 'a', onOpen: () {}),
        ),
      ),
    ),
  );
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

final _waiting = _failed.copyWith(status: DownloadStatus.queued, scheduled: true);

final _paused = _failed.copyWith(status: DownloadStatus.paused);

Future<void> _pumpDetail(WidgetTester tester, _FakeDownloads downloads, DownloadItem item) async {
  tester.view.physicalSize = const Size(1400, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        downloadsProvider.overrideWith(() => downloads),
        settingsProvider.overrideWith(_FakeSettings.new),
        liveDownloadProvider.overrideWith((ref, id) => Stream.value(item)),
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
}

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
    expect(find.text('Refresh link'), findsOneWidget);
  });

  testWidgets('a refused link keeps the dialog open and says why', (tester) async {
    final downloads = _FakeDownloads([_failed])
      ..refuseWith = 'That link is a different file (2.0 GB; this download is 1000 B)';
    await _pumpRow(tester, downloads);

    await tester.tap(find.byTooltip('Refresh link'));
    await tester.pump();
    expect(find.textContaining('Turn on Browser integration'), findsOneWidget);

    const link = 'https://mirror.example.com/ubuntu.iso';
    await tester.enterText(find.byType(TextField), link);
    await tester.pump();
    await tester.tap(find.text('Refresh and resume'));
    await tester.pump();

    expect(downloads.refreshed, [('a', link)]);
    expect(find.text(downloads.refuseWith!), findsOneWidget);
    expect(find.text('Refresh and resume'), findsOneWidget);
    expect(downloads.awaited, isEmpty);
  });

  testWidgets('a link caught from the browser closes the dialog', (tester) async {
    final downloads = _FakeDownloads([_failed])..wait = const rust.LinkWait(id: 'a');
    await _pumpRow(tester, downloads, capture: true);

    // closing the dialog stops the wait
    await tester.tap(find.byTooltip('Refresh link'));
    await tester.pump();
    expect(downloads.awaited, ['a']);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(downloads.awaited, ['a', null]);

    await tester.tap(find.byTooltip('Refresh link'));
    await tester.pump();
    expect(find.text('Waiting for your browser…'), findsOneWidget);

    downloads.wait = const rust.LinkWait(id: 'a', error: 'Expected a file download, not a stream');
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.text('Expected a file download, not a stream'), findsOneWidget);

    downloads.wait = null;
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();
    expect(find.text('Refresh and resume'), findsNothing);
    // the engine stopped waiting itself when it took the link
    expect(downloads.awaited, ['a', null, 'a']);
  });

  testWidgets('a scheduled row waits for off-peak hours and can start now', (tester) async {
    final downloads = _FakeDownloads([_waiting]);
    await _pumpRow(tester, downloads);

    expect(find.text('SCHEDULED'), findsOneWidget);
    expect(find.textContaining('waiting for off-peak hours'), findsOneWidget);
    expect(find.byTooltip('Resume'), findsNothing);
    await tester.tap(find.byTooltip('Start now'));
    expect(downloads.scheduled, [('a', false)]);
  });

  testWidgets('a waiting download detail shows its hours and starts now', (tester) async {
    final downloads = _FakeDownloads([_waiting]);
    await _pumpDetail(tester, downloads, _waiting);

    expect(find.text('Off-peak hours, 23:00–07:00'), findsOneWidget);
    expect(find.text('Resume'), findsNothing);
    expect(find.text('Unschedule'), findsNothing);
    await tester.tap(find.text('Start now'));
    expect(downloads.scheduled, [('a', false)]);
  });

  testWidgets('a paused download can be scheduled', (tester) async {
    final downloads = _FakeDownloads([_paused]);
    await _pumpDetail(tester, downloads, _paused);

    expect(find.text('Resume'), findsOneWidget);
    await tester.tap(find.text('Schedule'));
    expect(downloads.scheduled, [('a', true)]);
  });

  testWidgets('Settings turns starting at sign-in on and off', (tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final autostart = _FakeAutostart();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith(_FakeSettings.new),
          captureProvider.overrideWith(() => _FakeCapture(running: false)),
          autostartServiceProvider.overrideWithValue(autostart),
        ],
        child: const MaterialApp(
          home: Scaffold(body: SingleChildScrollView(child: SettingsScreen())),
        ),
      ),
    );

    final label = Platform.isWindows ? 'Start with Windows' : 'Start when you sign in';
    final toggle = find.descendant(
      of: find.ancestor(of: find.text(label), matching: find.byType(Row)).first,
      matching: find.byType(SToggle),
    );
    expect(tester.widget<SToggle>(toggle).value, isFalse);
    await tester.tap(toggle);
    await tester.pump();
    expect(autostart.set, [true]);
    expect(tester.widget<SToggle>(toggle).value, isTrue);
    await tester.tap(toggle);
    await tester.pump();
    expect(autostart.set, [true, false]);
    expect(tester.widget<SToggle>(toggle).value, isFalse);
  });
}
