import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../providers/downloads_provider.dart';
import '../widgets/download_row.dart';
import '../widgets/speed_hero.dart';

class ActiveScreen extends ConsumerWidget {
  const ActiveScreen({
    super.key,
    required this.onOpenDetail,
  });

  final ValueChanged<String> onOpenDetail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Only the ordered id list — this rebuilds on structural changes, not on
    // every progress tick. Each row watches its own item by id.
    final ids = ref.watch(visibleDownloadIdsProvider);

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 40),
      itemCount: ids.length + 1,
      itemBuilder: (context, i) {
        // index 0 is the throughput hero (it watches its own data)
        if (i == 0) return const RepaintBoundary(child: SpeedHero());
        final id = ids[i - 1];
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: RepaintBoundary(
            child: DownloadRow(
              key: ValueKey(id),
              id: id,
              onOpen: () => onOpenDetail(id),
            ),
          ),
        );
      },
    );
  }
}
