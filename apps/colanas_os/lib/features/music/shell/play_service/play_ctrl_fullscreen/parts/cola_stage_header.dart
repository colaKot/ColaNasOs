import 'package:flutter/material.dart';

class MusicPlayCtrlFullScreenHeader extends StatelessWidget {
  final double topPadding;
  final VoidCallback onClose;
  final double height;

  const MusicPlayCtrlFullScreenHeader({
    super.key,
    required this.onClose,
    this.height = 96,
    this.topPadding = 40,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: SizedBox(
        height: height,
        child: Padding(
          padding: EdgeInsets.fromLTRB(0, topPadding, 0, 0),
          child: Row(
            children: <Widget>[
              IconButton(
                onPressed: onClose,
                icon: const Icon(Icons.keyboard_arrow_down, size: 28.0),
              ),
              const Expanded(child: SizedBox.shrink()),
              const SizedBox(width: 8.0),
            ],
          ),
        ),
      ),
    );
  }
}
