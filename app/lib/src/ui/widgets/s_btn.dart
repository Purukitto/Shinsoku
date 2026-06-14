import 'package:flutter/material.dart';
import '../../theme/colors.dart';
import '../../theme/text_styles.dart';

enum BtnKind { primary, solid, ghost, plain, danger }
enum BtnSize { sm, md }

class SBtn extends StatefulWidget {
  const SBtn({
    super.key,
    required this.child,
    this.onPressed,
    this.kind = BtnKind.ghost,
    this.size = BtnSize.md,
    this.icon,
    this.disabled = false,
  });

  final Widget child;
  final VoidCallback? onPressed;
  final BtnKind kind;
  final BtnSize size;
  final IconData? icon;
  final bool disabled;

  @override
  State<SBtn> createState() => _SBtnState();
}

class _SBtnState extends State<SBtn> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final h = widget.size == BtnSize.sm ? 32.0 : 38.0;
    final fontSize = widget.size == BtnSize.sm ? 13.0 : 13.5;
    final iconSize = widget.size == BtnSize.sm ? 15.0 : 16.0;
    final pad = widget.size == BtnSize.sm
        ? const EdgeInsets.symmetric(horizontal: 11)
        : const EdgeInsets.symmetric(horizontal: 15);

    Widget content = Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (widget.icon != null) ...[
          Icon(widget.icon, size: iconSize),
          const SizedBox(width: 7),
        ],
        DefaultTextStyle(
          style: SText.uiBase().copyWith(fontSize: fontSize),
          child: widget.child,
        ),
      ],
    );

    if (widget.kind == BtnKind.primary) {
      return Opacity(
        opacity: widget.disabled ? 0.4 : (_hovered ? 0.9 : 1.0),
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            onTap: widget.disabled ? null : widget.onPressed,
            child: Container(
              height: h,
              padding: pad,
              decoration: BoxDecoration(
                gradient: SColors.voltGradient,
                borderRadius: BorderRadius.circular(9),
                boxShadow: [BoxShadow(color: const Color(0x4CA25CFF), blurRadius: 14, offset: const Offset(0, 4))],
              ),
              child: DefaultTextStyle(
                style: SText.uiBase(color: const Color(0xFF1B1020)).copyWith(
                  fontSize: fontSize, fontWeight: FontWeight.w600),
                child: IconTheme(data: const IconThemeData(color: Color(0xFF1B1020)), child: content),
              ),
            ),
          ),
        ),
      );
    }

    final (bg, fg, border) = switch (widget.kind) {
      BtnKind.solid  => (SColors.bg3, SColors.hi,               SColors.lineHi),
      BtnKind.danger => (Colors.transparent, SColors.danger,    const Color(0x40FF7A6B)),
      _              => (Colors.transparent, SColors.mid,       SColors.line),
    };

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.disabled ? null : widget.onPressed,
        child: Opacity(
          opacity: widget.disabled ? 0.4 : 1.0,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            height: h,
            padding: pad,
            decoration: BoxDecoration(
              color: _hovered ? bg.withValues(alpha: (bg.a) + 0.06) : bg,
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: border),
            ),
            child: DefaultTextStyle(
              style: SText.uiBase(color: _hovered ? SColors.hi : fg).copyWith(fontSize: fontSize),
              child: IconTheme(data: IconThemeData(color: _hovered ? SColors.hi : fg), child: content),
            ),
          ),
        ),
      ),
    );
  }
}

class SIconBtn extends StatefulWidget {
  const SIconBtn({
    super.key,
    required this.icon,
    this.onPressed,
    this.size = 34,
    this.active = false,
    this.color,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final double size;
  final bool active;
  final Color? color;
  final String? tooltip;

  @override
  State<SIconBtn> createState() => _SIconBtnState();
}

class _SIconBtnState extends State<SIconBtn> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final iconSize = widget.size > 30 ? 18.0 : 16.0;
    final fg = _hovered || widget.active
        ? SColors.hi
        : (widget.color ?? SColors.mid);

    Widget btn = MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: widget.size, height: widget.size,
          decoration: BoxDecoration(
            color: _hovered || widget.active ? SColors.bg3 : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: widget.active ? SColors.lineHi : Colors.transparent, width: 1),
          ),
          child: Icon(widget.icon, size: iconSize, color: fg),
        ),
      ),
    );

    if (widget.tooltip != null) {
      return Tooltip(message: widget.tooltip!, child: btn);
    }
    return btn;
  }
}
