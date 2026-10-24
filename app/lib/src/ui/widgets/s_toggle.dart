import 'package:flutter/material.dart';
import '../../theme/colors.dart';

enum ToggleSize { sm, md }

class SToggle extends StatelessWidget {
  const SToggle({
    super.key,
    required this.value,
    required this.onChanged,
    this.size = ToggleSize.md,
  });

  final bool value;
  final ValueChanged<bool> onChanged;
  final ToggleSize size;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final light = Theme.of(context).brightness == Brightness.light;
    final w = size == ToggleSize.sm ? 38.0 : 46.0;
    final h = size == ToggleSize.sm ? 22.0 : 26.0;
    final k = h - 6;

    return Semantics(
      toggled: value,
      child: GestureDetector(
        onTap: () => onChanged(!value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          width: w,
          height: h,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            gradient: value ? c.accentGradient : null,
            color: value ? null : c.bg4,
            borderRadius: BorderRadius.circular(h),
            boxShadow: value
                ? [BoxShadow(color: c.accent.withValues(alpha: 0.35), blurRadius: 12)]
                : null,
          ),
          // AnimatedAlign slides the knob without a Positioned/ParentDataWidget,
          // which avoids the semantics parent-data conflict on Windows.
          child: AnimatedAlign(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeInOut,
            alignment: value ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(
              width: k,
              height: k,
              // off, a light theme's knob is white: a dark one reads as switched on
              decoration: BoxDecoration(
                color: value ? c.accentInk : (light ? Colors.white : c.hi),
                shape: BoxShape.circle,
                boxShadow: light && !value
                    ? const [
                        BoxShadow(color: Color(0x33000000), blurRadius: 2, offset: Offset(0, 1)),
                      ]
                    : null,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
