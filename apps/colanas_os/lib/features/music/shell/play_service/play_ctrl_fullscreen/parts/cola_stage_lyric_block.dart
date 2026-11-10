import 'dart:async';

import '../../../compat/base_components.dart';
import '../../../compat/lyric_kit.dart';

import 'package:flutter/material.dart';

import '../../../compat/getx.dart';

import 'cola_stage_dynamic_lyric_parser.dart';
import 'cola_stage_dynamic_lyric_view.dart';
import 'cola_stage_lyric_search_dialog.dart';

const Color _kLyricHighlightColor = Colors.white;

/// 依据主题与居中模式生成歌词样式：把原先 State 里的 4 层 copyWith 链
/// 收成纯函数，样式计算不再依赖 widget / State。
LyricStyle _styleFor(ThemeData theme, bool centerMode) {
  final localBase = LyricStyles.default1;
  final localActive = localBase.activeStyle;
  final localNormal = localBase.textStyle;

  return localBase.copyWith(
    translationStyle: (localBase.translationStyle).copyWith(
      fontSize: ((localBase.translationStyle).fontSize ?? 14) + 2,
      color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
    ),
    textStyle: localNormal.copyWith(
      fontSize: (localNormal.fontSize ?? 16) + 2,
      color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
    ),
    textAlign: centerMode ? TextAlign.center : TextAlign.left,
    selectedColor: _kLyricHighlightColor,
    highlightAlign: centerMode
        ? MainAxisAlignment.center
        : MainAxisAlignment.start,
    fadeRange: FadeRange(
      top: (localBase.fadeRange?.top ?? 80) * 0.35,
      bottom: (localBase.fadeRange?.bottom ?? 80),
    ),
    contentPadding: centerMode
        ? const EdgeInsets.fromLTRB(0, 64, 0, 20)
        : const EdgeInsets.fromLTRB(0, 64, 10, 20),
    contentAlignment: centerMode
        ? CrossAxisAlignment.center
        : CrossAxisAlignment.start,
    activeStyle: localActive.copyWith(
      fontWeight: FontWeight.w700,
      fontSize: (localActive.fontSize ?? 18) + 8,
      color: _kLyricHighlightColor,
    ),
    activeHighlightColor: _kLyricHighlightColor,
    activeAlignment: centerMode
        ? MainAxisAlignment.center
        : MainAxisAlignment.start,
  );
}

class MusicPlayCtrlFullScreenLyricBlock extends StatefulWidget {
  final Duration trackDuration;
  final String title;
  final Duration position;
  final String musicPath;
  final String lyrics;
  final String artist;
  final String album;
  final Future<void> Function(Duration position) onSeekTo;
  final bool centerMode;

  const MusicPlayCtrlFullScreenLyricBlock({
    super.key,
    required this.musicPath,
    required this.title,
    required this.album,
    required this.artist,
    required this.lyrics,
    required this.trackDuration,
    required this.position,
    required this.onSeekTo,
    this.centerMode = false,
  });

  @override
  State<MusicPlayCtrlFullScreenLyricBlock> createState() =>
      _MusicPlayCtrlFullScreenLyricBlockState();
}

class _MusicPlayCtrlFullScreenLyricBlockState
    extends State<MusicPlayCtrlFullScreenLyricBlock> {
  late final LyricController _controller;
  LyricModel? _dynamicLyricModel;

  void _loadLyric(String lyric) {
    final localParsed = MusicPlayCtrlFullScreenDynamicLyricParser.tryParse(
      lyric,
    );
    _dynamicLyricModel = localParsed;
    // 表驱动：解析结果有无 → 对应的加载动作
    final loaders = <bool, void Function()>{
      true: () => _controller.loadLyricModel(localParsed!),
      false: () => _controller.loadLyric(lyric),
    };
    loaders[localParsed != null]!();
  }

  Future<void> _showLyricSearchDialog() async {
    final localOpenedMusicPath = widget.musicPath;
    final localLrc = await MusicPlayCtrlFullScreenLyricSearchDialog.show(
      context,
      musicPath: widget.musicPath,
      title: widget.title,
      artist: widget.artist,
      trackDuration: widget.trackDuration,
    );
    final localNext = (localLrc ?? '').trim();
    if (localNext.isEmpty) return;
    if (!mounted || widget.musicPath != localOpenedMusicPath) return;
    setState(() {
      _loadLyric(localNext);
    });
    _controller.setProgress(widget.position);
  }

  @override
  void initState() {
    super.initState();
    _controller = LyricController();
    _controller.setOnTapLineCallback((position) {
      unawaited(widget.onSeekTo(position));
    });
    final lyric = widget.lyrics.trim();
    if (lyric.isNotEmpty) {
      _loadLyric(lyric);
    }
    _controller.setProgress(widget.position);
  }

  @override
  void didUpdateWidget(covariant MusicPlayCtrlFullScreenLyricBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    final localNextLyric = widget.lyrics.trim();
    // 表驱动：把「字段是否变化」与「对应要执行的动作」列成一张表，按序执行命中项
    final changes = <({bool changed, void Function() apply})>[
      (
        changed: widget.onSeekTo != oldWidget.onSeekTo,
        apply: () => _controller.setOnTapLineCallback(
          (position) => unawaited(widget.onSeekTo(position)),
        ),
      ),
      (
        changed: localNextLyric != oldWidget.lyrics.trim(),
        apply: () => _loadLyric(localNextLyric),
      ),
      (
        changed: widget.position != oldWidget.position,
        apply: () => _controller.setProgress(widget.position),
      ),
    ];
    for (final change in changes) {
      if (change.changed) change.apply();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Widget _buildLyricArea(ThemeData theme, {required double height}) {
    final localLyricStyle = _styleFor(theme, widget.centerMode);
    final localLyricText = widget.lyrics.trim();
    if (localLyricText.isEmpty) {
      // 没歌词时把「搜索歌词」直接摆在这儿：以前只有标题栏那一个入口，
      // 窗口矮 / 手机竖屏时标题栏被挤走，用户就找不到搜索词的地方了。
      return Align(
        alignment: widget.centerMode ? Alignment.topCenter : Alignment.topLeft,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: widget.centerMode
              ? CrossAxisAlignment.center
              : CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'music_no_lyric'.tr,
              style: theme.textTheme.bodyLarge?.copyWith(
                height: 1.5,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.75),
              ),
            ),
            const SizedBox(height: 10.0),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: theme.colorScheme.onSurface.withValues(
                  alpha: 0.75,
                ),
                side: BorderSide(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.35),
                ),
              ),
              onPressed: _showLyricSearchDialog,
              label: Text('music_search_lyric'.tr),
              icon: const Icon(Icons.search, size: 18.0),
            ),
          ],
        ),
      );
    }

    if (_dynamicLyricModel != null) {
      return SizedBox(
        height: height,
        child: MusicPlayCtrlFullScreenDynamicLyricView(
          style: localLyricStyle,
          onSeekTo: widget.onSeekTo,
          model: _dynamicLyricModel!,
          controller: _controller,
          centerMode: widget.centerMode,
        ),
      );
    }

    return LyricView(
      width: double.infinity,
      style: localLyricStyle,
      height: height,
      controller: _controller,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    Widget metaLine(String label, String value) {
      if (value.trim().isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.fromLTRB(0, 10, 0, 0),
        child: Text(
          '$label: $value',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
          ),
        ),
      );
    }

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 640),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final bounded =
              constraints.hasBoundedHeight && constraints.maxHeight.isFinite;

          final localHeader = Column(
            crossAxisAlignment: widget.centerMode
                ? CrossAxisAlignment.center
                : CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                widget.title,
                textAlign: widget.centerMode
                    ? TextAlign.center
                    : TextAlign.left,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.92),
                ),
              ),
              metaLine('music_label_album'.tr, widget.album),
              metaLine('music_label_singer'.tr, widget.artist),
              const SizedBox(height: 14.0),
              Row(
                mainAxisAlignment: widget.centerMode
                    ? MainAxisAlignment.center
                    : MainAxisAlignment.start,
                children: <Widget>[
                  CustomOutlinedButton(
                    text: 'music_search_lyric'.tr,
                    onPressed: _showLyricSearchDialog,
                    icon: const Icon(Icons.search),
                    foregroundColor: theme.colorScheme.onSurface.withValues(
                      alpha: 0.65,
                    ),
                    borderColor: theme.colorScheme.onSurface.withValues(
                      alpha: 0.65,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12.0),
            ],
          );

          if (!bounded) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                localHeader,
                SizedBox(
                  height: 360.0,
                  child: _buildLyricArea(theme, height: 360.0),
                ),
              ],
            );
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              localHeader,
              Expanded(
                child: LayoutBuilder(
                  builder: (context, c) {
                    final localH = c.maxHeight <= 0 ? 1.0 : c.maxHeight;
                    return _buildLyricArea(theme, height: localH);
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
