import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../models/download_item.dart';
import '../../../models/format.dart';
import '../../../providers/downloads_provider.dart';
import '../../../theme/colors.dart';
import '../../../theme/text_styles.dart';
import '../../widgets/volt_bar.dart';
import '../../widgets/ext_chip.dart';
import '../../widgets/s_btn.dart';
import '../modals/refresh_modal.dart';
import 'status_label.dart';

class DownloadRow extends ConsumerStatefulWidget {
  const DownloadRow({super.key, required this.id, required this.onOpen});

  final String id;
  final VoidCallback onOpen;

  @override
  ConsumerState<DownloadRow> createState() => _DownloadRowState();
}

class _DownloadRowState extends ConsumerState<DownloadRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // Watch only this row's item — rebuilds when its instance changes, which the
    // tick only does for the actually-downloading item.
    final it = ref.watch(downloadItemProvider(widget.id));
    if (it == null) return const SizedBox.shrink();
    final notifier = ref.read(downloadsProvider.notifier);

    final p = it.progress;
    final active = it.status == DownloadStatus.downloading;
    final failed = it.status == DownloadStatus.error;
    final eta = it.etaSeconds;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onOpen,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: _hovered ? c.bg2 : c.bg1,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: _hovered ? c.lineHi : c.line),
          ),
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(17, 15, 17, 15),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        ExtChip(name: it.name, type: it.fileType, active: active),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Text(
                            it.name,
                            style: c.text.uiMd(),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 10),
                        StatusLabel(item: it),
                        const SizedBox(width: 8),
                        // action buttons
                        Row(
                          children: [
                            if (active)
                              SIconBtn(
                                icon: Icons.pause_rounded,
                                size: 30,
                                onPressed: () => notifier.pause(it.id),
                                tooltip: 'Pause',
                              ),
                            if (it.waitingForOffPeak)
                              SIconBtn(
                                icon: Icons.play_arrow_rounded,
                                size: 30,
                                onPressed: () => notifier.setScheduled(it.id, false),
                                tooltip: 'Start now',
                              )
                            else if (it.status == DownloadStatus.paused ||
                                it.status == DownloadStatus.queued)
                              SIconBtn(
                                icon: Icons.play_arrow_rounded,
                                size: 30,
                                onPressed: () => notifier.resume(it.id),
                                tooltip: 'Resume',
                              ),
                            if (failed) ...[
                              SIconBtn(
                                icon: Icons.link_rounded,
                                size: 30,
                                onPressed: () => showRefreshLinkModal(context, it.id),
                                tooltip: 'Refresh link',
                              ),
                              SIconBtn(
                                icon: Icons.refresh_rounded,
                                size: 30,
                                onPressed: () => notifier.resume(it.id),
                                tooltip: 'Retry',
                              ),
                            ],
                            SIconBtn(
                              icon: Icons.close_rounded,
                              size: 30,
                              onPressed: () => notifier.remove(it.id),
                              tooltip: 'Remove',
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 11),
                    VoltBar(value: p, dim: !active),
                    const SizedBox(height: 9),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            failed
                                ? '${it.host}  ·  ${it.error ?? 'Failed'}'
                                : '${it.host}  ·  ${fmtBytes(it.downloadedBytes)} / ${fmtBytes(it.totalBytes)}  ·  '
                                      '${it.waitingForOffPeak ? 'waiting for off-peak hours' : '${it.connections} connections'}',
                            style: c.text.monoSm(color: failed ? c.danger : null),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Text(
                          '${fmtPct(p)}${active && eta != null ? "  ·  ${fmtEta(eta)} left" : ""}',
                          style: c.text.monoSm(color: active ? c.mid : c.low),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              // active accent strip — pinned to the left edge, height set by the
              // content (finite), clipped to the card's rounded corners
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
      ),
    );
  }
}
