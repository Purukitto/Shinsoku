import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shinsoku/src/services/autostart_service.dart';
import 'package:win32_registry/win32_registry.dart';

void main() {
  group('Windows', () {
    // a scratch key, never the real Run key
    const root = r'Software\ShinsokuTest';
    const run = '$root\\Run';
    const approved = '$root\\Approved';
    const exe = r'C:\Apps\Shinsoku\shinsoku.exe';

    WindowsAutostart service({String path = exe}) =>
        WindowsAutostart(runPath: run, approvedPath: approved, exe: path);

    tearDown(() {
      try {
        CURRENT_USER.removeSubkey(root);
      } on Exception {
        /* never created */
      }
    });

    test('turns on and off', () {
      final s = service();
      expect(s.isEnabled(), isFalse);
      s.setEnabled(true);
      expect(s.isEnabled(), isTrue);
      final key = CURRENT_USER.open(run);
      expect(key.getString('Shinsoku'), '"$exe" --autostart');
      key.close();
      s.setEnabled(false);
      expect(s.isEnabled(), isFalse);
    });

    test('an entry disabled in Task Manager reads as off until turned on again', () {
      final s = service()..setEnabled(true);
      CURRENT_USER
          .create(approved)
          .setValue('Shinsoku', RegistryValue.binary(Uint8List.fromList([3, 0, 0, 0])));
      expect(s.isEnabled(), isFalse);
      s.setEnabled(true);
      expect(s.isEnabled(), isTrue);
    });

    test('an entry for a copy in another folder reads as off', () {
      service(path: r'D:\Old\shinsoku.exe').setEnabled(true);
      expect(service().isEnabled(), isFalse);
    });
  }, skip: !Platform.isWindows);

  group('Linux', () {
    late Directory home;
    const exe = '/opt/shinsoku/shinsoku';

    setUp(() => home = Directory.systemTemp.createTempSync('shinsoku_autostart'));
    tearDown(() => home.deleteSync(recursive: true));

    File entry() => File('${home.path}/autostart/xyz.purukitto.shinsoku.desktop');

    test('writes and removes an autostart entry', () {
      final s = LinuxAutostart(configHome: home.path, exe: exe);
      expect(s.isEnabled(), isFalse);
      s.setEnabled(true);
      expect(s.isEnabled(), isTrue);
      expect(entry().readAsStringSync(), contains('Exec="$exe" --autostart'));
      s.setEnabled(false);
      expect(entry().existsSync(), isFalse);
      expect(s.isEnabled(), isFalse);
    });

    test('an entry the desktop switched off reads as off', () {
      final s = LinuxAutostart(configHome: home.path, exe: exe)..setEnabled(true);
      entry().writeAsStringSync('${entry().readAsStringSync()}Hidden=true\n');
      expect(s.isEnabled(), isFalse);
    });
  });
}
