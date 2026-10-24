import 'package:flutter/material.dart';
import '../../../models/download_item.dart';
import '../../../models/format.dart';
import '../../../platform.dart';
import '../../../providers/downloads_provider.dart';
import '../../../theme/colors.dart';
import '../../../theme/text_styles.dart';
import '../../widgets/ext_chip.dart';
import '../../widgets/s_btn.dart';
import '../../widgets/segmented_control.dart';
import '../../widgets/pill.dart';

class CompletedScreen extends StatefulWidget {
  const CompletedScreen({super.key});

  @override
  State<CompletedScreen> createState() => _CompletedScreenState();
}

class _CompletedScreenState extends State<CompletedScreen> {
  String _view = 'list';

  @override
  Widget build(BuildContext context) {
    final data = completedDownloads;
    final totalBytes = data.fold(0, (a, d) => a + d.totalBytes);
    final compact = isCompact(context);

    return Padding(
      padding: compact
          ? const EdgeInsets.fromLTRB(16, 16, 16, 0)
          : const EdgeInsets.fromLTRB(24, 24, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('${data.length} files · ${fmtBytes(totalBytes)} total', style: SText.monoSm()),
              SSegmented<String>(
                value: _view,
                onChanged: (v) => setState(() => _view = v),
                options: const [
                  SOption(value: 'list', icon: Icons.format_list_bulleted_rounded),
                  SOption(value: 'grid', icon: Icons.grid_view_rounded),
                ],
              ),
            ],
          ),
          const SizedBox(height: 18),
          // lazy list/grid — only viewport items are built
          Expanded(child: _view == 'list' ? _buildList(data, compact) : _buildGrid(data, compact)),
        ],
      ),
    );
  }

  /// On a phone a row keeps the name and details; the speed and the buttons
  /// don't fit beside them.
  Widget _buildList(List<CompletedDownload> data, bool compact) {
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 40),
      itemCount: data.length,
      itemBuilder: (_, i) {
        final d = data[i];
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Container(
            decoration: BoxDecoration(
              color: SColors.bg1,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: SColors.line),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                ExtChip(name: d.name, type: d.fileType, size: 42),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        d.name,
                        style: SText.uiMd().copyWith(fontWeight: FontWeight.w500),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${d.host} · ${fmtBytes(d.totalBytes)} · ${timeAgo(d.completedAt)}',
                        style: SText.monoSm(),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                if (!compact) ...[
                  Pill(
                    tone: PillTone.mint,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.check_rounded, size: 11),
                        const SizedBox(width: 5),
                        Text('${fmtSpeed(d.avgSpeedBps)} avg'),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  SIconBtn(icon: Icons.open_in_new_rounded, size: 32, tooltip: 'Open'),
                  SIconBtn(icon: Icons.folder_open_rounded, size: 32, tooltip: 'Show in folder'),
                  SIconBtn(icon: Icons.more_horiz_rounded, size: 32, tooltip: 'More'),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildGrid(List<CompletedDownload> data, bool compact) {
    return GridView.builder(
      padding: const EdgeInsets.only(bottom: 40),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: compact ? 2 : 3,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: compact ? 1.25 : 1.8,
      ),
      itemCount: data.length,
      itemBuilder: (_, i) {
        final d = data[i];
        return Container(
          decoration: BoxDecoration(
            color: SColors.bg1,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: SColors.line),
          ),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  ExtChip(name: d.name, type: d.fileType, size: 48, radius: 13),
                  SIconBtn(icon: Icons.more_horiz_rounded, size: 30),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                d.name,
                style: SText.uiBase().copyWith(fontWeight: FontWeight.w500),
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 5),
              Text('${fmtBytes(d.totalBytes)} · ${timeAgo(d.completedAt)}', style: SText.monoSm()),
            ],
          ),
        );
      },
    );
  }
}
