import 'dart:io';

import 'package:flutter/services.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../models/progress_summary.dart';
import '../providers/progress_provider.dart';

/// System-tray icon + minimise-to-tray. Minimise → [hideToTray]; tray click /
/// "Show", or opening the app again while it runs → [showFromTray]; "Quit" exits.
/// While downloads run, hovering the icon shows their progress; the Linux tray
/// has no hover text, so there it heads the menu instead.
class TrayService with TrayListener implements ProgressSink {
  TrayService._();
  static final TrayService instance = TrayService._();

  /// The Windows runner calls `show` on this when the app is opened again.
  static const _instance = MethodChannel('shinsoku/instance');

  // Windows tray icon = .ico; Linux tray hosts want a .png (declared in pubspec)
  static final _iconPath = Platform.isLinux ? 'assets/icon/tray_64.png' : 'assets/icon/tray.ico';

  bool _initialized = false;
  String? _menuStatus;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    trayManager.addListener(this);
    _instance.setMethodCallHandler((call) async {
      if (call.method == 'show') await showFromTray();
    });
    await trayManager.setIcon(_iconPath);
    // the Linux tray has no tooltip; tray_manager throws there
    if (!Platform.isLinux) await trayManager.setToolTip('Shinsoku');
    await trayManager.setContextMenu(_menu());
  }

  Menu _menu() => Menu(
    items: [
      if (_menuStatus != null) ...[
        MenuItem(label: _menuStatus, disabled: true),
        MenuItem.separator(),
      ],
      MenuItem(key: 'show', label: 'Show Shinsoku'),
      MenuItem.separator(),
      MenuItem(key: 'quit', label: 'Quit'),
    ],
  );

  @override
  void show(ProgressSummary summary) {
    if (!_initialized) return;
    if (Platform.isLinux) {
      // whole percents, so the menu isn't rebuilt every second
      final p = summary.progress;
      _setMenuStatus(p == null ? summary.title : '${summary.title} · ${(p * 100).floor()}%');
    } else {
      trayManager.setToolTip('Shinsoku — ${_clip(summary.title)}\n${summary.detail}');
    }
  }

  @override
  void clear() {
    if (!_initialized) return;
    if (Platform.isLinux) {
      _setMenuStatus(null);
    } else {
      trayManager.setToolTip('Shinsoku');
    }
  }

  void _setMenuStatus(String? status) {
    if (status == _menuStatus) return;
    _menuStatus = status;
    trayManager.setContextMenu(_menu());
  }

  /// Windows cuts hover text off at 127 characters.
  static String _clip(String name) => name.length <= 60 ? name : '${name.substring(0, 59)}…';

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
