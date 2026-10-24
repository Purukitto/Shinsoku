import 'package:flutter/material.dart';
import '../../theme/colors.dart';
import '../../models/download_item.dart';

class SegmentBars extends StatelessWidget {
  const SegmentBars({
    super.key,
    required this.segments,
    this.height = 30,
    this.gap = 3,
    this.paused = false,
  });

  final List<SegmentInfo> segments;
  final double height;
  final double gap;
  final bool paused;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: segments.asMap().entries.map((e) {
        final s = e.value;
        return Expanded(
          child: Padding(
            padding: EdgeInsets.only(left: e.key > 0 ? gap : 0),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: Stack(
                alignment: Alignment.bottomCenter,
                children: [
                  Container(color: c.bg3),
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 500),
                    curve: Curves.easeInOut,
                    height: height * s.progress.clamp(0.0, 1.0),
                    decoration: BoxDecoration(
                      gradient: paused ? null : c.accentGradient,
                      color: paused ? c.bg4 : null,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}
