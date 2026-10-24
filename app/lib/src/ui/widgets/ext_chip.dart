import 'package:flutter/material.dart';
import '../../theme/colors.dart';
import '../../theme/text_styles.dart';
import '../../models/download_item.dart';

Color _typeTint(SColors c, FileType type) => switch (type) {
  FileType.video => c.accent,
  FileType.archive => c.accentEnd,
  FileType.app => c.accentStart,
  FileType.audio => c.mint,
  FileType.image => c.mid,
  FileType.doc => c.mid,
  FileType.iso => c.accentStart,
  _ => c.mid,
};

String _ext(String name) {
  final parts = name.split('.');
  if (parts.length < 2) return 'FILE';
  return parts.last.toUpperCase().substring(0, parts.last.length.clamp(0, 4));
}

class ExtChip extends StatelessWidget {
  const ExtChip({
    super.key,
    required this.name,
    required this.type,
    this.size = 46,
    this.active = false,
    this.radius = 12,
  });

  final String name;
  final FileType type;
  final double size;
  final bool active;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final tint = _typeTint(c, type);
    return SizedBox(
      width: size,
      height: size,
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: c.bg3,
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: c.line),
        ),
        child: Stack(
          children: [
            // colored left edge — clipped to the chip's rounded corners
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              child: Container(
                width: 3,
                decoration: BoxDecoration(
                  gradient: active ? c.accentGradient : null,
                  color: active ? null : tint.withValues(alpha: 0.75),
                ),
              ),
            ),
            Center(
              child: Text(
                _ext(name),
                style: c.text.monoBase().copyWith(
                  fontSize: size * 0.23,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.01,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
