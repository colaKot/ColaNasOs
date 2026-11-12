import 'dart:async';

import 'package:flutter/material.dart';

import '../../../compat/base_components.dart';
import '../../../compat/getx.dart';
import '../../../compat/lyric_kit.dart';
import 'cola_stage_dynamic_lyric_parser.dart';
import 'cola_stage_dynamic_lyric_view.dart';
import 'cola_stage_lyric_search_dialog.dart';

/// 歌词高亮统一用纯白，普通行按主题透明度变暗。
const Color _kHighlight = Colors.white;

LyricStyle _styleFor(ThemeData theme, bool centered) {
  final base = LyricStyles.default1;
  final normal = base.textStyle;
  final active = base.activeStyle;
  final translation = base.translationStyle;

  return base.copyWith(
    textAlign: centered ? TextAlign.center : TextAlign.left,
    contentAlignment: centered
        ? CrossAxisAlignment.center
        : CrossAxisAlignment.start,
    highlightAlign: centered
        ? MainAxisAlignment.center
        : MainAxisAlignment.start,
    activeAlignment: centered
        ? MainAxisAlignment.center
        : MainAxisAlignment.start,
    fadeRange: FadeRange(
      top: (base.fadeRange?.top ?? 80) * 0.35,
      bottom: base.fadeRange?.bottom ?? 80,
    ),
    contentPadding: EdgeInsets.fromLTRB(0, 64, centered ? 0 : 10, 20),
    selectedColor: _kHighlight,
    activeHighlightColor: _kHighlight,
    textStyle: normal.copyWith(
      fontSize: (normal.fontSize ?? 16) + 2,
      color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
    ),
    translationStyle: translation.copyWith(
      fontSize: (translation.fontSize ?? 14) + 2,
      color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
    ),
    activeStyle: active.copyWith(
      fontSize: (active.fontSize ?? 18) + 8,
      fontWeight: FontWeight.w700,
      color: _kHighlight,
    ),
  );
}

/// 歌词区：曲目信息 + 在线歌词搜索入口 + 歌词滚动视图。
class ColaMusicStageLyrics extends StatefulWidget {
  const ColaMusicStageLyrics({
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

  final String musicPath;
  final String title;
  final String album;
  final String artist;
  final String lyrics;
  final Duration trackDuration;
  final Duration position;
  final Future<void> Function(Duration position) onSeekTo;
  final bool centerMode;

  @override
  State<ColaMusicStageLyrics> createState() => _ColaMusicStageLyricsState();
}

class _ColaMusicStageLyricsState extends State<ColaMusicStageLyrics> {
  late final LyricController _lyric;
  LyricModel? _wordTimedModel;

  @override
  void initState() {
    super.initState();
    _lyric = LyricController()..setOnTapLineCallback(_seekToLine);
    final raw = widget.lyrics.trim();
    if (raw.isNotEmpty) _loadLyric(raw);
    _lyric.setProgress(widget.position);
  }

  @override
  void didUpdateWidget(covariant ColaMusicStageLyrics oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.onSeekTo != oldWidget.onSeekTo) {
      _lyric.setOnTapLineCallback(_seekToLine);
    }
    final next = widget.lyrics.trim();
    if (next != oldWidget.lyrics.trim()) _loadLyric(next);
    if (widget.position != oldWidget.position) {
      _lyric.setProgress(widget.position);
    }
  }

  @override
  void dispose() {
    _lyric.dispose();
    super.dispose();
  }

  void _seekToLine(Duration at) => unawaited(widget.onSeekTo(at));

  /// 带逐字时间轴的歌词交给专用视图，否则走普通 LRC 解析。
  void _loadLyric(String raw) {
    final parsed = ColaMusicStageWordLyricParser.tryParse(raw);
    _wordTimedModel = parsed;
    if (parsed == null) {
      _lyric.loadLyric(raw);
    } else {
      _lyric.loadLyricModel(parsed);
    }
  }

  Future<void> _openLyricSearch() async {
    final pathAtOpen = widget.musicPath;
    final picked = await ColaMusicStageLyricSearch.show(
      context,
      musicPath: widget.musicPath,
      title: widget.title,
      artist: widget.artist,
      trackDuration: widget.trackDuration,
    );
    final lrc = (picked ?? '').trim();
    if (lrc.isEmpty) return;
    // 搜索期间可能已经切歌，路径变了就不要把歌词塞给新曲目。
    if (!mounted || widget.musicPath != pathAtOpen) return;
    setState(() {
      _loadLyric(lrc);
    });
    _lyric.setProgress(widget.position);
  }

  Widget _metaLine(ThemeData theme, String label, String value) {
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

  Widget _header(ThemeData theme) {
    final centered = widget.centerMode;
    final tint = theme.colorScheme.onSurface.withValues(alpha: 0.65);

    return Column(
      crossAxisAlignment: centered
          ? CrossAxisAlignment.center
          : CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          widget.title,
          textAlign: centered ? TextAlign.center : TextAlign.left,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.92),
          ),
        ),
        _metaLine(theme, 'music_label_album'.tr, widget.album),
        _metaLine(theme, 'music_label_singer'.tr, widget.artist),
        const SizedBox(height: 14.0),
        Row(
          mainAxisAlignment: centered
              ? MainAxisAlignment.center
              : MainAxisAlignment.start,
          children: <Widget>[
            CustomOutlinedButton(
              text: 'music_search_lyric'.tr,
              onPressed: _openLyricSearch,
              icon: const Icon(Icons.search),
              foregroundColor: tint,
              borderColor: tint,
            ),
          ],
        ),
        const SizedBox(height: 12.0),
      ],
    );
  }

  /// 没有歌词时不只提示，还把搜索入口一起摆在这里；
  /// 窄屏上标题栏可能被挤出视野，只靠标题栏的按钮会找不到入口。
  Widget _emptyLyrics(ThemeData theme) {
    final centered = widget.centerMode;
    final tint = theme.colorScheme.onSurface.withValues(alpha: 0.75);

    return Align(
      alignment: centered ? Alignment.topCenter : Alignment.topLeft,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: centered
            ? CrossAxisAlignment.center
            : CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'music_no_lyric'.tr,
            style: theme.textTheme.bodyLarge?.copyWith(
              height: 1.5,
              color: tint,
            ),
          ),
          const SizedBox(height: 10.0),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: tint,
              side: BorderSide(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.35),
              ),
            ),
            onPressed: _openLyricSearch,
            label: Text('music_search_lyric'.tr),
            icon: const Icon(Icons.search, size: 18.0),
          ),
        ],
      ),
    );
  }

  Widget _lyricBody(ThemeData theme, double height) {
    if (widget.lyrics.trim().isEmpty) return _emptyLyrics(theme);

    final style = _styleFor(theme, widget.centerMode);
    final model = _wordTimedModel;
    if (model != null) {
      return SizedBox(
        height: height,
        child: ColaMusicStageWordLyricView(
          style: style,
          onSeekTo: widget.onSeekTo,
          model: model,
          controller: _lyric,
          centerMode: widget.centerMode,
        ),
      );
    }

    return LyricView(
      width: double.infinity,
      style: style,
      height: height,
      controller: _lyric,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 640),
      child: LayoutBuilder(
        builder: (_, box) {
          final bounded = box.hasBoundedHeight && box.maxHeight.isFinite;
          if (!bounded) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _header(theme),
                SizedBox(height: 360.0, child: _lyricBody(theme, 360.0)),
              ],
            );
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _header(theme),
              Expanded(
                child: LayoutBuilder(
                  builder: (_, inner) => _lyricBody(
                    theme,
                    inner.maxHeight <= 0 ? 1.0 : inner.maxHeight,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
