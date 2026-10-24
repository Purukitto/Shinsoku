import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../models/off_peak.dart';
import '../../../platform.dart';
import '../../../providers/autostart_provider.dart';
import '../../../providers/capture_provider.dart';
import '../../../providers/settings_provider.dart';
import '../../../rust/api.dart' as rust;
import '../../../services/settings_service.dart';
import '../../../theme/colors.dart';
import '../../../theme/text_styles.dart';
import '../../widgets/s_toggle.dart';
import '../../widgets/segmented_control.dart';
import '../../widgets/volt_slider.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  bool _showManual = false;

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(settingsProvider);
    final set = ref.read(settingsProvider.notifier);
    final cap = isDesktop ? ref.watch(captureProvider) : CaptureState.empty;
    final capStatus = cap.enabled ? ref.watch(captureStatusProvider).value : null;
    final autostart = ref.read(autostartServiceProvider).supported;
    return SizedBox(
      width: 760,
      child: Column(
        children: [
          _card(
            icon: Icons.bolt_rounded,
            title: 'Acceleration',
            children: [
              _row(
                'Connections per download',
                desc: 'Split each file into parallel segments for maximum throughput.',
                child: VoltSlider(
                  value: s.maxConnections.toDouble(),
                  min: 1,
                  max: 16,
                  onChanged: (v) => set.setMaxConnections(v.round()),
                  suffix: '×',
                ),
              ),
              _row(
                'Simultaneous downloads',
                desc: 'How many files transfer at once before others queue.',
                last: true,
                child: VoltSlider(
                  value: s.maxSimultaneous.toDouble(),
                  min: 1,
                  max: 8,
                  onChanged: (v) => set.setMaxSimultaneous(v.round()),
                ),
              ),
            ],
          ),
          _card(
            icon: Icons.speed_rounded,
            title: 'Bandwidth',
            children: [
              _row(
                'Download speed limit',
                desc: '0 means unlimited — use the full pipe.',
                child: VoltSlider(
                  value: s.downloadLimitMbps.toDouble(),
                  min: 0,
                  max: 200,
                  step: 5,
                  onChanged: (v) => set.setDownloadLimitMbps(v.round()),
                  fmt: (v) => v == 0 ? 'Unlimited' : '${v.toInt()} MB/s',
                ),
              ),
              _row(
                'Cap upload / seeding',
                desc: 'Throttle uploads so downloads stay fast.',
                child: SToggle(value: s.uploadCap, onChanged: set.setUploadCap),
              ),
              if (s.uploadCap)
                _row(
                  'Upload speed limit',
                  last: true,
                  child: VoltSlider(
                    value: s.uploadLimitMbps.toDouble(),
                    min: 1,
                    max: 100,
                    step: 1,
                    onChanged: (v) => set.setUploadLimitMbps(v.round()),
                    suffix: ' MB/s',
                  ),
                ),
            ],
          ),
          _card(
            icon: Icons.folder_rounded,
            title: 'Files',
            children: [
              _row(
                'Sort into category folders',
                desc: 'Save into Videos, Images, Documents… subfolders of your download folder.',
                last: true,
                child: SToggle(value: s.categorize, onChanged: set.setCategorize),
              ),
            ],
          ),
          _card(
            icon: Icons.schedule_rounded,
            title: 'Scheduling',
            children: [
              _row(
                'Off-peak hours',
                desc:
                    'Scheduled downloads start when these hours begin and stop when they '
                    'end, carrying on the next time.',
                child: _DayPicker(days: s.offPeakDays, onChanged: set.setOffPeakDays),
              ),
              _scheduleTimeline(s, set),
              _row(
                'Full speed off-peak',
                desc: 'Ignore the download speed limit during off-peak hours.',
                child: SToggle(value: s.offPeakFullSpeed, onChanged: set.setOffPeakFullSpeed),
              ),
            ],
          ),
          if (autostart)
            _card(
              icon: Icons.power_settings_new_rounded,
              title: 'Startup',
              children: [
                _row(
                  Platform.isWindows ? 'Start with Windows' : 'Start when you sign in',
                  desc:
                      'Open in the tray when you sign in, so scheduled downloads run on their own.',
                  last: true,
                  child: SToggle(
                    value: ref.watch(autostartProvider),
                    onChanged: ref.read(autostartProvider.notifier).setEnabled,
                  ),
                ),
              ],
            ),
          // the clipboard poll and the extension are desktop only for now
          if (isDesktop)
            _card(
              icon: Icons.content_paste_rounded,
              title: 'Capture',
              children: [
                _row(
                  'Monitor clipboard',
                  desc: 'Catch links the moment you copy them and offer to download.',
                  child: SToggle(value: s.clipboardMonitor, onChanged: set.setClipboardMonitor),
                ),
                _row(
                  'Browser integration',
                  desc:
                      'Capture downloads from Firefox & Chrome via the extension — '
                      'cookies and referrer included.',
                  last: !cap.enabled,
                  child: SToggle(
                    value: cap.enabled,
                    onChanged: (v) => ref.read(captureProvider.notifier).setEnabled(v),
                  ),
                ),
                if (cap.enabled) _captureDetails(cap, capStatus),
              ],
            ),
          _card(
            icon: Icons.palette_outlined,
            title: 'Appearance',
            children: [
              _row(
                'Theme',
                desc: 'System follows your device’s light or dark mode.',
                // shrinks rather than overflows on a narrow phone or with large text
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: SSegmented<ThemeMode>(
                    options: const [
                      SOption(value: ThemeMode.system, label: 'System'),
                      SOption(value: ThemeMode.light, label: 'Light'),
                      SOption(value: ThemeMode.dark, label: 'Dark'),
                    ],
                    value: s.themeMode,
                    onChanged: set.setThemeMode,
                  ),
                ),
              ),
              if (s.themeMode != ThemeMode.light)
                _row(
                  'Pure black',
                  desc: 'Use true black in dark mode, which saves power on OLED screens.',
                  last: true,
                  child: SToggle(value: s.pureBlack, onChanged: set.setPureBlack),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _card({required IconData icon, required String title, required List<Widget> children}) {
    final c = context.colors;
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: c.bg1,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c.line),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 18),
            child: Row(
              children: [
                Icon(icon, size: 17, color: c.accent),
                const SizedBox(width: 10),
                Text(
                  title.toUpperCase(),
                  style: c.text
                      .uiBase(color: c.mid)
                      .copyWith(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.04 * 13,
                      ),
                ),
              ],
            ),
          ),
          ...children,
        ],
      ),
    );
  }

  Widget _row(String title, {String? desc, required Widget child, bool last = false}) {
    final c = context.colors;
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: c.text.uiMd().copyWith(fontWeight: FontWeight.w500, fontSize: 14)),
        if (desc != null) ...[
          const SizedBox(height: 3),
          Text(desc, style: c.text.uiBase(color: c.low).copyWith(fontSize: 12.5)),
        ],
      ],
    );
    // On a phone a toggle stays beside its title; wider controls go below it.
    final compact = isCompact(context);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 18),
      decoration: last
          ? null
          : BoxDecoration(
              border: Border(top: BorderSide(color: c.line)),
            ),
      child: compact && child is! SToggle
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [text, const SizedBox(height: 14), child],
            )
          : Row(
              children: [
                Expanded(child: text),
                SizedBox(width: compact ? 16 : 24),
                if (compact)
                  child
                else
                  SizedBox(
                    width: 230,
                    child: Align(alignment: Alignment.centerRight, child: child),
                  ),
              ],
            ),
    );
  }

  /// What the extension needs to connect. Primary path is one pairing code;
  /// host/port/token sit under a Manual disclosure. Shown only when enabled.
  Widget _captureDetails(CaptureState cap, rust.CaptureStatus? status) {
    final c = context.colors;
    final endpoint = 'http://127.0.0.1:${cap.port}';
    final running = (status?.running ?? cap.running) && cap.port != 0;
    final lastSeen = status?.lastSeenMs;
    final connected = running && lastSeen != null && lastSeen > 0;
    final captures = status?.captures ?? 0;

    final (statusLabel, statusColor) = !running
        ? ('Server not running', c.danger)
        : connected
        ? ('Browser connected${captures > 0 ? ' · $captures captured' : ''}', c.mint)
        : ('Listening — waiting for your browser', c.amber);

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 18),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: c.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(shape: BoxShape.circle, color: statusColor),
              ),
              const SizedBox(width: 8),
              Text(statusLabel, style: c.text.uiBase(color: statusColor).copyWith(fontSize: 12.5)),
            ],
          ),
          const SizedBox(height: 12),
          _detailField('Pairing code', cap.pairingCode, mono: true),
          const SizedBox(height: 9),
          Text(
            'Open the Shinsoku extension’s options and paste this once — it fills everything.',
            style: c.text.uiBase(color: c.low).copyWith(fontSize: 12),
          ),
          const SizedBox(height: 12),
          InkWell(
            onTap: () => setState(() => _showManual = !_showManual),
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _showManual ? Icons.expand_more_rounded : Icons.chevron_right_rounded,
                    size: 16,
                    color: c.mid,
                  ),
                  const SizedBox(width: 4),
                  Text('Manual setup', style: c.text.uiBase(color: c.mid).copyWith(fontSize: 12.5)),
                ],
              ),
            ),
          ),
          if (_showManual) ...[
            const SizedBox(height: 10),
            _detailField('Endpoint', endpoint),
            const SizedBox(height: 8),
            _detailField('Token', cap.token, mono: true),
          ],
        ],
      ),
    );
  }

  Widget _detailField(String label, String value, {bool mono = false}) {
    final c = context.colors;
    return Container(
      decoration: BoxDecoration(
        color: c.bg0,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.line),
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      child: Row(
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label.toUpperCase(),
              style: c.text.monoXs(color: c.low).copyWith(fontSize: 10, letterSpacing: 0.08 * 10),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: (mono ? c.text.monoSm() : c.text.uiMd()).copyWith(fontSize: 12.5),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          _CopyChip(text: value),
        ],
      ),
    );
  }

  Widget _scheduleTimeline(AppSettings s, SettingsNotifier set) {
    final c = context.colors;
    final label = 'OFF-PEAK ${fmtClock(s.offPeakStartMin)}–${fmtClock(s.offPeakEndMin)}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _TimeStepper(
                  label: 'FROM',
                  minutes: s.offPeakStartMin,
                  onChanged: (m) => set.setOffPeakWindow(m, s.offPeakEndMin),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _TimeStepper(
                  label: 'TO',
                  minutes: s.offPeakEndMin,
                  onChanged: (m) => set.setOffPeakWindow(s.offPeakStartMin, m),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            height: 52,
            decoration: BoxDecoration(
              color: c.bg0,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: c.line),
            ),
            clipBehavior: Clip.hardEdge,
            child: Stack(
              children: [
                // full-speed window across the day (wraps past midnight as two bands)
                Positioned.fill(
                  child: Row(children: _windowBands(s.offPeakStartMin, s.offPeakEndMin)),
                ),
                // hour ticks — one cheap paint instead of 24 widgets
                Positioned.fill(child: CustomPaint(painter: _ScheduleTicks(c.lineHi))),
                // label
                Positioned(
                  left: 10,
                  top: 8,
                  child: Text(label, style: c.text.monoXs(color: c.accent).copyWith(fontSize: 10)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              for (final t in ['00:00', '06:00', '12:00', '18:00', '24:00'])
                Text(t, style: c.text.monoXs().copyWith(fontSize: 10)),
            ],
          ),
        ],
      ),
    );
  }

  /// Flex-weighted day strip (1440 min wide): full-speed window shaded, rest
  /// empty. A wrapping window (start > end) shades both ends.
  List<Widget> _windowBands(int start, int end) {
    final c = context.colors;
    Widget band(int mins) => Expanded(
      flex: mins,
      child: Container(decoration: BoxDecoration(gradient: c.accentSoftGradient)),
    );
    Widget gap(int mins) => Expanded(flex: mins, child: const SizedBox());
    final out = <Widget>[];
    void add(Widget Function(int) w, int mins) {
      if (mins > 0) out.add(w(mins));
    }

    if (start == end) {
      add(gap, 1440);
    } else if (start < end) {
      add(gap, start);
      add(band, end - start);
      add(gap, 1440 - end);
    } else {
      add(band, end);
      add(gap, start - end);
      add(band, 1440 - start);
    }
    return out;
  }
}

/// Compact 30-min time spinner matching the dark/mono aesthetic (no Material
/// clock dialog). Wraps at midnight.
class _TimeStepper extends StatelessWidget {
  const _TimeStepper({required this.label, required this.minutes, required this.onChanged});

  static const _step = 30;
  final String label;
  final int minutes;
  final ValueChanged<int> onChanged;

  // Dart's % returns a non-negative result for a positive divisor, so this wraps
  // cleanly across midnight in both directions.
  void _bump(int delta) => onChanged((minutes + delta) % 1440);

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      decoration: BoxDecoration(
        color: c.bg0,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.line),
      ),
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: c.text
                      .monoXs(color: c.low)
                      .copyWith(fontSize: 10, letterSpacing: 0.08 * 10),
                ),
                const SizedBox(height: 2),
                Text(
                  fmtClock(minutes),
                  style: TextStyle(fontFamily: kFontMono, fontSize: 15, color: c.hi),
                ),
              ],
            ),
          ),
          _StepBtn(icon: Icons.remove_rounded, onTap: () => _bump(-_step)),
          const SizedBox(width: 4),
          _StepBtn(icon: Icons.add_rounded, onTap: () => _bump(_step)),
        ],
      ),
    );
  }
}

/// One toggle per weekday, Monday first, over the off-peak day mask.
class _DayPicker extends StatelessWidget {
  const _DayPicker({required this.days, required this.onChanged});

  static const _names = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];
  final int days;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < 7; i++) ...[
          if (i > 0) const SizedBox(width: 4),
          _day(c, i, on: days & (1 << i) != 0),
        ],
      ],
    );
  }

  Widget _day(SColors c, int i, {required bool on}) => Tooltip(
    message: _names[i],
    child: Semantics(
      label: _names[i],
      selected: on,
      button: true,
      child: InkWell(
        onTap: () => onChanged(days ^ (1 << i)),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            gradient: on ? c.accentSoftGradient : null,
            color: on ? null : c.bg0,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: on ? c.accent.withValues(alpha: 0.25) : c.line),
          ),
          child: Text(
            _names[i][0],
            style: c.text
                .monoSm(color: on ? c.accent : c.low)
                .copyWith(fontSize: 11.5, fontWeight: FontWeight.w600),
          ),
        ),
      ),
    ),
  );
}

class _StepBtn extends StatelessWidget {
  const _StepBtn({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: c.bg2,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: c.line),
        ),
        child: Icon(icon, size: 15, color: c.mid),
      ),
    );
  }
}

/// Faint hour ticks across the schedule timeline, drawn in a single paint pass
/// (taller marks every 6 hours).
class _ScheduleTicks extends CustomPainter {
  const _ScheduleTicks(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (int h = 1; h < 24; h++) {
      final x = size.width * h / 24;
      final len = h % 6 == 0 ? 12.0 : 6.0;
      canvas.drawLine(Offset(x, size.height - len), Offset(x, size.height), paint);
    }
  }

  @override
  bool shouldRepaint(_ScheduleTicks oldDelegate) => oldDelegate.color != color;
}

/// Copy-to-clipboard button with a brief check-mark confirmation.
class _CopyChip extends StatefulWidget {
  const _CopyChip({required this.text});
  final String text;

  @override
  State<_CopyChip> createState() => _CopyChipState();
}

class _CopyChipState extends State<_CopyChip> {
  bool _done = false;
  Timer? _t;

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  void _copy() {
    Clipboard.setData(ClipboardData(text: widget.text));
    setState(() => _done = true);
    _t?.cancel();
    _t = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _done = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return IconButton(
      onPressed: _copy,
      iconSize: 15,
      visualDensity: VisualDensity.compact,
      splashRadius: 16,
      tooltip: 'Copy',
      icon: Icon(_done ? Icons.check_rounded : Icons.copy_rounded, color: _done ? c.mint : c.low),
    );
  }
}
