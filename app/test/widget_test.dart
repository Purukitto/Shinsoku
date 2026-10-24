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
import 'package:shinsoku/src/ui/mobile/mobile_download_row.dart';
import 'package:shinsoku/src/ui/mobile/mobile_shell.dart';
import 'package:shinsoku/src/ui/widgets/s_toggle.dart';

/// In-memory list; records calls instead of making them on the engine.
class _FakeDownloads extends DownloadsNotifier {
  _FakeDownloads(this.items);

  final List<DownloadItem> items;
  final List<String> resumed = [];
  final List<String> paused = [];
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
  void pause(String id) => paused.add(id);

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

final _running = _failed.copyWith(status: DownloadStatus.downloading, speedBps: 2048);

/// A phone screen: 360 by 800 logical pixels.
void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

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

  testWidgets('Settings switches the theme', (tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith(_FakeSettings.new),
          captureProvider.overrideWith(() => _FakeCapture(running: false)),
          autostartServiceProvider.overrideWithValue(_FakeAutostart()),
        ],
        child: const MaterialApp(
          home: Scaffold(body: SingleChildScrollView(child: SettingsScreen())),
        ),
      ),
    );
    final settings = ProviderScope.containerOf(tester.element(find.byType(SettingsScreen)));
    Future<void> tapText(String text) async {
      await tester.ensureVisible(find.text(text));
      await tester.tap(find.text(text));
      await tester.pump();
    }

    expect(settings.read(settingsProvider).themeMode, ThemeMode.system);
    await tapText('Light');
    expect(settings.read(settingsProvider).themeMode, ThemeMode.light);
    expect(find.text('Pure black'), findsNothing); // dark mode only

    await tapText('Dark');
    expect(settings.read(settingsProvider).themeMode, ThemeMode.dark);
    final pureBlack = find.descendant(
      of: find.ancestor(of: find.text('Pure black'), matching: find.byType(Row)).first,
      matching: find.byType(SToggle),
    );
    await tester.tap(pureBlack);
    await tester.pump();
    expect(settings.read(settingsProvider).pureBlack, isTrue);
    // let the debounced save run out
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a phone row shows progress and pauses', (tester) async {
    _phone(tester);
    final downloads = _FakeDownloads([_running]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [downloadsProvider.overrideWith(() => downloads)],
        child: MaterialApp(
          home: Scaffold(
            body: MobileDownloadRow(id: 'a', onOpen: () {}),
          ),
        ),
      ),
    );

    expect(find.text('ubuntu.iso'), findsOneWidget);
    expect(find.textContaining('40.0%'), findsOneWidget);
    await tester.tap(find.byTooltip('Pause'));
    expect(downloads.paused, ['a']);
  });

  testWidgets('a download page fits a phone', (tester) async {
    _phone(tester);
    final downloads = _FakeDownloads([_failed]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          downloadsProvider.overrideWith(() => downloads),
          downloadDirProvider.overrideWith((ref) async => '/storage/emulated/0/Download/Shinsoku'),
          liveDownloadProvider.overrideWith((ref, id) => Stream.value(_failed)),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: DetailScreen(itemId: 'a', onBack: () {}),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // a row that overflowed would have failed the test already
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Refresh link'), findsOneWidget);
    expect(find.text('/storage/emulated/0/Download/Shinsoku'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    expect(downloads.resumed, ['a']);
  });

  testWidgets('Settings fits a phone', (tester) async {
    _phone(tester);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith(_FakeSettings.new),
          captureProvider.overrideWith(() => _FakeCapture(running: false)),
          autostartServiceProvider.overrideWithValue(_FakeAutostart()),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(padding: EdgeInsets.all(16), child: SettingsScreen()),
          ),
        ),
      ),
    );

    // sliders drop below their titles; toggles stay beside them
    final title = tester.getRect(find.text('Connections per download'));
    final slider = tester.getRect(find.text('8×'));
    expect(slider.top, greaterThan(title.bottom));
    final sortTitle = tester.getRect(find.text('Sort into category folders'));
    final sortDesc = tester.getRect(find.textContaining('subfolders of your download folder'));
    final sortToggle = tester.getRect(
      find
          .descendant(
            of: find
                .ancestor(of: find.text('Sort into category folders'), matching: find.byType(Row))
                .first,
            matching: find.byType(SToggle),
          )
          .first,
    );
    expect(sortToggle.left, greaterThan(sortTitle.left));
    expect(sortToggle.top, lessThan(sortDesc.bottom));
  });

  testWidgets('the phone shell moves between tabs and opens a download', (tester) async {
    _phone(tester);
    final downloads = _FakeDownloads([_running]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          downloadsProvider.overrideWith(() => downloads),
          settingsProvider.overrideWith(_FakeSettings.new),
          captureProvider.overrideWith(() => _FakeCapture(running: false)),
          autostartServiceProvider.overrideWithValue(_FakeAutostart()),
          downloadDirProvider.overrideWith((ref) async => '/downloads'),
          liveDownloadProvider.overrideWith((ref, id) => Stream.value(_running)),
        ],
        child: const MaterialApp(home: MobileShell()),
      ),
    );

    expect(find.text('TOTAL THROUGHPUT'), findsOneWidget);
    expect(find.text('Downloading  1'), findsOneWidget);

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('ACCELERATION'), findsOneWidget);
    expect(find.bySemanticsLabel('Add a download'), findsNothing);

    await tester.tap(find.text('Downloading  1'));
    await tester.pump();
    await tester.tap(find.text('ubuntu.iso'));
    await tester.pumpAndSettle();
    expect(find.text('All downloads'), findsOneWidget);
    expect(find.text('Pause'), findsOneWidget);

    await tester.tap(find.text('All downloads'));
    await tester.pumpAndSettle();
    expect(find.text('TOTAL THROUGHPUT'), findsOneWidget);
  });
}
