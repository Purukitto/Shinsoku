// Screenshot harness — runs the real windowed app (real fonts, real Windows
// rendering, including the CJK logo glyphs a `flutter test` renderer can't draw)
// but with every engine-backed provider swapped for a frozen mock dataset.
//
//   flutter run -t lib/main_screenshots.dart -d windows --release \
//       --dart-define=SHOT_DIR=<repo>/docs/screenshots
//
// Navigate to a screen, then press a function key to write a clean, correctly
// named, 2× PNG straight into docs/screenshots/ — no OS chrome, no cropping:
//
//   F1 hero · F2 active · F3 detail · F4 add · F5 settings · F6 completed
//
// (tool/screenshots.ps1 / tool/screenshots.sh wire up SHOT_DIR for you.)
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'src/providers/downloads_provider.dart';
import 'src/rust/frb_generated.dart';
import 'src/screenshots/mock_data.dart';
import 'src/screenshots/mock_providers.dart';
import 'src/theme/app_theme.dart';
import 'src/theme/colors.dart';
import 'src/theme/text_styles.dart';
import 'src/ui/desktop/desktop_shell.dart';

/// Output directory, injected by the runner scripts. Falls back to the repo's
/// docs/screenshots relative to the app working directory.
const String _shotDirDefine = String.fromEnvironment('SHOT_DIR');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // The Add dialog's `probe_url` is a standalone bridge call (no engine); init
  // the native lib so pasting a real URL renders a real preview card.
  await RustLib.init();

  // Seed the completed history (a plain global list the Completed screen reads).
  completedDownloads
    ..clear()
    ..addAll(mockCompleted);

  await windowManager.ensureInitialized();
  windowManager.waitUntilReadyToShow(
    const WindowOptions(
      size: Size(1240, 800),
      minimumSize: Size(900, 600),
      center: true,
      title: 'Shinsoku — Screenshot harness',
      backgroundColor: Color(0xFF141317),
      titleBarStyle: TitleBarStyle.hidden,
    ),
    () async {
      await windowManager.show();
      await windowManager.focus();
    },
  );

  runApp(ProviderScope(
    overrides: screenshotOverrides,
    child: const _ScreenshotHarness(),
  ));
}

class _ScreenshotHarness extends StatefulWidget {
  const _ScreenshotHarness();

  @override
  State<_ScreenshotHarness> createState() => _ScreenshotHarnessState();
}

class _ScreenshotHarnessState extends State<_ScreenshotHarness> {
  final GlobalKey _shotKey = GlobalKey();
  final GlobalKey<ScaffoldMessengerState> _msgKey = GlobalKey();

  // Not const: LogicalKeyboardKey overrides `==`, so it can't be a const map key.
  static final Map<LogicalKeyboardKey, String> _bindings = {
    LogicalKeyboardKey.f1: 'hero.png',
    LogicalKeyboardKey.f2: 'active.png',
    LogicalKeyboardKey.f3: 'detail.png',
    LogicalKeyboardKey.f4: 'add.png',
    LogicalKeyboardKey.f5: 'settings.png',
    LogicalKeyboardKey.f6: 'completed.png',
  };

  String get _shotDir => _shotDirDefine.isNotEmpty
      ? _shotDirDefine
      : '${Directory.current.path}/../docs/screenshots';

  @override
  void initState() {
    super.initState();
    // Global key hook — fires regardless of which widget (e.g. a focused text
    // field in the Add dialog) currently has focus.
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    final filename = _bindings[event.logicalKey];
    if (filename == null) return false;
    _capture(filename);
    return true;
  }

  Future<void> _capture(String filename) async {
    // Drop any lingering toast and wait for a clean paint so it can't leak into
    // the captured frame.
    _msgKey.currentState?.removeCurrentSnackBar();
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;

    final boundary =
        _shotKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) return;
    final image = await boundary.toImage(pixelRatio: 2.0);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final w = image.width, h = image.height;
    image.dispose();
    if (bytes == null) return;

    final dir = Directory(_shotDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final file = File('${dir.path}/$filename');
    file.writeAsBytesSync(bytes.buffer.asUint8List());

    debugPrint('[screenshot] saved ${file.path} ($w×$h)');
    _msgKey.currentState
      ?..removeCurrentSnackBar()
      ..showSnackBar(SnackBar(
        behavior: SnackBarBehavior.floating,
        width: 340,
        duration: const Duration(milliseconds: 1400),
        backgroundColor: SColors.bg3,
        content: Text('Saved  $filename   ·   $w×$h',
            style: SText.monoSm(color: SColors.hi)),
      ));
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Stack(children: [
        // Captured subtree — the whole app, dialogs included.
        Positioned.fill(
          child: RepaintBoundary(
            key: _shotKey,
            child: MaterialApp(
              title: 'Shinsoku',
              debugShowCheckedModeBanner: false,
              theme: AppTheme.dark,
              scaffoldMessengerKey: _msgKey,
              home: const DesktopShell(),
            ),
          ),
        ),
        // Operator hint — outside the RepaintBoundary, so it never appears in a
        // capture even while it overlays the running window.
        const Positioned(left: 14, bottom: 12, child: _HintBar()),
      ]),
    );
  }
}

class _HintBar extends StatelessWidget {
  const _HintBar();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xE61A191E),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: SColors.lineHi),
      ),
      child: Text(
        'F1 hero · F2 active · F3 detail · F4 add · F5 settings · F6 completed  →  docs/screenshots',
        style: SText.monoXs(color: SColors.mid),
      ),
    );
  }
}
