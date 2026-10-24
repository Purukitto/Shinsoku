import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../models/download_item.dart';
import '../../providers/downloads_provider.dart';
import '../../providers/version_provider.dart';
import '../../theme/colors.dart';
import '../../theme/text_styles.dart';
import '../desktop/modals/add_modal.dart';
import '../desktop/screens/completed_screen.dart';
import '../desktop/screens/detail_screen.dart';
import '../desktop/screens/empty_screen.dart';
import '../desktop/screens/settings_screen.dart';
import '../desktop/widgets/speed_hero.dart';
import '../widgets/logo.dart';
import 'mobile_download_row.dart';

enum _Tab { downloading, completed, settings }

/// The phone layout: one screen at a time, tabs along the bottom, and each
/// download's page pushed on top so the system back gesture returns.
class MobileShell extends ConsumerStatefulWidget {
  const MobileShell({super.key});

  @override
  ConsumerState<MobileShell> createState() => _MobileShellState();
}

class _MobileShellState extends ConsumerState<MobileShell> {
  _Tab _tab = _Tab.downloading;

  void _openDetail(String id) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => _DetailPage(id: id)));

  void _showAdd() {
    final downloads = ref.read(downloadsProvider.notifier);
    showDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.66),
      builder: (_) => AddDownloadModal(
        onStart:
            ({
              required url,
              required connections,
              required headers,
              expectedChecksum,
              required scheduled,
            }) {
              downloads.add(
                url: url,
                connections: connections,
                headers: headers,
                expectedChecksum: expectedChecksum,
                scheduled: scheduled,
              );
              setState(() => _tab = _Tab.downloading);
            },
        onStartStream: ({required url, required headers, title, required scheduled}) {
          downloads.addStream(url: url, headers: headers, title: title, scheduled: scheduled);
          setState(() => _tab = _Tab.downloading);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // Only the count, so the shell doesn't rebuild on every progress tick.
    final activeCount = ref.watch(
      downloadsProvider.select((l) => l.where((i) => i.status != DownloadStatus.completed).length),
    );

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value:
          (Theme.of(context).brightness == Brightness.dark
                  ? SystemUiOverlayStyle.light
                  : SystemUiOverlayStyle.dark)
              .copyWith(statusBarColor: Colors.transparent),
      child: Scaffold(
        backgroundColor: c.bg0,
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              const _Header(),
              Expanded(
                child: switch (_tab) {
                  _Tab.downloading =>
                    activeCount == 0
                        ? SingleChildScrollView(
                            padding: const EdgeInsets.all(16),
                            child: EmptyScreen(onAdd: _showAdd),
                          )
                        : _DownloadingList(onOpen: _openDetail),
                  _Tab.completed => const CompletedScreen(),
                  _Tab.settings => const SingleChildScrollView(
                    padding: EdgeInsets.fromLTRB(16, 16, 16, 32),
                    child: SettingsScreen(),
                  ),
                },
              ),
            ],
          ),
        ),
        floatingActionButton: _tab == _Tab.downloading && activeCount > 0
            ? _AddButton(onTap: _showAdd)
            : null,
        bottomNavigationBar: _BottomNav(
          tab: _tab,
          activeCount: activeCount,
          completedCount: completedDownloads.length,
          onSelect: (t) => setState(() => _tab = t),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.line)),
      ),
      child: Row(
        children: [
          ShinsokuLogo(size: 28),
          const SizedBox(width: 12),
          const Expanded(
            child: Align(alignment: Alignment.centerRight, child: _UpdateChip()),
          ),
        ],
      ),
    );
  }
}

/// The phone's counterpart of the sidebar's "Update available" line: nothing until a
/// newer GitHub release is found, then a chip that opens the release page. Its own
/// ConsumerWidget so the check doesn't rebuild the header.
class _UpdateChip extends ConsumerWidget {
  const _UpdateChip();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final update = ref.watch(updateProvider).value;
    if (update == null) return const SizedBox.shrink();
    return Semantics(
      button: true,
      label: 'Update available, version ${update.latest}',
      excludeSemantics: true,
      child: GestureDetector(
        onTap: () => launchUrl(Uri.parse(update.url), mode: LaunchMode.externalApplication),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            gradient: c.accentSoftGradient,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: c.accent.withValues(alpha: 0.28)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.arrow_circle_up_rounded, size: 16, color: c.accent),
              const SizedBox(width: 7),
              // gives way first on a narrow screen or with large text
              Flexible(
                child: Text(
                  'Update',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: c.text.uiSm().copyWith(fontWeight: FontWeight.w500),
                ),
              ),
              const SizedBox(width: 7),
              Text('v${update.latest}', style: c.text.monoXs(color: c.accent)),
            ],
          ),
        ),
      ),
    );
  }
}

class _DownloadingList extends ConsumerWidget {
  const _DownloadingList({required this.onOpen});

  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Structural changes only; each row watches its own item.
    final ids = ref.watch(visibleDownloadIdsProvider);
    return ListView.builder(
      // bottom room for the add button
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      itemCount: ids.length + 1,
      itemBuilder: (context, i) {
        if (i == 0) return const RepaintBoundary(child: SpeedHero());
        final id = ids[i - 1];
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: RepaintBoundary(
            child: MobileDownloadRow(key: ValueKey(id), id: id, onOpen: () => onOpen(id)),
          ),
        );
      },
    );
  }
}

class _DetailPage extends StatelessWidget {
  const _DetailPage({required this.id});

  final String id;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Scaffold(
      backgroundColor: c.bg0,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          child: DetailScreen(itemId: id, onBack: () => Navigator.of(context).pop()),
        ),
      ),
    );
  }
}

class _AddButton extends StatelessWidget {
  const _AddButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Semantics(
      button: true,
      label: 'Add a download',
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            gradient: c.accentGradient,
            borderRadius: BorderRadius.circular(18),
            boxShadow: [
              BoxShadow(
                color: c.accentFill[0].withValues(alpha: 0.35),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: const Icon(Icons.add_rounded, size: 26, color: Colors.white),
        ),
      ),
    );
  }
}

class _BottomNav extends StatelessWidget {
  const _BottomNav({
    required this.tab,
    required this.activeCount,
    required this.completedCount,
    required this.onSelect,
  });

  final _Tab tab;
  final int activeCount;
  final int completedCount;
  final ValueChanged<_Tab> onSelect;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      decoration: BoxDecoration(
        color: c.bg1,
        border: Border(top: BorderSide(color: c.line)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 64,
          child: Row(
            children: [
              _item(c, _Tab.downloading, Icons.bolt_rounded, 'Downloading', activeCount),
              _item(
                c,
                _Tab.completed,
                Icons.check_circle_outline_rounded,
                'Completed',
                completedCount,
              ),
              _item(c, _Tab.settings, Icons.settings_outlined, 'Settings', null),
            ],
          ),
        ),
      ),
    );
  }

  Widget _item(SColors c, _Tab t, IconData icon, String label, int? count) {
    final on = tab == t;
    return Expanded(
      child: Semantics(
        selected: on,
        button: true,
        child: GestureDetector(
          onTap: () => onSelect(t),
          behavior: HitTestBehavior.opaque,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 22, color: on ? c.accent : c.low),
              const SizedBox(height: 4),
              Text(
                count == null || count == 0 ? label : '$label  $count',
                style: c.text
                    .uiSm(color: on ? c.hi : c.mid)
                    .copyWith(fontWeight: on ? FontWeight.w500 : FontWeight.w400),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
