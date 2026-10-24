import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/download_item.dart';
import '../../models/format.dart';
import '../../providers/downloads_provider.dart';
import '../../theme/colors.dart';
import '../../theme/text_styles.dart';
import '../desktop/widgets/status_label.dart';
import '../widgets/ext_chip.dart';
import '../widgets/s_btn.dart';
import '../widgets/volt_bar.dart';

/// A download in the phone list. Tapping opens its page, which holds the rarer
/// actions; the one button here pauses, resumes or retries.
class MobileDownloadRow extends ConsumerWidget {
  const MobileDownloadRow({super.key, required this.id, required this.onOpen});

  final String id;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    // Watch only this row's item, as the desktop row does.
    final it = ref.watch(downloadItemProvider(id));
    if (it == null) return const SizedBox.shrink();
    final notifier = ref.read(downloadsProvider.notifier);

    final p = it.progress;
    final active = it.status == DownloadStatus.downloading;
    final failed = it.status == DownloadStatus.error;
    final eta = it.etaSeconds;

    final action = switch (it.status) {
      DownloadStatus.downloading => (Icons.pause_rounded, 'Pause', () => notifier.pause(it.id)),
      _ when it.waitingForOffPeak => (
        Icons.play_arrow_rounded,
        'Start now',
        () => notifier.setScheduled(it.id, false),
      ),
      DownloadStatus.paused ||
      DownloadStatus.queued => (Icons.play_arrow_rounded, 'Resume', () => notifier.resume(it.id)),
      DownloadStatus.error => (Icons.refresh_rounded, 'Retry', () => notifier.resume(it.id)),
      DownloadStatus.completed => null,
    };

    return GestureDetector(
      onTap: onOpen,
      behavior: HitTestBehavior.opaque,
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: c.bg1,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: c.line),
        ),
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      ExtChip(name: it.name, type: it.fileType, size: 40, active: active),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(it.name, style: c.text.uiMd(), overflow: TextOverflow.ellipsis),
                            const SizedBox(height: 5),
                            StatusLabel(item: it),
                          ],
                        ),
                      ),
                      if (action != null)
                        SIconBtn(
                          icon: action.$1,
                          size: 40,
                          tooltip: action.$2,
                          onPressed: action.$3,
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: VoltBar(value: p, dim: !active),
                  ),
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            failed
                                ? it.error ?? 'Failed'
                                : '${fmtBytes(it.downloadedBytes)} / ${fmtBytes(it.totalBytes)}'
                                      '${it.waitingForOffPeak ? '  ·  waiting for off-peak' : ''}',
                            style: c.text.monoSm(color: failed ? c.danger : null),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          '${fmtPct(p)}${active && eta != null ? "  ·  ${fmtEta(eta)}" : ""}',
                          style: c.text.monoSm(color: active ? c.mid : c.low),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            // active accent strip, as on desktop
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              child: Container(
                width: 3,
                decoration: BoxDecoration(gradient: active ? c.accentGradient : null),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
