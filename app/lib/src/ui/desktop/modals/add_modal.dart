import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../models/download_item.dart';
import '../../../models/format.dart';
import '../../../rust/api.dart' as rust;
import '../../../rust/engine/download.dart' as rd;
import '../../../theme/colors.dart';
import '../../../theme/text_styles.dart';
import '../../widgets/bolt_icon.dart';
import '../../widgets/ext_chip.dart';
import '../../widgets/s_btn.dart';
import '../../widgets/s_toggle.dart';
import '../../widgets/volt_slider.dart';
import '../../widgets/pill.dart';

FileType _ftype(String s) => switch (s) {
  'video' => FileType.video,
  'archive' => FileType.archive,
  'app' => FileType.app,
  'audio' => FileType.audio,
  'image' => FileType.image,
  'doc' => FileType.doc,
  'iso' => FileType.iso,
  _ => FileType.unknown,
};

String _kindLabel(FileType t) => switch (t) {
  FileType.video => 'Video',
  FileType.archive => 'Archive',
  FileType.app => 'Application',
  FileType.audio => 'Audio',
  FileType.image => 'Image',
  FileType.doc => 'Document',
  FileType.iso => 'Disk image',
  _ => 'File',
};

class AddDownloadModal extends ConsumerStatefulWidget {
  const AddDownloadModal({
    super.key,
    required this.onStart,
    required this.onStartStream,
    this.fromClipboard = false,
  });

  final void Function({
    required String url,
    required int connections,
    required List<(String, String)> headers,
    String? expectedChecksum,
  }) onStart;

  /// Routed instead of [onStart] when the link is an HLS (M3U8) stream.
  final void Function({
    required String url,
    required List<(String, String)> headers,
    String? title,
  }) onStartStream;
  final bool fromClipboard;

  @override
  ConsumerState<AddDownloadModal> createState() => _AddDownloadModalState();
}

class _AddDownloadModalState extends ConsumerState<AddDownloadModal> {
  final _ctrl = TextEditingController();
  double _conns = 8;
  bool _scheduled = false;

  // advanced: custom request headers + expected checksum
  bool _advanced = false;
  final List<(TextEditingController, TextEditingController)> _headers = [];
  final _checksumCtrl = TextEditingController();

  Timer? _debounce;
  rd.ProbeResult? _probe;
  bool _probing = false;
  String? _error;
  String _probedUrl = '';

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(_onChanged);
    if (widget.fromClipboard) _prefillFromClipboard();
  }

  Future<void> _prefillFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final t = data?.text?.trim() ?? '';
    if (mounted && (t.startsWith('http://') || t.startsWith('https://'))) {
      _ctrl.text = t; // listener fires → probe is scheduled
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    _checksumCtrl.dispose();
    for (final h in _headers) {
      h.$1.dispose();
      h.$2.dispose();
    }
    super.dispose();
  }

  List<(String, String)> _collectHeaders() {
    final out = <(String, String)>[];
    for (final h in _headers) {
      final name = h.$1.text.trim();
      if (name.isEmpty) continue;
      out.add((name, h.$2.text.trim()));
    }
    return out;
  }

  bool get _hasAdvanced =>
      _collectHeaders().isNotEmpty || _checksumCtrl.text.trim().isNotEmpty;

  Widget _advancedDisclosure() => InkWell(
    onTap: () => setState(() => _advanced = !_advanced),
    borderRadius: BorderRadius.circular(8),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Icon(_advanced ? Icons.expand_less_rounded : Icons.expand_more_rounded,
          size: 18, color: SColors.mid),
        const SizedBox(width: 6),
        Text('Advanced', style: SText.uiBase(color: SColors.mid).copyWith(fontSize: 13)),
        const Spacer(),
        if (!_advanced && _hasAdvanced)
          Text('configured', style: SText.monoXs(color: SColors.voltPink).copyWith(fontSize: 10.5)),
      ]),
    ),
  );

  Widget _advancedSection() => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('REQUEST HEADERS', style: SText.monoXs().copyWith(letterSpacing: 0.1 * 10.5, fontSize: 10.5)),
      const SizedBox(height: 4),
      Text('Sent with every request — e.g. Cookie, Referer, Authorization.',
        style: SText.monoSm(color: SColors.low).copyWith(fontSize: 11)),
      const SizedBox(height: 10),
      for (var i = 0; i < _headers.length; i++) _headerRow(i),
      Align(
        alignment: Alignment.centerLeft,
        child: SBtn(
          kind: BtnKind.ghost, size: BtnSize.sm, icon: Icons.add_rounded,
          onPressed: () => setState(() =>
            _headers.add((TextEditingController(), TextEditingController()))),
          child: const Text('Add header')),
      ),
      const SizedBox(height: 18),
      Text('EXPECTED CHECKSUM', style: SText.monoXs().copyWith(letterSpacing: 0.1 * 10.5, fontSize: 10.5)),
      const SizedBox(height: 8),
      _miniField(_checksumCtrl, 'SHA-256 or MD5 hex — verified after download'),
    ]),
  );

  Widget _headerRow(int i) {
    final h = _headers[i];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(children: [
        Expanded(flex: 4, child: _miniField(h.$1, 'Header')),
        const SizedBox(width: 8),
        Expanded(flex: 6, child: _miniField(h.$2, 'Value')),
        const SizedBox(width: 2),
        SIconBtn(icon: Icons.close_rounded, size: 34, tooltip: 'Remove',
          onPressed: () => setState(() {
            h.$1.dispose();
            h.$2.dispose();
            _headers.removeAt(i);
          })),
      ]),
    );
  }

  Widget _miniField(TextEditingController c, String hint) => Container(
    height: 40,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: SColors.bg0,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: SColors.line),
    ),
    padding: const EdgeInsets.symmetric(horizontal: 12),
    child: TextField(
      controller: c,
      style: SText.monoBase().copyWith(fontSize: 12),
      onChanged: (_) => setState(() {}),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: SText.monoBase(color: const Color(0xFF6A6672)).copyWith(fontSize: 12),
        border: InputBorder.none, isDense: true, contentPadding: EdgeInsets.zero,
      ),
    ),
  );

  bool get _isUrl {
    final t = _ctrl.text.trim();
    return t.startsWith('http://') || t.startsWith('https://');
  }

  /// The probe flags an `.m3u8` link with this MIME (see `probe_url` in the core).
  bool get _isHls => _probe?.mimeType == 'application/vnd.apple.mpegurl';

  void _onChanged() {
    setState(() {}); // refresh button/placeholder state
    _scheduleProbe();
  }

  void _scheduleProbe() {
    _debounce?.cancel();
    final url = _ctrl.text.trim();
    if (!_isUrl) {
      setState(() {
        _probe = null;
        _error = null;
        _probing = false;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 550), () => _probe2(url));
  }

  Future<void> _probe2(String url) async {
    setState(() {
      _probing = true;
      _error = null;
    });
    try {
      final res = await rust.probeUrl(url: url);
      if (!mounted || _ctrl.text.trim() != url) return;
      setState(() {
        _probe = res;
        _probedUrl = url;
        _probing = false;
      });
    } catch (_) {
      if (!mounted || _ctrl.text.trim() != url) return;
      setState(() {
        _probe = null;
        _error = 'Could not read this link';
        _probing = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final probe = _probe;
    final ready = probe != null && _probedUrl == _ctrl.text.trim();

    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        width: 560,
        decoration: BoxDecoration(
          color: SColors.bg2,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: SColors.lineHi),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.6), blurRadius: 80, offset: const Offset(0, 30))],
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // header
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 20, 22, 16),
            child: Row(children: [
              BoltIcon(size: 16),
              const SizedBox(width: 10),
              Text('New download', style: SText.uiLg()),
              const Spacer(),
              SIconBtn(icon: Icons.close_rounded, onPressed: () => Navigator.pop(context)),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 0, 22, 22),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (widget.fromClipboard) ...[
                Container(
                  margin: const EdgeInsets.only(bottom: 14),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    gradient: SColors.voltSoftGradient,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0x38FF63B6)),
                  ),
                  child: Row(children: [
                    const Icon(Icons.content_paste_rounded, size: 15, color: SColors.voltPink),
                    const SizedBox(width: 10),
                    Text('Link detected on your clipboard', style: SText.uiBase()),
                  ]),
                ),
              ],
              Text('SOURCE URL', style: SText.monoXs().copyWith(letterSpacing: 0.1 * 10.5, fontSize: 10.5)),
              const SizedBox(height: 8),
              Container(
                height: 44,
                decoration: BoxDecoration(
                  color: SColors.bg0,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: SColors.line),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(children: [
                  const Icon(Icons.link_rounded, size: 16, color: SColors.low),
                  const SizedBox(width: 10),
                  Expanded(child: TextField(
                    controller: _ctrl,
                    autofocus: true,
                    style: SText.monoBase().copyWith(fontSize: 12.5),
                    decoration: InputDecoration(
                      hintText: 'Paste a URL (http/https)…',
                      hintStyle: SText.monoBase(color: const Color(0xFF6A6672)).copyWith(fontSize: 12.5),
                      border: InputBorder.none, isDense: true, contentPadding: EdgeInsets.zero,
                    ),
                  )),
                  if (_probing)
                    const SizedBox(
                      width: 14, height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2, color: SColors.voltPink),
                    ),
                ]),
              ),
              const SizedBox(height: 16),
              if (ready) ...[
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: SColors.bg1,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: SColors.line),
                  ),
                  child: Row(children: [
                    ExtChip(name: probe.filename, type: _ftype(probe.fileType), size: 46, active: true),
                    const SizedBox(width: 13),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(probe.filename, style: SText.uiMd().copyWith(fontWeight: FontWeight.w500),
                        overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 3),
                      Text(
                        _isHls
                            ? '${_kindLabel(_ftype(probe.fileType))} · HLS stream · highest quality'
                            : '${_kindLabel(_ftype(probe.fileType))} · '
                                '${probe.totalBytes > BigInt.zero ? fmtBytes(probe.totalBytes.toInt()) : "unknown size"}',
                        style: SText.monoSm()),
                    ])),
                    if (_isHls)
                      Pill(tone: PillTone.volt, child: Row(mainAxisSize: MainAxisSize.min, children: const [
                        Icon(Icons.playlist_play_rounded, size: 12), SizedBox(width: 5), Text('STREAM'),
                      ]))
                    else if (probe.resumable)
                      Pill(tone: PillTone.mint, child: Row(mainAxisSize: MainAxisSize.min, children: const [
                        Icon(Icons.check_rounded, size: 11), SizedBox(width: 5), Text('RESUMABLE'),
                      ])),
                  ]),
                ),
              ] else ...[
                Container(
                  height: 78,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: _error != null ? SColors.danger.withValues(alpha: 0.5) : SColors.line),
                  ),
                  child: Center(
                    child: Text(
                      _error ?? (_probing ? 'Reading link…' : 'Awaiting a valid link…'),
                      style: SText.monoSm(color: _error != null ? SColors.danger : SColors.low)),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              if (!_isHls) ...[
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  Text('Parallel connections', style: SText.uiBase(color: SColors.mid).copyWith(fontSize: 13)),
                  SizedBox(width: 230, child: VoltSlider(
                    value: _conns, min: 1, max: 16,
                    onChanged: (v) => setState(() => _conns = v), suffix: '×')),
                ]),
                const SizedBox(height: 10),
              ],
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Text('Schedule for off-peak', style: SText.uiBase(color: SColors.mid).copyWith(fontSize: 13)),
                SToggle(value: _scheduled, onChanged: (v) => setState(() => _scheduled = v)),
              ]),
              const SizedBox(height: 10),
              _advancedDisclosure(),
              if (_advanced) _advancedSection(),
              const SizedBox(height: 22),
              Row(children: [
                Expanded(child: SBtn(kind: BtnKind.ghost, onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'))),
                const SizedBox(width: 10),
                Expanded(flex: 2, child: SBtn(
                  kind: BtnKind.primary,
                  icon: Icons.bolt_rounded,
                  disabled: !ready,
                  onPressed: !ready ? null : () {
                    final url = _ctrl.text.trim();
                    if (_isHls) {
                      widget.onStartStream(url: url, headers: _collectHeaders(), title: null);
                    } else {
                      final cs = _checksumCtrl.text.trim();
                      widget.onStart(
                        url: url,
                        connections: _conns.round(),
                        headers: _collectHeaders(),
                        expectedChecksum: cs.isEmpty ? null : cs,
                      );
                    }
                    Navigator.pop(context);
                  },
                  child: Text(_scheduled ? 'Schedule download' : 'Download now'),
                )),
              ]),
            ]),
          ),
        ]),
      ),
    );
  }
}
