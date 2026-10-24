import 'package:flutter/material.dart';
import '../../theme/colors.dart';
import '../../theme/text_styles.dart';

/// Custom slider driven by a [GestureDetector] (no Material [Slider]) and no
/// `Positioned`/`LayoutBuilder` — the fill and thumb are placed with
/// `FractionallySizedBox`/`Align`. It exposes a single clean slider node via
/// [Semantics] (`excludeSemantics`), which avoids the parent-data/semantics
/// conflicts that a `Stack` of positioned children inside an interactive node
/// causes on the Windows accessibility bridge.
class VoltSlider extends StatelessWidget {
  const VoltSlider({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.step = 1,
    this.suffix = '',
    this.fmt,
  });

  final double value;
  final double min;
  final double max;
  final double step;
  final ValueChanged<double> onChanged;
  final String suffix;
  final String Function(double)? fmt;

  double _quantize(double v) {
    if (step > 0) v = (v / step).round() * step;
    return v.clamp(min, max);
  }

  String _label(double v) => fmt != null ? fmt!(v) : '${v.toInt()}$suffix';

  void _setFromDx(BuildContext context, double dx) {
    final box = context.findRenderObject();
    if (box is! RenderBox || box.size.width <= 0) return;
    final t = (dx / box.size.width).clamp(0.0, 1.0);
    final v = _quantize(min + t * (max - min));
    if (v != value) onChanged(v);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final pct = max > min ? ((value - min) / (max - min)).clamp(0.0, 1.0) : 0.0;
    final incV = _quantize(value + step);
    final decV = _quantize(value - step);

    return Row(
      children: [
        Expanded(
          child: Semantics(
            slider: true,
            value: _label(value),
            increasedValue: _label(incV),
            decreasedValue: _label(decV),
            onIncrease: () => onChanged(incV),
            onDecrease: () => onChanged(decV),
            excludeSemantics: true,
            child: Builder(
              builder: (context) {
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (d) => _setFromDx(context, d.localPosition.dx),
                  onHorizontalDragUpdate: (d) => _setFromDx(context, d.localPosition.dx),
                  child: SizedBox(
                    height: 22,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        // track bg
                        Container(
                          height: 6,
                          decoration: BoxDecoration(
                            color: c.bg4,
                            borderRadius: BorderRadius.circular(6),
                          ),
                        ),
                        // filled volt track
                        Align(
                          alignment: Alignment.centerLeft,
                          child: FractionallySizedBox(
                            widthFactor: pct,
                            child: Container(
                              height: 6,
                              decoration: BoxDecoration(
                                gradient: c.accentGradient,
                                borderRadius: BorderRadius.circular(6),
                              ),
                            ),
                          ),
                        ),
                        // thumb — positioned proportionally without pixel math
                        Align(
                          alignment: Alignment(2 * pct - 1, 0),
                          child: Container(
                            width: 18,
                            height: 18,
                            decoration: BoxDecoration(
                              color: c.hi,
                              shape: BoxShape.circle,
                              border: Border.all(color: c.accentInk, width: 3),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black38,
                                  blurRadius: 8,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        const SizedBox(width: 14),
        SizedBox(
          // fits "Unlimited" on one line
          width: 80,
          child: Text(
            _label(value),
            textAlign: TextAlign.right,
            style: TextStyle(fontFamily: kFontMono, fontSize: 13, color: c.hi),
          ),
        ),
      ],
    );
  }
}
