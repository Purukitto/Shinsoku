import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';
import '../../models/download_item.dart';
import '../../providers/downloads_provider.dart';
import '../../providers/settings_provider.dart';
import '../../providers/version_provider.dart';
import '../../services/tray_service.dart';
import '../../theme/colors.dart';
import '../../theme/text_styles.dart';
import '../widgets/logo.dart';
import '../widgets/s_btn.dart';
import '../widgets/segmented_control.dart';
import 'screens/active_screen.dart';
import 'screens/detail_screen.dart';
import 'screens/completed_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/empty_screen.dart';
import 'modals/add_modal.dart';

enum _DesktopView { active, detail, completed, settings, empty }

class DesktopShell extends ConsumerStatefulWidget {
  const DesktopShell({super.key});

  @override
  ConsumerState<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends ConsumerState<DesktopShell> {
  _DesktopView _view = _DesktopView.active;
  String? _selectedId;
  bool _showClipBanner = false;
  Timer? _clipTimer;
  String? _lastClip;

  @override
  void initState() {
    super.initState();
    // Poll the clipboard while monitoring is on, surfacing the capture banner
    // for each fresh link. Polling is the only option — desktop has no
    // clipboard-change event — and the platform read runs only while enabled.
    _clipTimer = Timer.periodic(const Duration(milliseconds: 1200), (_) => _pollClipboard());
    _pollClipboard();
  }

  @override
  void dispose() {
    _clipTimer?.cancel();
    super.dispose();
  }

  Future<void> _pollClipboard() async {
    if (!ref.read(settingsProvider).clipboardMonitor) {
      if (_showClipBanner) setState(() => _showClipBanner = false);
      return;
    }
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final t = data?.text?.trim() ?? '';
    if (t == _lastClip) return; // value unchanged since last seen / dismissal
    _lastClip = t;
    final isUrl =
        (t.startsWith('http://') || t.startsWith('https://')) && !t.contains(RegExp(r'\s'));
    if (mounted) setState(() => _showClipBanner = isUrl);
  }

  void _navigate(_DesktopView view) {
    setState(() {
      _view = view;
      _selectedId = null;
    });
  }

  void _openDetail(String id) {
    setState(() {
      _selectedId = id;
      _view = _DesktopView.detail;
    });
  }

  void _showAddModal({bool fromClipboard = false}) {
    setState(() => _showClipBanner = false);
    showDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.66),
      builder: (_) => AddDownloadModal(
        fromClipboard: fromClipboard,
        onStart:
            ({
              required url,
              required connections,
              required headers,
              expectedChecksum,
              required scheduled,
            }) {
              ref
                  .read(downloadsProvider.notifier)
                  .add(
                    url: url,
                    connections: connections,
                    headers: headers,
                    expectedChecksum: expectedChecksum,
                    scheduled: scheduled,
                  );
              _navigate(_DesktopView.active);
            },
        onStartStream: ({required url, required headers, title, required scheduled}) {
          ref
              .read(downloadsProvider.notifier)
              .addStream(url: url, headers: headers, title: title, scheduled: scheduled);
          _navigate(_DesktopView.active);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // Watch only the derived count (not the whole list) so the shell doesn't
    // rebuild every tick — that's what keeps the per-row provider scoping
    // effective. The selected item's name is watched only while a detail view is
    // open, and it rarely changes.
    final activeCount = ref.watch(
      downloadsProvider.select((l) => l.where((i) => i.status != DownloadStatus.completed).length),
    );
    final isEmpty = activeCount == 0;
    final selectedName = _selectedId == null
        ? null
        : ref.watch(downloadItemProvider(_selectedId!))?.name;
    final title = switch (_view) {
      _DesktopView.active => 'Downloading',
      _DesktopView.empty => 'Downloading',
      _DesktopView.detail => selectedName ?? 'Download',
      _DesktopView.completed => 'Completed',
      _DesktopView.settings => 'Settings',
    };

    return Scaffold(
      backgroundColor: c.bg0,
      body: Column(
        children: [
          // custom title bar
          _TitleBar(),
          // content area: sidebar + main
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Sidebar(
                  view: _view,
                  onNavigate: _navigate,
                  activeCount: activeCount,
                  completedCount: completedDownloads.length,
                ),
                Expanded(
                  child: Column(
                    children: [
                      // toolbar
                      _Toolbar(
                        title: title,
                        showClipBanner: _showClipBanner && _view != _DesktopView.settings,
                        onClipBannerTap: () => _showAddModal(fromClipboard: true),
                        onAddUrl: _showAddModal,
                      ),
                      // content — list screens scroll themselves (lazy); others use a page scroll
                      Expanded(
                        child: switch (_view) {
                          _DesktopView.active =>
                            isEmpty
                                ? _PageScroll(child: EmptyScreen(onAdd: _showAddModal))
                                : ActiveScreen(onOpenDetail: _openDetail),
                          _DesktopView.empty => _PageScroll(
                            child: EmptyScreen(onAdd: _showAddModal),
                          ),
                          _DesktopView.detail => _PageScroll(
                            child: DetailScreen(
                              itemId: _selectedId ?? '',
                              onBack: () => _navigate(_DesktopView.active),
                            ),
                          ),
                          _DesktopView.completed => const CompletedScreen(),
                          _DesktopView.settings => const _PageScroll(child: SettingsScreen()),
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TitleBar extends StatelessWidget {
  const _TitleBar();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: c.bg1,
        border: Border(bottom: BorderSide(color: c.line)),
      ),
      child: Row(
        children: [
          // draggable title region
          Expanded(
            child: DragToMoveArea(
              child: Container(
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.only(left: 18),
                child: Text(
                  'Shinsoku — Download Manager',
                  style: c.text.uiBase(color: c.low).copyWith(fontSize: 12.5),
                ),
              ),
            ),
          ),
          // window controls (Windows convention: right-aligned)
          const _WindowButtons(),
        ],
      ),
    );
  }
}

class _WindowButtons extends StatefulWidget {
  const _WindowButtons();

  @override
  State<_WindowButtons> createState() => _WindowButtonsState();
}

class _WindowButtonsState extends State<_WindowButtons> with WindowListener {
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    windowManager.isMaximized().then((m) {
      if (mounted) setState(() => _maximized = m);
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() => setState(() => _maximized = true);

  @override
  void onWindowUnmaximize() => setState(() => _maximized = false);

  Future<void> _toggleMaximize() async {
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _WinBtn(icon: Icons.remove_rounded, onTap: () => TrayService.instance.hideToTray()),
        _WinBtn(
          icon: _maximized ? Icons.filter_none_rounded : Icons.crop_square_rounded,
          iconSize: _maximized ? 12.5 : 14,
          onTap: _toggleMaximize,
        ),
        _WinBtn(icon: Icons.close_rounded, danger: true, onTap: () => windowManager.close()),
      ],
    );
  }
}

class _WinBtn extends StatefulWidget {
  const _WinBtn({required this.icon, required this.onTap, this.danger = false, this.iconSize = 15});

  final IconData icon;
  final VoidCallback onTap;
  final bool danger;
  final double iconSize;

  @override
  State<_WinBtn> createState() => _WinBtnState();
}

class _WinBtnState extends State<_WinBtn> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final hoverBg = widget.danger ? const Color(0xFFE13050) : c.bg3;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: 46,
          height: 44,
          color: _hover ? hoverBg : Colors.transparent,
          alignment: Alignment.center,
          child: Icon(
            widget.icon,
            size: widget.iconSize,
            color: _hover ? (widget.danger ? Colors.white : c.hi) : c.low,
          ),
        ),
      ),
    );
  }
}

/// Standard page scroll for non-list screens (detail, settings, empty).
class _PageScroll extends StatelessWidget {
  const _PageScroll({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      SingleChildScrollView(padding: const EdgeInsets.fromLTRB(24, 24, 24, 40), child: child);
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.view,
    required this.onNavigate,
    required this.activeCount,
    required this.completedCount,
  });

  final _DesktopView view;
  final void Function(_DesktopView) onNavigate;
  final int activeCount;
  final int completedCount;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isActive =
        view == _DesktopView.active || view == _DesktopView.detail || view == _DesktopView.empty;

    return Container(
      width: 232,
      decoration: BoxDecoration(
        color: c.bg1,
        border: Border(right: BorderSide(color: c.line)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(padding: const EdgeInsets.fromLTRB(6, 4, 6, 18), child: ShinsokuLogo(size: 30)),
          _NavItem(
            icon: Icons.bolt_rounded,
            label: 'Downloading',
            count: activeCount,
            active: isActive,
            accent: c.accent,
            onTap: () => onNavigate(_DesktopView.active),
          ),
          _NavItem(
            icon: Icons.check_circle_outline_rounded,
            label: 'Completed',
            count: completedCount,
            active: view == _DesktopView.completed,
            onTap: () => onNavigate(_DesktopView.completed),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 20, 8, 8),
            child: Text(
              'LIBRARY',
              style: c.text.monoXs().copyWith(fontSize: 10, letterSpacing: 0.14 * 10),
            ),
          ),
          _NavItem(
            icon: Icons.videocam_outlined,
            label: 'Video',
            count: 5,
            active: false,
            onTap: () => onNavigate(_DesktopView.completed),
          ),
          _NavItem(
            icon: Icons.download_outlined,
            label: 'Applications',
            count: 3,
            active: false,
            onTap: () => onNavigate(_DesktopView.completed),
          ),
          _NavItem(
            icon: Icons.folder_zip_outlined,
            label: 'Archives',
            count: 4,
            active: false,
            onTap: () => onNavigate(_DesktopView.completed),
          ),
          _NavItem(
            icon: Icons.music_note_outlined,
            label: 'Music & Audio',
            count: 2,
            active: false,
            onTap: () => onNavigate(_DesktopView.completed),
          ),
          const Spacer(),
          // storage widget
          Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: c.bg0,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: c.line),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('STORAGE', style: c.text.monoXs().copyWith(fontSize: 10.5)),
                    Text('248 GB free', style: c.text.monoXs().copyWith(fontSize: 10.5)),
                  ],
                ),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(5),
                  child: LinearProgressIndicator(
                    value: 0.62,
                    minHeight: 5,
                    backgroundColor: c.bg3,
                    valueColor: AlwaysStoppedAnimation(c.lineHi),
                  ),
                ),
              ],
            ),
          ),
          _NavItem(
            icon: Icons.settings_outlined,
            label: 'Settings',
            active: view == _DesktopView.settings,
            onTap: () => onNavigate(_DesktopView.settings),
          ),
          const _VersionFooter(),
        ],
      ),
    );
  }
}

/// Bottom-of-sidebar version line; turns into an "Update available" prompt when a
/// newer GitHub release is found. Own ConsumerWidget so the check doesn't rebuild
/// the sidebar.
class _VersionFooter extends ConsumerWidget {
  const _VersionFooter();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final update = ref.watch(updateProvider).value;
    if (update != null) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: GestureDetector(
          onTap: () => launchUrl(Uri.parse(update.url), mode: LaunchMode.externalApplication),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
            decoration: BoxDecoration(
              gradient: c.accentSoftGradient,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: c.accent.withValues(alpha: 0.28)),
            ),
            child: Row(
              children: [
                Icon(Icons.arrow_circle_up_rounded, size: 16, color: c.accent),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    'Update available',
                    style: c.text.uiBase().copyWith(fontSize: 12.5, fontWeight: FontWeight.w500),
                  ),
                ),
                Text('v${update.latest}', style: c.text.monoXs(color: c.accent)),
              ],
            ),
          ),
        ),
      );
    }
    final version = ref.watch(appVersionProvider).value;
    if (version == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 10, left: 9),
      child: Text('v$version', style: c.text.monoXs()),
    );
  }
}

class _NavItem extends StatefulWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
    this.count,
    this.accent,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;
  final int? count;
  final Color? accent;

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          height: 38,
          margin: const EdgeInsets.symmetric(vertical: 1),
          padding: const EdgeInsets.only(left: 9, right: 12),
          decoration: BoxDecoration(
            color: widget.active ? c.bg3 : (_hovered ? c.bg2 : Colors.transparent),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              // active accent indicator — reserves its space when inactive so icons stay aligned
              Container(
                width: 3,
                height: 18,
                decoration: BoxDecoration(
                  gradient: widget.active ? c.accentGradient : null,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 10),
              Icon(widget.icon, size: 17, color: widget.active ? (widget.accent ?? c.hi) : c.low),
              const SizedBox(width: 11),
              Expanded(
                child: Text(
                  widget.label,
                  style: c.text
                      .uiBase(color: widget.active ? c.hi : c.mid)
                      .copyWith(fontWeight: widget.active ? FontWeight.w500 : FontWeight.w400),
                ),
              ),
              if (widget.count != null)
                Text(
                  '${widget.count}',
                  style: c.text
                      .monoSm(color: widget.active ? c.mid : c.faint)
                      .copyWith(fontSize: 11),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.title,
    required this.showClipBanner,
    required this.onClipBannerTap,
    required this.onAddUrl,
  });

  final String title;
  final bool showClipBanner;
  final VoidCallback onClipBannerTap;
  final VoidCallback onAddUrl;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.line)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(title, style: c.text.uiLg(), overflow: TextOverflow.ellipsis),
          ),
          if (showClipBanner) ...[
            GestureDetector(
              onTap: onClipBannerTap,
              child: Container(
                height: 38,
                padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 0),
                decoration: BoxDecoration(
                  gradient: c.accentSoftGradient,
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(color: c.accent.withValues(alpha: 0.28)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.content_paste_rounded, size: 15, color: c.accent),
                    const SizedBox(width: 9),
                    Text(
                      'Link copied — download?',
                      style: c.text.uiBase().copyWith(fontSize: 12.5),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 12),
          ],
          const SSearchInput(width: 220),
          const SizedBox(width: 14),
          SBtn(
            kind: BtnKind.primary,
            icon: Icons.add_rounded,
            onPressed: onAddUrl,
            child: const Text('Add URL'),
          ),
        ],
      ),
    );
  }
}
