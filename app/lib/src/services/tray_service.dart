import 'package:flutter/services.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

/// System-tray icon + minimise-to-tray. Minimise → [hideToTray]; tray click /
/// "Show", or opening the app again while it runs → [showFromTray]; "Quit" exits.
class TrayService with TrayListener {
  TrayService._();
  static final TrayService instance = TrayService._();

  /// The Windows runner calls `show` on this when the app is opened again.
  static const _instance = MethodChannel('shinsoku/instance');

  // Windows tray icon = .ico (declared in pubspec)
  static const _iconPath = 'assets/icon/tray.ico';

  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    trayManager.addListener(this);
    _instance.setMethodCallHandler((call) async {
      if (call.method == 'show') await showFromTray();
    });
    await trayManager.setIcon(_iconPath);
    await trayManager.setToolTip('Shinsoku');
    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(key: 'show', label: 'Show Shinsoku'),
          MenuItem.separator(),
          MenuItem(key: 'quit', label: 'Quit'),
        ],
      ),
    );
  }

  Future<void> hideToTray() async {
    await windowManager.setSkipTaskbar(true);
    await windowManager.hide();
  }

  Future<void> showFromTray() async {
    await windowManager.setSkipTaskbar(false);
    await windowManager.show();
    await windowManager.focus();
  }

  @override
  void onTrayIconMouseDown() => showFromTray();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        showFromTray();
      case 'quit':
        _quit();
    }
  }

  Future<void> _quit() async {
    await trayManager.destroy();
    await windowManager.destroy();
  }
}
