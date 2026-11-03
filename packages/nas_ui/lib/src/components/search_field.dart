import 'package:flutter/material.dart';

/// 搜索框：受控 controller + 清除按钮 + 回车提交，避免每页重复实现。
class NasSearchField extends StatefulWidget {
  const NasSearchField({
    super.key,
    required this.controller,
    this.hintText = '搜索',
    this.onSubmitted,
    this.onClear,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final String hintText;
  final ValueChanged<String>? onSubmitted;
  final VoidCallback? onClear;
  final bool autofocus;

  @override
  State<NasSearchField> createState() => _NasSearchFieldState();
}

class _NasSearchFieldState extends State<NasSearchField> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_refresh);
  }

  @override
  void didUpdateWidget(covariant NasSearchField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_refresh);
      widget.controller.addListener(_refresh);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final hasText = widget.controller.text.isNotEmpty;
    return TextField(
      controller: widget.controller,
      autofocus: widget.autofocus,
      decoration: InputDecoration(
        isDense: true,
        prefixIcon: const Icon(Icons.search),
        hintText: widget.hintText,
        suffixIcon: hasText
            ? IconButton(
                tooltip: '清除',
                icon: const Icon(Icons.clear),
                onPressed: () {
                  widget.controller.clear();
                  widget.onClear?.call();
                },
              )
            : null,
      ),
      onSubmitted: widget.onSubmitted,
    );
  }
}
