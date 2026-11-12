import 'package:flutter/material.dart';

/// 全屏舞台顶栏：只承担「收起」入口，高度与顶部留白由调用方按屏幕宽度给定。
class ColaMusicStageHeader extends StatelessWidget {
  const ColaMusicStageHeader({
    super.key,
    required this.onClose,
    this.height = 96,
    this.topPadding = 40,
  });

  final double height;
  final double topPadding;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: SizedBox(
        height: height,
        child: Padding(
          padding: EdgeInsets.only(top: topPadding),
          child: Row(
            children: <Widget>[
              IconButton(
                onPressed: onClose,
                icon: const Icon(Icons.keyboard_arrow_down, size: 28.0),
              ),
              const Spacer(),
              const SizedBox(width: 8.0),
            ],
          ),
        ),
      ),
    );
  }
}
