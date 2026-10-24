import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../models/format.dart';
import '../../../platform.dart';
import '../../../providers/capture_provider.dart';
import '../../../providers/downloads_provider.dart';
import '../../../theme/colors.dart';
import '../../../theme/text_styles.dart';
import '../../widgets/ext_chip.dart';
import '../../widgets/s_btn.dart';

Future<void> showRefreshLinkModal(BuildContext context, String id) => showDialog(
  context: context,
  barrierColor: Colors.black.withValues(alpha: 0.66),
  builder: (_) => RefreshLinkModal(id: id),
);

/// Gives a stopped download a fresh link for the same file: pasted, or caught
/// from the browser while the dialog is open.
class RefreshLinkModal extends ConsumerStatefulWidget {
  const RefreshLinkModal({super.key, required this.id});

  final String id;

  @override
  ConsumerState<RefreshLinkModal> createState() => _RefreshLinkModalState();
}

class _RefreshLinkModalState extends ConsumerState<RefreshLinkModal> {
  final _ctrl = TextEditingController();
  late final DownloadsNotifier _downloads = ref.read(downloadsProvider.notifier);
  Timer? _poll;
  bool _waiting = false;
  bool _busy = false;
  String? _error;
  String? _captureError;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(() => setState(() => _error = null));
    if (isDesktop && ref.read(captureProvider).running) {
      _waiting = true;
      _downloads.awaitLink(widget.id);
      _poll = Timer.periodic(const Duration(milliseconds: 600), (_) => _checkCapture());
    }
    _prefillFromClipboard();
  }

  @override
  void dispose() {
    _poll?.cancel();
    if (_waiting) _downloads.awaitLink(null);
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _prefillFromClipboard() async {
    final t = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim() ?? '';
    final current = ref.read(downloadItemProvider(widget.id))?.url;
    if (mounted && _isLink(t) && t != current && _ctrl.text.isEmpty) _ctrl.text = t;
  }

  /// The engine stops waiting once the browser's link has been taken.
  void _checkCapture() {
    final wait = _downloads.linkWait();
    if (wait == null) {
      _poll?.cancel();
      _waiting = false;
      if (mounted) Navigator.pop(context);
      return;
    }
    if (wait.error != _captureError) setState(() => _captureError = wait.error);
  }

  static bool _isLink(String t) =>
      (t.startsWith('http://') || t.startsWith('https://')) && !t.contains(RegExp(r'\s'));

  Future<void> _submit() async {
    setState(() => _busy = true);
    final error = await _downloads.refreshLink(widget.id, _ctrl.text.trim());
    if (!mounted) return;
    if (error == null) {
      Navigator.pop(context);
    } else {
      setState(() {
        _busy = false;
        _error = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final it = ref.watch(downloadItemProvider(widget.id));
    if (it == null) return const SizedBox.shrink();
    final ready = _isLink(_ctrl.text.trim()) && !_busy;
    final referrer = it.referrer;

    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        width: 540,
        decoration: BoxDecoration(
          color: c.bg2,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: c.lineHi),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.6),
              blurRadius: 80,
              offset: const Offset(0, 30),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 20, 22, 16),
              child: Row(
                children: [
                  Icon(Icons.link_rounded, size: 17, color: c.accent),
                  const SizedBox(width: 10),
                  Text('Refresh link', style: c.text.uiLg()),
                  const Spacer(),
                  SIconBtn(icon: Icons.close_rounded, onPressed: () => Navigator.pop(context)),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 0, 22, 22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: c.bg1,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: c.line),
                    ),
                    child: Row(
                      children: [
                        ExtChip(name: it.name, type: it.fileType),
                        const SizedBox(width: 13),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                it.name,
                                style: c.text.uiMd().copyWith(fontWeight: FontWeight.w500),
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 3),
                              Text(
                                '${fmtBytes(it.downloadedBytes)} of ${fmtBytes(it.totalBytes)}'
                                '  ·  ${fmtPct(it.progress)} kept',
                                style: c.text.monoSm(),
                              ),
                              if (it.error != null) ...[
                                const SizedBox(height: 3),
                                Text(
                                  it.error!,
                                  style: c.text.monoSm(color: c.danger),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (_waiting)
                    _browserPanel(referrer)
                  else if (isDesktop)
                    Text(
                      'Turn on Browser integration in Settings to catch the new link '
                      'from your browser instead.',
                      style: c.text.monoSm(color: c.low).copyWith(fontSize: 11),
                    ),
                  const SizedBox(height: 18),
                  Text(
                    'NEW LINK',
                    style: c.text.monoXs().copyWith(letterSpacing: 0.1 * 10.5, fontSize: 10.5),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    height: 44,
                    decoration: BoxDecoration(
                      color: c.bg0,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: _error != null ? c.danger.withValues(alpha: 0.5) : c.line,
                      ),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      children: [
                        Icon(Icons.link_rounded, size: 16, color: c.low),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextField(
                            controller: _ctrl,
                            autofocus: true,
                            style: c.text.monoBase().copyWith(fontSize: 12.5),
                            onSubmitted: (_) {
                              if (ready) _submit();
                            },
                            decoration: InputDecoration(
                              hintText: 'Paste a new link to the same file…',
                              hintStyle: c.text.monoBase(color: c.low).copyWith(fontSize: 12.5),
                              border: InputBorder.none,
                              isDense: true,
                              contentPadding: EdgeInsets.zero,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Text(_error!, style: c.text.monoSm(color: c.danger)),
                  ],
                  const SizedBox(height: 22),
                  Row(
                    children: [
                      Expanded(
                        child: SBtn(
                          kind: BtnKind.ghost,
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Cancel'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        flex: 2,
                        child: SBtn(
                          kind: BtnKind.primary,
                          icon: Icons.refresh_rounded,
                          disabled: !ready,
                          onPressed: ready ? _submit : null,
                          child: Text(_busy ? 'Checking link…' : 'Refresh and resume'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _browserPanel(String? referrer) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        gradient: c.accentSoftGradient,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.accent.withValues(alpha: 0.22)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Start the download again on the page it came from. Shinsoku takes the '
            'new link instead of adding a download.',
            style: c.text.uiBase().copyWith(fontSize: 13),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              if (referrer != null) ...[
                SBtn(
                  kind: BtnKind.solid,
                  size: BtnSize.sm,
                  icon: Icons.open_in_new_rounded,
                  onPressed: () =>
                      launchUrl(Uri.parse(referrer), mode: LaunchMode.externalApplication),
                  child: const Text('Open page'),
                ),
                const SizedBox(width: 12),
              ],
              if (_captureError == null) ...[
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2, color: c.accent),
                ),
                const SizedBox(width: 8),
                Text('Waiting for your browser…', style: c.text.monoSm(color: c.mid)),
              ] else
                Expanded(
                  child: Text(
                    _captureError!,
                    style: c.text.monoSm(color: c.danger),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 2,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
