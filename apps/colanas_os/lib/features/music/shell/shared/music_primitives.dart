/// 无业务语义的基础部件：主题取值、搜索框、封面图、滑块、系统栏配色。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../compat/base_components.dart';
import '../compat/cola_custom_colors.dart';
import '../compat/getx.dart';
import '../compat/host.dart';

/// 统一读取音乐壳的扩展色，省掉每个文件里重复的 3 行 theme.extension 样板。
extension MusicThemeX on BuildContext {
  Color get musicBarColor =>
      Theme.of(this).extension<CustomColors>()?.oprationBarBgColor ??
      Theme.of(this).colorScheme.surface;

  Color get musicContentBgColor =>
      Theme.of(this).extension<CustomColors>()?.mainContentBgColor ??
      Theme.of(this).colorScheme.surface;
}

/// 搜索框：把 TextEditingController 生命周期与外部 Rx 同步收在一处。
///
/// 之前 6 个搜索栏各自复制了 initState / ever / dispose 的 20 行样板。
class MusicSearchField extends StatefulWidget {
  const MusicSearchField({
    super.key,
    required this.searchText,
    required this.onChanged,
    required this.onClear,
    required this.hintText,
    this.defaultExpanded = false,
    this.height = 32,
    this.onSubmitted,
  });

  final RxString searchText;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;
  final String hintText;
  final bool defaultExpanded;
  final double height;

  /// 回车 / 点确认按钮时立即搜索
  final ValueChanged<String>? onSubmitted;

  @override
  State<MusicSearchField> createState() => _MusicSearchFieldState();
}

class _MusicSearchFieldState extends State<MusicSearchField> {
  late final TextEditingController _editing = TextEditingController(
    text: widget.searchText.value,
  );
  Worker? _syncWorker;

  @override
  void initState() {
    super.initState();
    _syncWorker = ever<String>(widget.searchText, (value) {
      if (!mounted || _editing.text == value) return;
      _editing.value = _editing.value.copyWith(
        text: value,
        selection: TextSelection.collapsed(offset: value.length),
        composing: TextRange.empty,
      );
    });
  }

  @override
  void dispose() {
    _syncWorker?.dispose();
    _editing.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CustomExpandableSearchBar(
    hintText: widget.hintText,
    controller: _editing,
    onChanged: widget.onChanged,
    onClear: widget.onClear,
    defaultExpanded: widget.defaultExpanded,
    height: widget.height,
    onSubmitted: widget.onSubmitted,
  );
}

/// 封面图：空地址与加载失败统一回退到默认封面。
class MusicCoverImage extends StatelessWidget {
  const MusicCoverImage({
    super.key,
    required this.url,
    this.width,
    this.height,
    this.borderRadius = 0,
    this.fit = BoxFit.cover,
    this.fallbackAsset = 'assets/music/icons/default_cover.jpg',
  });

  final String url;
  final double? width;
  final double? height;
  final double borderRadius;
  final BoxFit fit;
  final String fallbackAsset;

  @override
  Widget build(BuildContext context) {
    if (url.trim().isEmpty) return _fallback();
    return CustomExtendedImage(
      imageUrl: url,
      width: width,
      height: height,
      fit: fit,
      borderRadius: borderRadius,
      showLoading: false,
      errorBuilder: (_, _, _) => _fallback(),
    );
  }

  Widget _fallback() =>
      Image.asset(fallbackAsset, width: width, height: height, fit: fit);
}

/// 统一 SliderTheme 的滑块；全屏页可通过 [trackShape] 注入自定义轨道。
class MusicSlider extends StatelessWidget {
  const MusicSlider({
    super.key,
    required this.value,
    required this.max,
    this.min = 0,
    this.onChanged,
    this.onChangeStart,
    this.onChangeEnd,
    this.enabled = true,
    this.trackHeight = 3,
    this.thumbRadius = 6,
    this.overlayRadius = 10,
    this.trackShape,
    this.inactiveTrackColor,
  });

  final double value;
  final double max;
  final double min;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeStart;
  final ValueChanged<double>? onChangeEnd;
  final bool enabled;
  final double trackHeight;
  final double thumbRadius;
  final double overlayRadius;
  final SliderTrackShape? trackShape;
  final Color? inactiveTrackColor;

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context);
    final data = SliderTheme.of(context).copyWith(
      trackHeight: trackHeight,
      trackShape: trackShape,
      thumbShape: RoundSliderThumbShape(enabledThumbRadius: thumbRadius),
      overlayShape: RoundSliderOverlayShape(overlayRadius: overlayRadius),
      activeTrackColor: palette.colorScheme.primary,
      inactiveTrackColor:
          inactiveTrackColor ?? palette.dividerColor.withValues(alpha: 0.5),
      thumbColor: palette.colorScheme.primary,
    );
    return SliderTheme(
      data: data,
      child: Slider(
        value: value.clamp(min, max).toDouble(),
        min: min,
        max: max,
        onChanged: enabled ? onChanged : null,
        onChangeStart: onChangeStart,
        onChangeEnd: onChangeEnd,
      ),
    );
  }
}

/// 手机端状态栏 / 导航栏配色，三个列表页原先各复制了 16 行。
class MusicSystemUiOverlay extends StatelessWidget {
  const MusicSystemUiOverlay({
    super.key,
    required this.child,
    required this.barColor,
  });

  final Widget child;
  final Color barColor;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final icons = brightness == Brightness.dark
        ? Brightness.light
        : Brightness.dark;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: barColor,
        statusBarIconBrightness: icons,
        statusBarBrightness: brightness == Brightness.dark
            ? Brightness.dark
            : Brightness.light,
        systemNavigationBarColor: barColor,
        systemNavigationBarIconBrightness: icons,
        systemNavigationBarDividerColor: barColor,
      ),
      child: child,
    );
  }
}
