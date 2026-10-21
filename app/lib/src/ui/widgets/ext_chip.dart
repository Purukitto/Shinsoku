import 'package:flutter/material.dart';
import '../../theme/colors.dart';
import '../../theme/text_styles.dart';
import '../../models/download_item.dart';

Color _typeTint(FileType type) => switch (type) {
  FileType.video => SColors.voltPink,
  FileType.archive => SColors.voltAmber,
  FileType.app => SColors.voltViolet,
  FileType.audio => SColors.mint,
  FileType.image => SColors.mid,
  FileType.doc => SColors.mid,
  FileType.iso => SColors.voltViolet,
  _ => SColors.mid,
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
    final tint = _typeTint(type);
    return SizedBox(
      width: size,
      height: size,
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: SColors.bg3,
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: SColors.line),
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
                  gradient: active ? SColors.voltGradient : null,
                  color: active ? null : tint.withValues(alpha: 0.75),
                ),
              ),
            ),
            Center(
              child: Text(
                _ext(name),
                style: SText.monoBase().copyWith(
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
