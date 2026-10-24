import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../models/download_item.dart';
import '../../../models/format.dart';
import '../../../models/off_peak.dart';
import '../../../platform.dart';
import '../../../providers/downloads_provider.dart';
import '../../../providers/settings_provider.dart';
import '../../../theme/colors.dart';
import '../../../theme/text_styles.dart';
import '../../widgets/volt_bar.dart';
import '../../widgets/segment_bars.dart';
import '../../widgets/speed_chart.dart';
import '../../widgets/ext_chip.dart';
import '../../widgets/s_btn.dart';
import '../../widgets/bolt_icon.dart';
import '../modals/refresh_modal.dart';
import '../widgets/status_label.dart';

class DetailScreen extends ConsumerWidget {
  const DetailScreen({super.key, required this.itemId, required this.onBack});

  final String itemId;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(downloadsProvider.notifier);
    // live full item; fall back to the list item before the first poll
    final it =
        ref.watch(liveDownloadProvider(itemId)).value ?? ref.watch(downloadItemProvider(itemId));
    if (it == null) {
      return Align(
        alignment: Alignment.topLeft,
        child: GestureDetector(
          onTap: onBack,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.chevron_left_rounded, size: 16, color: SColors.mid),
              Text(
                'All downloads',
                style: SText.uiBase(color: SColors.mid).copyWith(fontSize: 13.5),
              ),
            ],
          ),
        ),
      );
    }
    final p = it.progress;
    final active = it.status == DownloadStatus.downloading;
    final failed = it.status == DownloadStatus.error;
    final eta = it.etaSeconds;
    final compact = isCompact(context);
    final meta = [
      ['Source', it.host],
      ['File type', it.isHls ? 'HLS stream' : _kindOf(it.fileType)],
      ['Destination', ref.watch(downloadDirProvider).value ?? '—'],
      if (it.isHls)
        ['Segments', '${it.segmentDone} / ${it.segmentTotal}']
      else
        ['Connections', '${it.connections} simultaneous'],
      if (it.retryCount > 0) ['Reconnects', '${it.retryCount}'],
      if (it.scheduled) ['Schedule', _offPeakLabel(ref)],
    ];

    final actions = [
      if (active)
        SBtn(
          kind: BtnKind.solid,
          icon: Icons.pause_rounded,
          onPressed: () => notifier.pause(it.id),
          child: const Text('Pause'),
        )
      else if (it.waitingForOffPeak)
        SBtn(
          kind: BtnKind.primary,
          icon: Icons.play_arrow_rounded,
          onPressed: () => notifier.setScheduled(it.id, false),
          child: const Text('Start now'),
        )
      else if (it.status != DownloadStatus.completed)
        SBtn(
          kind: BtnKind.primary,
          icon: failed ? Icons.refresh_rounded : Icons.play_arrow_rounded,
          onPressed: () => notifier.resume(it.id),
          child: Text(failed ? 'Retry' : 'Resume'),
        ),
      if (it.status != DownloadStatus.completed && !it.waitingForOffPeak)
        SBtn(
          kind: BtnKind.solid,
          icon: Icons.schedule_rounded,
          onPressed: () => notifier.setScheduled(it.id, !it.scheduled),
          child: Text(it.scheduled ? 'Unschedule' : 'Schedule'),
        ),
      if (failed || it.status == DownloadStatus.paused)
        SBtn(
          kind: BtnKind.solid,
          icon: Icons.link_rounded,
          onPressed: () => showRefreshLinkModal(context, it.id),
          child: const Text('Refresh link'),
        ),
      if (it.status == DownloadStatus.completed && isDesktop)
        SBtn(
          kind: BtnKind.solid,
          icon: Icons.folder_open_rounded,
          child: const Text('Show in folder'),
          onPressed: () {},
        ),
      SIconBtn(
        icon: Icons.delete_outline_rounded,
        size: 38,
        tooltip: 'Remove',
        onPressed: () {
          notifier.remove(it.id);
          onBack();
        },
      ),
    ];

    final title = Row(
      children: [
        ExtChip(
          name: it.name,
          type: it.fileType,
          size: compact ? 52 : 66,
          active: active,
          radius: compact ? 14 : 16,
        ),
        SizedBox(width: compact ? 14 : 18),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(it.name, style: SText.uiXl(), overflow: TextOverflow.ellipsis),
              const SizedBox(height: 8),
              Row(
                children: [
                  StatusLabel(item: it),
                  const SizedBox(width: 12),
                  Flexible(
                    child: Text(
                      '${_kindOf(it.fileType)} · ${fmtBytes(it.totalBytes)}',
                      style: SText.monoSm(),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );

    final segmentsCard = _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: Text(
                  it.isHls ? 'Stream segments' : 'Parallel acceleration',
                  style: SText.uiBase().copyWith(fontWeight: FontWeight.w500),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 10),
              _pill(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    BoltIcon(size: 10),
                    const SizedBox(width: 5),
                    Text(it.isHls ? '${it.segmentTotal} SEGMENTS' : '${it.connections}× SEGMENTS'),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (it.isHls) ...[
            SizedBox(
              height: 84,
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${it.segmentDone} / ${it.segmentTotal} segments',
                      style: SText.monoLg(
                        color: active ? SColors.voltPink : SColors.mid,
                      ).copyWith(fontSize: 20),
                    ),
                    const SizedBox(height: 12),
                    VoltBar(
                      value: it.segmentTotal > 0 ? it.segmentDone / it.segmentTotal : 0.0,
                      dim: !active,
                      height: 10,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('HLS · ${it.connections} parallel', style: SText.monoXs()),
                Text(
                  fmtPct(it.segmentTotal > 0 ? it.segmentDone / it.segmentTotal : 0.0),
                  style: SText.monoXs(),
                ),
              ],
            ),
          ] else ...[
            SizedBox(
              height: 84,
              child: SegmentBars(segments: it.segments, height: 84, paused: !active),
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('connection 1', style: SText.monoXs()),
                Text('connection ${it.connections}', style: SText.monoXs()),
              ],
            ),
          ],
        ],
      ),
    );

    final speedCard = _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Transfer rate', style: SText.uiBase().copyWith(fontWeight: FontWeight.w500)),
          const SizedBox(height: 4),
          Text(
            fmtSpeed(it.speedBps),
            style: SText.monoLg(
              color: active ? SColors.voltPink : SColors.mid,
            ).copyWith(fontSize: 22),
          ),
          const SizedBox(height: 12),
          Expanded(child: SpeedChart(data: it.speedHistory, strokeWidth: 2)),
        ],
      ),
    );

    final stats = [
      _statCell('DOWNLOADED', fmtBytes(it.downloadedBytes), sub: fmtPct(p)),
      _statCell(
        'AVG SPEED',
        it.speedHistory.isEmpty
            ? '—'
            : fmtSpeed((it.speedHistory.reduce((a, b) => a + b) / it.speedHistory.length).round()),
        sub: 'per second',
      ),
      _statCell('PEAK SPEED', fmtSpeed(it.peakBps), sub: 'per second'),
      _statCell(
        'ETA',
        active && eta != null ? fmtEta(eta) : '—',
        sub: active ? 'remaining' : it.status.name,
      ),
    ];
    Widget statRow(List<Widget> cells) =>
        Row(spacing: 12, children: [for (final c in cells) Expanded(child: c)]);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // back
        GestureDetector(
          onTap: onBack,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.chevron_left_rounded, size: 16, color: SColors.mid),
              Text(
                'All downloads',
                style: SText.uiBase(color: SColors.mid).copyWith(fontSize: 13.5),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        // header: title and actions side by side, or stacked on a phone
        if (compact) ...[
          title,
          const SizedBox(height: 14),
          Wrap(spacing: 8, runSpacing: 8, children: actions),
        ] else
          Row(
            children: [
              Expanded(child: title),
              const SizedBox(width: 16),
              Row(spacing: 8, children: actions),
            ],
          ),
        const SizedBox(height: 24),
        if (failed && it.error != null) ...[_errorCard(it.error!), const SizedBox(height: 16)],

        // big progress card
        _card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(fmtPct(p), style: SText.monoHero()),
                  const SizedBox(width: 12),
                  Flexible(
                    child: Text(
                      '${fmtBytes(it.downloadedBytes)} of ${fmtBytes(it.totalBytes)}'
                      '${active && eta != null ? "  ·  ${fmtEta(eta)} remaining" : ""}',
                      style: SText.monoSm(color: SColors.mid),
                      textAlign: TextAlign.right,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              VoltBar(value: p, dim: !active, height: 10),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // segments + speed chart side by side, or stacked on a phone
        if (compact) ...[
          segmentsCard,
          const SizedBox(height: 16),
          SizedBox(height: 190, width: double.infinity, child: speedCard),
        ] else
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(flex: 13, child: segmentsCard),
                const SizedBox(width: 16),
                Expanded(flex: 10, child: speedCard),
              ],
            ),
          ),
        const SizedBox(height: 16),

        // stat cells: one row, or two on a phone
        if (compact) ...[
          statRow(stats.sublist(0, 2)),
          const SizedBox(height: 12),
          statRow(stats.sublist(2)),
        ] else
          statRow(stats),
        const SizedBox(height: 16),

        // metadata table
        Container(
          decoration: BoxDecoration(
            color: SColors.bg1,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: SColors.line),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            children: [
              for (final (i, row) in meta.indexed)
                _metaRow(row[0], row[1], last: i == meta.length - 1),
            ],
          ),
        ),
        if (it.checksum != null) ...[const SizedBox(height: 16), _checksumCard(it)],
      ],
    );
  }

  static String _offPeakLabel(WidgetRef ref) {
    final (start, end) = ref.watch(
      settingsProvider.select((s) => (s.offPeakStartMin, s.offPeakEndMin)),
    );
    return 'Off-peak hours, ${fmtClock(start)}–${fmtClock(end)}';
  }

  static Widget _errorCard(String error) => Container(
    padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
    decoration: BoxDecoration(
      color: const Color(0x1FFF7A6B),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: const Color(0x40FF7A6B)),
    ),
    child: Row(
      children: [
        const Icon(Icons.error_outline_rounded, size: 16, color: SColors.danger),
        const SizedBox(width: 10),
        Expanded(
          child: Text(error, style: SText.uiBase(color: SColors.danger).copyWith(fontSize: 13)),
        ),
      ],
    ),
  );

  static Widget _checksumCard(DownloadItem it) {
    final algo = (it.checksumAlgo == 'md5' ? 'MD5' : 'SHA-256');
    final verified = it.checksumVerified;
    return Container(
      decoration: BoxDecoration(
        color: SColors.bg1,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: SColors.line),
      ),
      padding: const EdgeInsets.fromLTRB(20, 14, 12, 14),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      'CHECKSUM · $algo',
                      style: SText.monoXs().copyWith(letterSpacing: 0.1 * 10.5, fontSize: 10.5),
                    ),
                    if (verified != null) ...[const SizedBox(width: 10), _verifyBadge(verified)],
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  it.checksum!,
                  style: SText.monoSm(color: SColors.mid).copyWith(fontSize: 11.5),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          SIconBtn(
            icon: Icons.copy_rounded,
            size: 34,
            tooltip: 'Copy checksum',
            onPressed: () => Clipboard.setData(ClipboardData(text: it.checksum!)),
          ),
        ],
      ),
    );
  }

  static Widget _verifyBadge(bool ok) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color: ok ? const Color(0x1F7FE0B0) : const Color(0x1FFF7A6B),
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: ok ? const Color(0x407FE0B0) : const Color(0x40FF7A6B)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          ok ? Icons.verified_rounded : Icons.error_outline_rounded,
          size: 11,
          color: ok ? SColors.mint : SColors.danger,
        ),
        const SizedBox(width: 4),
        Text(
          ok ? 'VERIFIED' : 'MISMATCH',
          style: SText.monoXs(color: ok ? SColors.mint : SColors.danger).copyWith(fontSize: 10),
        ),
      ],
    ),
  );

  static Widget _card({required Widget child}) => Container(
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: SColors.bg1,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: SColors.line),
    ),
    child: child,
  );

  static Widget _pill({required Widget child}) => Container(
    height: 22,
    padding: const EdgeInsets.symmetric(horizontal: 9),
    decoration: BoxDecoration(
      color: const Color(0x1FFF63B6),
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: const Color(0x40FF63B6)),
    ),
    child: DefaultTextStyle(
      style: SText.monoSm(color: SColors.voltPink).copyWith(fontSize: 11),
      child: Row(mainAxisSize: MainAxisSize.min, children: [child]),
    ),
  );

  static Widget _statCell(String label, String value, {String? sub}) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: SColors.bg1,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: SColors.line),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: SText.monoXs().copyWith(letterSpacing: 0.1 * 10.5, fontSize: 10.5)),
        const SizedBox(height: 8),
        Text(value, style: SText.monoLg().copyWith(fontSize: 19)),
        if (sub != null) ...[
          const SizedBox(height: 3),
          Text(sub, style: SText.monoSm().copyWith(fontSize: 11)),
        ],
      ],
    ),
  );

  static Widget _metaRow(String key, String value, {bool last = false}) => Container(
    padding: const EdgeInsets.symmetric(vertical: 13),
    decoration: last
        ? null
        : BoxDecoration(
            border: Border(bottom: BorderSide(color: SColors.line)),
          ),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(key, style: SText.uiBase(color: SColors.mid).copyWith(fontSize: 13)),
        const SizedBox(width: 16),
        Flexible(
          child: Text(
            value,
            style: SText.monoBase().copyWith(fontSize: 12.5),
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.right,
          ),
        ),
      ],
    ),
  );

  static String _kindOf(FileType t) => switch (t) {
    FileType.video => 'Video',
    FileType.archive => 'Archive',
    FileType.app => 'Application',
    FileType.audio => 'Audio',
    FileType.image => 'Image',
    FileType.doc => 'Document',
    FileType.iso => 'Disk image',
    _ => 'File',
  };
}
