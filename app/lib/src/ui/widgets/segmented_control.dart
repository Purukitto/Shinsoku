import 'package:flutter/material.dart';
import '../../theme/colors.dart';
import '../../theme/text_styles.dart';

class SOption<T> {
  final T value;
  final String? label;
  final IconData? icon;
  const SOption({required this.value, this.label, this.icon});
}

class SSegmented<T> extends StatelessWidget {
  const SSegmented({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
    this.full = false,
  });

  final List<SOption<T>> options;
  final T value;
  final ValueChanged<T> onChanged;
  final bool full;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: SColors.bg1,
        border: Border.all(color: SColors.line),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        mainAxisSize: full ? MainAxisSize.max : MainAxisSize.min,
        children: options.map((o) {
          final sel = o.value == value;
          return GestureDetector(
            onTap: () => onChanged(o.value),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
              decoration: BoxDecoration(
                color: sel ? SColors.bg3 : Colors.transparent,
                borderRadius: BorderRadius.circular(7),
                boxShadow: sel ? [BoxShadow(color: Colors.black26, blurRadius: 3, offset: const Offset(0, 1))] : null,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (o.icon != null) ...[
                    Icon(o.icon!, size: 15, color: sel ? SColors.hi : SColors.mid),
                    if (o.label != null) const SizedBox(width: 6),
                  ],
                  if (o.label != null)
                    Text(o.label!,
                      style: SText.uiBase(color: sel ? SColors.hi : SColors.mid)
                          .copyWith(fontWeight: FontWeight.w500, fontSize: 13)),
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

class SSearchInput extends StatelessWidget {
  const SSearchInput({
    super.key,
    this.placeholder = 'Search',
    this.controller,
    this.width = 220,
  });

  final String placeholder;
  final TextEditingController? controller;
  final double width;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width, height: 36,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: SColors.bg1,
          border: Border.all(color: SColors.line),
          borderRadius: BorderRadius.circular(9),
        ),
        child: Row(children: [
          Icon(Icons.search_rounded, size: 16, color: SColors.low),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: controller,
              style: SText.uiBase().copyWith(fontSize: 13.5),
              decoration: InputDecoration(
                hintText: placeholder,
                hintStyle: SText.uiBase(color: SColors.low).copyWith(fontSize: 13.5),
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
        ]),
      ),
    );
  }
}
