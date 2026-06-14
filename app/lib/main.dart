import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';
import 'src/providers/downloads_provider.dart';
import 'src/rust/frb_generated.dart';
import 'src/services/tray_service.dart';
import 'src/theme/app_theme.dart';
import 'src/ui/desktop/desktop_shell.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  await windowManager.ensureInitialized();
  await TrayService.instance.init();
  windowManager.waitUntilReadyToShow(
    const WindowOptions(
      size: Size(1240, 800),
      minimumSize: Size(900, 600),
      center: true,
      title: 'Shinsoku',
      backgroundColor: Color(0xFF141317),
      titleBarStyle: TitleBarStyle.hidden,
    ),
    () async {
      await windowManager.show();
      await windowManager.focus();
    },
  );
  runApp(const ProviderScope(child: ShinsokuApp()));
}

class ShinsokuApp extends ConsumerStatefulWidget {
  const ShinsokuApp({super.key});

  @override
  ConsumerState<ShinsokuApp> createState() => _ShinsokuAppState();
}

class _ShinsokuAppState extends ConsumerState<ShinsokuApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Pause the live simulation timers while the window is hidden/minimized;
    // keep them running while focused or merely inactive (still visible).
    final running = state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
    ref.read(downloadsProvider.notifier).setRunning(running);
    ref.read(globalSpeedHistoryProvider.notifier).setRunning(running);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Shinsoku',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      home: const DesktopShell(),
    );
  }
}
