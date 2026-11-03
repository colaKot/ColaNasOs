import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import '../../core/video_subtitle_prefs.dart';

/// 内置播放器（SP3-03 二期）：media_kit 作为跨平台内核。
///
/// 选型说明：官方 `video_player` 不支持 Windows / Linux；media_kit 覆盖
/// Windows / Linux / macOS / Android / iOS（Web 走同一套 API），一套代码即可。
/// 控件用 SDK 自带的 Material 方案（播放 / 进度 / 音量 / 全屏），避免自己造一遍。
///
/// 外挂字幕：服务端已把 srt / ass / vtt 转成 WebVTT，这里用
/// `SubtitleTrack.data(vtt)` 直接喂给播放器；语言偏好记在本地设置，
/// 下次打开任意影片自动套用（[VideoSubtitlePrefs]）。
class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key, required this.url, this.title, this.itemId});

  /// 带短期令牌的播放直链（`/api/v1/video/stream-url` 签发）
  final String url;
  final String? title;

  /// 影片 id：用于拉外挂字幕；为空则不做字幕（例如外部传入的直链）
  final String? itemId;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  late final Player _player;
  late final VideoController _controller;
  String? _error;

  List<VideoSubtitleFile> _subs = const [];
  String? _activeSub;

  @override
  void initState() {
    super.initState();
    _player = Player();
    _controller = VideoController(_player);
    _player.stream.error.listen((message) {
      if (mounted) setState(() => _error = message);
    });
    _player.open(Media(widget.url)).catchError((Object e) {
      if (mounted) setState(() => _error = e.toString());
    });
    _loadSubtitles();
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _loadSubtitles() async {
    final id = widget.itemId;
    if (id == null || id.isEmpty) return;
    try {
      final res = await ApiSession.instance.client.videoSubtitles(id: id);
      if (!mounted) return;
      setState(() => _subs = res.items);
      final pick = pickSubtitle(res.items, VideoSubtitlePrefs.instance.preferred);
      if (pick != null) await _applySubtitle(pick);
    } catch (_) {
      // 没有字幕 / 接口失败都不影响播放
    }
  }

  Future<void> _applySubtitle(VideoSubtitleFile? file) async {
    if (file == null) {
      try {
        await _player.setSubtitleTrack(SubtitleTrack.no());
      } catch (_) {
        /* 内核不支持时忽略 */
      }
      if (mounted) setState(() => _activeSub = null);
      return;
    }

    final id = widget.itemId;
    if (id == null) return;
    try {
      final res = await ApiSession.instance.client.videoSubtitle(id: id, name: file.name);
      await _player.setSubtitleTrack(
        SubtitleTrack.data(res.vtt, title: file.name, language: file.lang),
      );
      if (mounted) setState(() => _activeSub = file.name);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('video.subtitleFailed', {'error': '$e'}))),
        );
      }
    }
  }

  /// 选择并记住偏好：`off` / `auto` / 语言标签
  Future<void> _chooseSubtitle(String preferred, VideoSubtitleFile? file) async {
    await VideoSubtitlePrefs.instance.set(preferred);
    await _applySubtitle(file);
  }

  VideoSubtitleFile? _findSub(String name) {
    for (final sub in _subs) {
      if (sub.name == name) return sub;
    }
    return null;
  }

  Widget _subtitleMenu() {
    final scheme = Theme.of(context).colorScheme;
    return PopupMenuButton<String>(
      icon: Icon(
        _activeSub == null ? Icons.subtitles_outlined : Icons.subtitles,
        color: Colors.white70,
      ),
      tooltip: tr('ui.video.022'),
      onSelected: (value) {
        if (value == VideoSubtitlePrefs.off) {
          _chooseSubtitle(VideoSubtitlePrefs.off, null);
          return;
        }
        if (value == VideoSubtitlePrefs.auto) {
          _chooseSubtitle(
            VideoSubtitlePrefs.auto,
            _subs.isEmpty ? null : _subs.first,
          );
          return;
        }
        final file = _findSub(value);
        _chooseSubtitle(file?.lang ?? VideoSubtitlePrefs.auto, file);
      },
      itemBuilder: (context) => [
        PopupMenuItem<String>(
          value: VideoSubtitlePrefs.off,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_activeSub == null)
                Icon(Icons.check, size: 16, color: scheme.primary)
              else
                const SizedBox(width: 16),
              const SizedBox(width: 8),
              Text(tr('ui.video.023')),
            ],
          ),
        ),
        if (_subs.length > 1)
          PopupMenuItem<String>(
            value: VideoSubtitlePrefs.auto,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(width: 16),
                const SizedBox(width: 8),
                Text(tr('ui.video.024')),
              ],
            ),
          ),
        for (final sub in _subs)
          PopupMenuItem<String>(
            value: sub.name,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_activeSub == sub.name)
                  Icon(Icons.check, size: 16, color: scheme.primary)
                else
                  const SizedBox(width: 16),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    sub.lang ?? sub.name,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(
          widget.title ?? tr('ui.video.001'),
          overflow: TextOverflow.ellipsis,
        ),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        actions: [
          if (widget.itemId != null && widget.itemId!.isNotEmpty) _subtitleMenu(),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _error != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(NasTokens.spaceLg),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            tr('ui.video.h891441'),
                            style: TextStyle(
                              color: context.nasDanger,
                              fontSize: NasTokens.fontSubtitle,
                            ),
                          ),
                          const SizedBox(height: NasTokens.spaceSm),
                          Text(
                            _error!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: NasTokens.fontCaption,
                            ),
                          ),
                          const SizedBox(height: NasTokens.spaceMd),
                          OutlinedButton(
                            onPressed: () => Navigator.of(context).maybePop(),
                            child: Text(tr('ui.mount.019')),
                          ),
                        ],
                      ),
                    ),
                  )
                : Video(controller: _controller),
          ),
          Container(
            width: double.infinity,
            color: Colors.black,
            padding: const EdgeInsets.symmetric(
              horizontal: NasTokens.spaceMd,
              vertical: NasTokens.spaceSm,
            ),
            child: Text(
              tr('ui.video.h4ad584'),
              style: TextStyle(
                color: Colors.white70,
                fontSize: NasTokens.fontCaption,
              ),
            ),
          ),
        ],
      ),
    );
  }
}