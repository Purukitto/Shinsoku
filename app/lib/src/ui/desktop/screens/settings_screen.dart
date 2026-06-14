import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../providers/downloads_provider.dart';
import '../../../rust/api.dart' as rust;
import '../../../theme/colors.dart';
import '../../../theme/text_styles.dart';
import '../../widgets/s_toggle.dart';
import '../../widgets/volt_slider.dart';

const _mib = 1024 * 1024;

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  double _maxConn = 8;
  double _maxSim = 3;
  double _dlLimit = 0;
  bool _ulCap = true;
  double _ulLimit = 20;
  bool _clip = true;
  bool _browser = true;
  bool _sched = true;
  bool _categorize = true;

  void _applyMaxConn(double v) {
    setState(() => _maxConn = v);
    rust.setMaxConnections(engine: ref.read(engineProvider), n: v.round());
  }

  void _applyMaxSim(double v) {
    setState(() => _maxSim = v);
    rust.setMaxSimultaneous(engine: ref.read(engineProvider), n: v.round());
  }

  void _applyDlLimit(double v) {
    setState(() => _dlLimit = v);
    // slider is MB/s (0 = unlimited); engine wants bytes/s
    rust.setSpeedLimitBps(
      engine: ref.read(engineProvider),
      bps: BigInt.from(v.round()) * BigInt.from(_mib),
    );
  }

  void _applyCategorize(bool v) {
    setState(() => _categorize = v);
    rust.setCategorize(engine: ref.read(engineProvider), on_: v);
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 760,
      child: Column(children: [
        _card(icon: Icons.bolt_rounded, title: 'Acceleration', children: [
          _row('Connections per download',
            desc: 'Split each file into parallel segments for maximum throughput.',
            child: VoltSlider(value: _maxConn, min: 1, max: 16,
              onChanged: _applyMaxConn, suffix: '×')),
          _row('Simultaneous downloads',
            desc: 'How many files transfer at once before others queue.', last: true,
            child: VoltSlider(value: _maxSim, min: 1, max: 8,
              onChanged: _applyMaxSim)),
        ]),
        _card(icon: Icons.speed_rounded, title: 'Bandwidth', children: [
          _row('Download speed limit', desc: '0 means unlimited — use the full pipe.',
            child: VoltSlider(value: _dlLimit, min: 0, max: 200, step: 5,
              onChanged: _applyDlLimit,
              fmt: (v) => v == 0 ? 'Unlimited' : '${v.toInt()} MB/s')),
          _row('Cap upload / seeding', desc: 'Throttle uploads so downloads stay fast.',
            child: SToggle(value: _ulCap, onChanged: (v) => setState(() => _ulCap = v))),
          if (_ulCap)
            _row('Upload speed limit', last: true,
              child: VoltSlider(value: _ulLimit, min: 1, max: 100, step: 1,
                onChanged: (v) => setState(() => _ulLimit = v), suffix: ' MB/s')),
        ]),
        _card(icon: Icons.folder_rounded, title: 'Files', children: [
          _row('Sort into category folders',
            desc: 'Save into Videos, Images, Documents… subfolders of your download folder.',
            last: true,
            child: SToggle(value: _categorize, onChanged: _applyCategorize)),
        ]),
        _card(icon: Icons.schedule_rounded, title: 'Scheduling', children: [
          _row('Off-peak acceleration',
            desc: 'Run heavy downloads on a schedule when your network is quiet.',
            child: SToggle(value: _sched, onChanged: (v) => setState(() => _sched = v))),
          if (_sched) _scheduleTimeline(),
        ]),
        _card(icon: Icons.content_paste_rounded, title: 'Capture', children: [
          _row('Monitor clipboard',
            desc: 'Catch links the moment you copy them and offer to download.',
            child: SToggle(value: _clip, onChanged: (v) => setState(() => _clip = v))),
          _row('Browser integration',
            desc: 'Sniff streaming media and big files from any page via the extension.', last: true,
            child: SToggle(value: _browser, onChanged: (v) => setState(() => _browser = v))),
        ]),
      ]),
    );
  }

  static Widget _card({required IconData icon, required String title, required List<Widget> children}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: SColors.bg1,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: SColors.line),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 22),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 18),
          child: Row(children: [
            Icon(icon, size: 17, color: SColors.voltPink),
            const SizedBox(width: 10),
            Text(title.toUpperCase(),
              style: SText.uiBase(color: SColors.mid).copyWith(
                fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: 0.04 * 13)),
          ]),
        ),
        ...children,
      ]),
    );
  }

  static Widget _row(String title, {String? desc, required Widget child, bool last = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 18),
      decoration: last ? null : BoxDecoration(border: Border(top: BorderSide(color: SColors.line))),
      child: Row(children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: SText.uiMd().copyWith(fontWeight: FontWeight.w500, fontSize: 14)),
          if (desc != null) ...[
            const SizedBox(height: 3),
            Text(desc, style: SText.uiBase(color: SColors.low).copyWith(fontSize: 12.5)),
          ],
        ])),
        const SizedBox(width: 24),
        SizedBox(width: 230, child: Align(alignment: Alignment.centerRight, child: child)),
      ]),
    );
  }

  Widget _scheduleTimeline() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(children: [
        Container(
          height: 52,
          decoration: BoxDecoration(
            color: SColors.bg0,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: SColors.line),
          ),
          clipBehavior: Clip.hardEdge,
          child: Stack(children: [
            // full-speed window (left 7/24 of the day)
            Positioned.fill(
              child: FractionallySizedBox(
                widthFactor: 7 / 24,
                alignment: Alignment.centerLeft,
                child: Container(
                  decoration: BoxDecoration(gradient: SColors.voltSoftGradient),
                ),
              ),
            ),
            // hour ticks — one cheap paint instead of 24 widgets
            const Positioned.fill(child: CustomPaint(painter: _ScheduleTicks())),
            // label
            Positioned(
              left: 10, top: 8,
              child: Text('FULL SPEED 23:00–07:00',
                style: SText.monoXs(color: SColors.voltPink).copyWith(fontSize: 10)),
            ),
          ]),
        ),
        const SizedBox(height: 8),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          for (final t in ['00:00', '06:00', '12:00', '18:00', '24:00'])
            Text(t, style: SText.monoXs().copyWith(fontSize: 10)),
        ]),
      ]),
    );
  }
}

/// Faint hour ticks across the schedule timeline, drawn in a single paint pass
/// (taller marks every 6 hours).
class _ScheduleTicks extends CustomPainter {
  const _ScheduleTicks();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = SColors.lineHi
      ..strokeWidth = 1;
    for (int h = 1; h < 24; h++) {
      final x = size.width * h / 24;
      final len = h % 6 == 0 ? 12.0 : 6.0;
      canvas.drawLine(Offset(x, size.height - len), Offset(x, size.height), paint);
    }
  }

  @override
  bool shouldRepaint(_ScheduleTicks oldDelegate) => false;
}
