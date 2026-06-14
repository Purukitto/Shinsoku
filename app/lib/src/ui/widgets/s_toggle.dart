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
    final w = size == ToggleSize.sm ? 38.0 : 46.0;
    final h = size == ToggleSize.sm ? 22.0 : 26.0;
    final k = h - 6;

    return Semantics(
      toggled: value,
      child: GestureDetector(
        onTap: () => onChanged(!value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          width: w, height: h,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            gradient: value ? SColors.voltGradient : null,
            color: value ? null : SColors.bg4,
            borderRadius: BorderRadius.circular(h),
            boxShadow: value ? [BoxShadow(color: const Color(0x59FF63B6), blurRadius: 12)] : null,
          ),
          // AnimatedAlign slides the knob without a Positioned/ParentDataWidget,
          // which avoids the semantics parent-data conflict on Windows.
          child: AnimatedAlign(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeInOut,
            alignment: value ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(
              width: k, height: k,
              decoration: BoxDecoration(
                color: value ? const Color(0xFF1B1020) : SColors.hi,
                shape: BoxShape.circle,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
