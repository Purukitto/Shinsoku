import 'package:flutter/material.dart';
import '../../../models/download_item.dart';
import '../../../models/format.dart';
import '../../widgets/pill.dart';
import '../../widgets/bolt_icon.dart';

class StatusLabel extends StatelessWidget {
  const StatusLabel({super.key, required this.item});
  final DownloadItem item;

  @override
  Widget build(BuildContext context) {
    return switch (item.status) {
      DownloadStatus.queued  => const Pill(child: Text('QUEUED')),
      DownloadStatus.paused  => Pill(tone: PillTone.amber, child: const Text('PAUSED')),
      DownloadStatus.completed => Pill(tone: PillTone.mint, child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [const Icon(Icons.check_rounded, size: 12), const SizedBox(width: 5), const Text('DONE')])),
      DownloadStatus.error   => const Pill(child: Text('ERROR')),
      DownloadStatus.downloading => Pill(tone: PillTone.volt, child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [BoltIcon(size: 11), const SizedBox(width: 5), Text(fmtSpeed(item.speedBps))])),
    };
  }
}
