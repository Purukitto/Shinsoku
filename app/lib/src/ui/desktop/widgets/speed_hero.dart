import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../models/download_item.dart';
import '../../../models/format.dart';
import '../../../providers/downloads_provider.dart';
import '../../../theme/colors.dart';
import '../../../theme/text_styles.dart';
import '../../widgets/speed_chart.dart';
import '../../widgets/bolt_icon.dart';

class SpeedHero extends ConsumerWidget {
  const SpeedHero({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(downloadsProvider);
    final globalHistory = ref.watch(globalSpeedHistoryProvider);
    final active = items.where((i) => i.status == DownloadStatus.downloading).toList();
    final queued = items.where((i) => i.status == DownloadStatus.queued).length;
    final total = active.fold(0, (a, i) => a + i.speedBps);
    final totalStr = fmtBytes(total).split(' ');
    final num = totalStr[0];
    final unit = totalStr.length > 1 ? totalStr[1] : '';

    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      height: 128,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: SColors.bg1,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: SColors.line),
      ),
      child: Stack(
        children: [
          // soft volt glow wash across the whole card
          const Positioned.fill(
            child: DecoratedBox(decoration: BoxDecoration(gradient: SColors.voltSoftGradient)),
          ),
          // full-bleed sparkline filling the right portion (clipped to the card radius)
          Positioned(
            left: 232,
            right: 0,
            top: 24,
            bottom: 0,
            child: SpeedChart(data: globalHistory, strokeWidth: 2.2),
          ),
          // left: speed readout (drawn over the chart)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    BoltIcon(size: 12),
                    const SizedBox(width: 7),
                    Text(
                      'TOTAL THROUGHPUT',
                      style: SText.monoXs(color: SColors.mid).copyWith(letterSpacing: 0.12 * 11),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      num,
                      style: SText.monoXl().copyWith(
                        fontSize: 38,
                        letterSpacing: -0.02 * 38,
                        height: 1,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text('$unit/s', style: SText.monoMd(color: SColors.mid).copyWith(fontSize: 16)),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Text('● ', style: TextStyle(color: SColors.voltPink, fontSize: 11)),
                    Text('${active.length} active', style: SText.monoSm()),
                    const SizedBox(width: 16),
                    Text('◷ $queued queued', style: SText.monoSm()),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
