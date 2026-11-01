import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications_linux/flutter_local_notifications_linux.dart';

import '../models/finish_notice.dart';
import '../providers/finish_provider.dart';
import 'file_actions.dart';
import 'tray_service.dart';

/// Desktop notifications for finished downloads: a toast the Windows runner
/// shows (`windows/runner/notices.cpp`), or a freedesktop notification on
/// Linux. A finished file gets Open and Show in folder buttons; clicking the
/// notification itself brings the window back.
class DesktopNotices implements FinishSink {
  DesktopNotices._();
  static final DesktopNotices instance = DesktopNotices._();

  static const _windows = MethodChannel('shinsoku/notices');
  late final _linux = Platform.isLinux ? LinuxFlutterLocalNotificationsPlugin() : null;

  /// Set up on the first notice, so a run that never shows one registers
  /// nothing with the system.
  Future<bool>? _ready;

  Future<bool> _init() async {
    if (Platform.isWindows) {
      _windows.setMethodCallHandler((call) async {
        if (call.method == 'clicked') _onClick(call.arguments as String);
      });
      return true;
    }
    try {
      return await _linux?.initialize(
            settings: LinuxInitializationSettings(
              defaultActionName: 'Show Shinsoku',
              defaultIcon: AssetsLinuxIcon('assets/icon/shinsoku_1024.png'),
            ),
            onDidReceiveNotificationResponse: (r) =>
                _onClick(r.actionId == null ? 'show' : '${r.actionId}|${r.payload}'),
          ) ??
          false;
    } on Object {
      // no notification service on the session bus
      return false;
    }
  }

  @override
  Future<void> notify(FinishNotice notice) async {
    if (!await (_ready ??= _init())) return;
    final file = _file(notice);
    try {
      if (Platform.isWindows) {
        await _windows.invokeMethod<bool>('show', {
          'xml': toastXml(notice),
          'tag': '${notice.key}',
        });
      } else if (_linux case final l?) {
        await l.show(
          id: notice.key,
          title: notice.title,
          body: notice.body,
          payload: file,
          notificationDetails: LinuxNotificationDetails(
            category: notice.failed
                ? LinuxNotificationCategory.transferError
                : LinuxNotificationCategory.transferComplete,
            actions: [
              if (file != null) ...const [
                LinuxNotificationAction(key: 'open', label: 'Open'),
                LinuxNotificationAction(key: 'folder', label: 'Show in folder'),
              ],
            ],
          ),
        );
      }
    } on Object {
      // a notification that can't be shown is only a missed notice
    }
  }

  /// The file a notice offers to open: one finished download's.
  static String? _file(FinishNotice notice) => notice.failed ? null : notice.single?.path;

  /// What Windows shows. Clicking hands back `launch`, or the button's
  /// `arguments`.
  @visibleForTesting
  static String toastXml(FinishNotice notice) {
    final file = _file(notice);
    final xml = StringBuffer('<toast launch="show"><visual><binding template="ToastGeneric">')
      ..write('<text>${_escape(notice.title)}</text>')
      ..write('<text>${_escape(notice.body)}</text>')
      ..write('</binding></visual>');
    if (file != null) {
      xml
        ..write('<actions>')
        ..write('<action content="Open" arguments="${_escape('open|$file')}"/>')
        ..write('<action content="Show in folder" arguments="${_escape('folder|$file')}"/>')
        ..write('</actions>');
    }
    return (xml..write('</toast>')).toString();
  }

  static String _escape(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');

  /// "show", or "open|path" and "folder|path" from a button.
  static void _onClick(String arguments) {
    final cut = arguments.indexOf('|');
    final path = cut < 0 ? '' : arguments.substring(cut + 1);
    switch (cut < 0 ? arguments : arguments.substring(0, cut)) {
      case 'open':
        FileActions.open(path);
      case 'folder':
        FileActions.showInFolder(path);
      default:
        TrayService.instance.showFromTray();
    }
  }
}
