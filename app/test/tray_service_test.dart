import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shinsoku/src/models/progress_summary.dart';
import 'package:shinsoku/src/services/tray_service.dart';

const _mb = 1024 * 1024;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'hovering the tray shows progress, then just the name once idle',
    () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('tray_manager'),
        (call) async {
          calls.add(call);
          return null;
        },
      );
      final tray = TrayService.instance;
      await tray.init();
      calls.clear();

      tray.show(
        const ProgressSummary(
          active: 1,
          running: 1,
          downloadedBytes: 45 * _mb,
          totalBytes: 100 * _mb,
          speedBps: 5 * _mb,
          name: 'ubuntu.iso',
        ),
      );
      tray.show(
        ProgressSummary(
          active: 1,
          running: 1,
          downloadedBytes: 0,
          totalBytes: 100 * _mb,
          speedBps: _mb,
          name: '${'a' * 80}.iso',
        ),
      );
      tray.clear();

      final tips = [
        for (final c in calls)
          if (c.method == 'setToolTip') (c.arguments as Map)['toolTip'] as String,
      ];
      expect(tips, [
        'Shinsoku — ubuntu.iso\n45.0% · 5.0 MB/s · 11s left',
        'Shinsoku — ${'a' * 59}…\n0.0% · 1.0 MB/s · 1m 40s left',
        'Shinsoku',
      ]);
    },
    skip: Platform.isLinux ? 'the Linux tray has no hover text' : false,
  );
}
