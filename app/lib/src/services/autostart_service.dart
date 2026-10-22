import 'dart:io';

import 'package:win32_registry/win32_registry.dart';

/// Opening Shinsoku, hidden in the tray, when the user signs in, so scheduled
/// downloads run without anyone opening it. The operating system holds the
/// setting rather than `settings.json`, so turning it off in Task Manager or
/// the desktop's startup apps shows here too.
abstract class AutostartService {
  /// Flag the startup entry launches with; the app then starts hidden.
  static const flag = '--autostart';

  factory AutostartService.forPlatform() {
    if (Platform.isWindows) return WindowsAutostart();
    if (Platform.isLinux) return LinuxAutostart();
    return const _Unsupported();
  }

  bool get supported;

  /// Whether signing in starts this copy of the app.
  bool isEnabled();

  void setEnabled(bool on);
}

/// The per-user `Run` key. Task Manager's **Disable** leaves the entry in place
/// and marks it in `StartupApproved\Run`, so that mark counts as off, and
/// turning it on here clears it.
class WindowsAutostart implements AutostartService {
  WindowsAutostart({
    this.runPath = r'Software\Microsoft\Windows\CurrentVersion\Run',
    this.approvedPath = r'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run',
    String? exe,
  }) : exe = exe ?? Platform.resolvedExecutable;

  static const _name = 'Shinsoku';

  final String runPath;
  final String approvedPath;
  final String exe;

  String get _command => '"$exe" ${AutostartService.flag}';

  @override
  bool get supported => true;

  @override
  bool isEnabled() {
    // an entry left by a copy in another folder doesn't start this one
    final command = _read(runPath, (k) => k.getString(_name));
    if (command == null || command.toLowerCase() != _command.toLowerCase()) return false;
    // the first byte is odd while the entry is disabled
    final approved = _read(approvedPath, (k) => k.getBinary(_name));
    return approved == null || approved.isEmpty || approved.first.isEven;
  }

  @override
  void setEnabled(bool on) {
    final run = CURRENT_USER.create(runPath);
    try {
      if (on) {
        run.setValue(_name, RegistryValue.string(_command));
      } else if (run.getValue(_name) != null) {
        run.removeValue(_name);
      }
    } finally {
      run.close();
    }
    final RegistryKey approved;
    try {
      approved = CURRENT_USER.open(
        approvedPath,
        config: const RegistryOpenConfig(access: RegistryAccess.readWrite),
      );
    } on Exception {
      return; // nothing ever marked
    }
    try {
      if (approved.getValue(_name) != null) approved.removeValue(_name);
    } finally {
      approved.close();
    }
  }

  /// Runs [read] on the key at [path], or returns null when there is no key.
  static T? _read<T>(String path, T? Function(RegistryKey key) read) {
    final RegistryKey key;
    try {
      key = CURRENT_USER.open(path);
    } on Exception {
      return null;
    }
    try {
      return read(key);
    } finally {
      key.close();
    }
  }
}

/// An XDG autostart entry, which GNOME, KDE and most other desktops read.
class LinuxAutostart implements AutostartService {
  LinuxAutostart({String? configHome, String? exe})
    : configHome = configHome ?? _defaultConfigHome(),
      exe = exe ?? Platform.resolvedExecutable;

  final String configHome;
  final String exe;

  static String _defaultConfigHome() {
    final xdg = Platform.environment['XDG_CONFIG_HOME'];
    if (xdg != null && xdg.isNotEmpty) return xdg;
    return '${Platform.environment['HOME']}/.config';
  }

  File get _entry => File('$configHome/autostart/xyz.purukitto.shinsoku.desktop');

  String get _exec => 'Exec="$exe" ${AutostartService.flag}';

  @override
  bool get supported => true;

  @override
  bool isEnabled() {
    if (!_entry.existsSync()) return false;
    final lines = _entry.readAsLinesSync().map((l) => l.trim()).toSet();
    // desktops that switch an entry off rather than delete it set one of these
    return lines.contains(_exec) &&
        !lines.contains('Hidden=true') &&
        !lines.contains('X-GNOME-Autostart-enabled=false');
  }

  @override
  void setEnabled(bool on) {
    if (on) {
      _entry.parent.createSync(recursive: true);
      _entry.writeAsStringSync(
        '[Desktop Entry]\n'
        'Type=Application\n'
        'Name=Shinsoku\n'
        '$_exec\n'
        'X-GNOME-Autostart-enabled=true\n',
      );
    } else if (_entry.existsSync()) {
      _entry.deleteSync();
    }
  }
}

class _Unsupported implements AutostartService {
  const _Unsupported();

  @override
  bool get supported => false;

  @override
  bool isEnabled() => false;

  @override
  void setEnabled(bool on) {}
}
