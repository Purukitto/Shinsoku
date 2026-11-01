import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:url_launcher/url_launcher.dart';

/// Opens a finished download, or shows it in the file manager, on desktop.
abstract final class FileActions {
  /// In the app the system picks for its type.
  static Future<void> open(String path) async {
    if (path.isEmpty || !await File(path).exists()) return;
    await launchUrl(Uri.file(path));
  }

  /// Selected in its folder, or the folder alone once the file has gone.
  static Future<void> showInFolder(String path) async {
    if (path.isEmpty) return;
    final dir = File(path).parent;
    if (!await File(path).exists()) {
      if (await dir.exists()) await launchUrl(Uri.directory(dir.path));
      return;
    }
    if (Platform.isWindows) {
      await Process.start('explorer.exe', ['/select,', path]);
    } else if (!await _showItems(path)) {
      await launchUrl(Uri.directory(dir.path));
    }
  }

  /// The freedesktop file manager interface, which Nautilus, Dolphin, Nemo and
  /// others answer.
  static Future<bool> _showItems(String path) async {
    final client = DBusClient.session();
    try {
      await client.callMethod(
        destination: 'org.freedesktop.FileManager1',
        path: DBusObjectPath('/org/freedesktop/FileManager1'),
        interface: 'org.freedesktop.FileManager1',
        name: 'ShowItems',
        values: [
          DBusArray.string([Uri.file(path).toString()]),
          const DBusString(''),
        ],
        replySignature: DBusSignature(''),
      );
      return true;
    } on Exception {
      // no session bus, or no file manager on it
      return false;
    } finally {
      await client.close();
    }
  }
}
