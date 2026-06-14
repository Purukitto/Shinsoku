import 'package:flutter/material.dart';
import '../../../theme/colors.dart';
import '../../../theme/text_styles.dart';
import '../../widgets/bolt_icon.dart';
import '../../widgets/s_btn.dart';

class EmptyScreen extends StatelessWidget {
  const EmptyScreen({super.key, required this.onAdd});
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 460,
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Container(
          width: 96, height: 96,
          decoration: BoxDecoration(
            color: SColors.bg1,
            borderRadius: BorderRadius.circular(26),
            border: Border.all(color: SColors.line),
          ),
          child: Stack(alignment: Alignment.center, children: [
            Positioned.fill(child: Container(
              decoration: BoxDecoration(
                gradient: SColors.voltSoftGradient,
                borderRadius: BorderRadius.circular(26),
              ),
            )),
            BoltIcon(size: 44),
          ]),
        ),
        const SizedBox(height: 24),
        Text('Nothing downloading', style: SText.uiXl()),
        const SizedBox(height: 8),
        SizedBox(
          width: 360,
          child: Text(
            'Paste a link, drop a torrent, or copy a URL anywhere — Shinsoku catches it and downloads at full speed.',
            textAlign: TextAlign.center,
            style: SText.uiBase(color: SColors.low).copyWith(height: 1.5),
          ),
        ),
        const SizedBox(height: 24),
        SBtn(
          kind: BtnKind.primary,
          icon: Icons.add_rounded,
          onPressed: onAdd,
          child: const Text('Add a download'),
        ),
      ]),
    );
  }
}
