import '../../../compat/cola_device_utils.dart';

import 'package:flutter/material.dart';

import '../../app_components/cola_disc_cover.dart';
import '../../../compat/host.dart';
import 'cola_stage_disc_block.dart';
import 'cola_stage_lyric_block.dart';

/// 窄屏/宽屏两个分支共用的构造产物：两个主区块 + 悬浮小封面要用的公共参数。
/// 收成值对象后，分支只负责布局，不再各自拼一遍构造参数。
class _FullScreenBlocks {
  const _FullScreenBlocks({
    required this.disc,
    required this.lyric,
    required this.isPlaying,
    required this.discAsset,
    required this.coverUrl,
  });

  final Widget disc;
  final Widget lyric;
  final bool isPlaying;
  final String discAsset;
  final String coverUrl;
}

class MusicPlayCtrlFullScreenBody extends StatefulWidget {
  final Duration trackDuration;
  final String title;
  final Duration position;
  final VoidCallback? onToggleFavorite;
  final VoidCallback onShowProperties;
  final VoidCallback onShowPlaylist;
  final VoidCallback onNextDiscStyle;
  final String musicPath;
  final String lyrics;
  final bool isPlaying;
  final bool isFavorite;
  final bool favoriteLoading;
  final String discAsset;
  final String coverUrl;
  final String artist;
  final String album;
  final Future<void> Function(Duration position) onSeekTo;

  const MusicPlayCtrlFullScreenBody({
    required this.trackDuration,
    required this.title,
    required this.position,
    required this.onToggleFavorite,
    required this.onShowProperties,
    required this.onShowPlaylist,
    required this.onSeekTo,
    required this.onNextDiscStyle,
    required this.musicPath,
    required this.lyrics,
    super.key,
    required this.isPlaying,
    required this.isFavorite,
    required this.favoriteLoading,
    required this.discAsset,
    required this.coverUrl,
    required this.artist,
    required this.album,
  });

  @override
  State<MusicPlayCtrlFullScreenBody> createState() =>
      _MusicPlayCtrlFullScreenBodyState();
}

class _MusicPlayCtrlFullScreenBodyState
    extends State<MusicPlayCtrlFullScreenBody> {
  bool _showLyrics = false;

  bool _readShowLyrics() =>
      CacheManager().getBool(CacheKeys.musicFullScreenShowLyrics) ?? false;

  void _writeShowLyrics(bool value) =>
      CacheManager().setBool(CacheKeys.musicFullScreenShowLyrics, value);

  @override
  void initState() {
    super.initState();
    _showLyrics = _readShowLyrics();
  }

  void _setShowLyrics(bool value) {
    if (_showLyrics == value) return;
    setState(() => _showLyrics = value);
    _writeShowLyrics(value);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (ctx, c) {
        final isNarrow = DeviceUtils.isMobile;
        final blocks = _FullScreenBlocks(
          disc: MusicPlayCtrlFullScreenDiscBlock(
            onToggleFavorite: widget.onToggleFavorite,
            onTapDisc: isNarrow ? () => _setShowLyrics(true) : null,
            onShowProperties: widget.onShowProperties,
            onShowPlaylist: widget.onShowPlaylist,
            onNextDiscStyle: widget.onNextDiscStyle,
            isPlaying: widget.isPlaying,
            isFavorite: widget.isFavorite,
            favoriteLoading: widget.favoriteLoading,
            discAsset: widget.discAsset,
            coverUrl: widget.coverUrl,
          ),
          lyric: MusicPlayCtrlFullScreenLyricBlock(
            trackDuration: widget.trackDuration,
            title: widget.title,
            position: widget.position,
            onSeekTo: widget.onSeekTo,
            musicPath: widget.musicPath,
            lyrics: widget.lyrics,
            centerMode: isNarrow,
            artist: widget.artist,
            album: widget.album,
          ),
          isPlaying: widget.isPlaying,
          discAsset: widget.discAsset,
          coverUrl: widget.coverUrl,
        );
        if (isNarrow) {
          final current = _showLyrics
              ? Stack(
                  children: <Widget>[
                    Positioned.fill(child: Center(child: blocks.lyric)),
                    Positioned(
                      right: 12.0,
                      bottom: 12.0,
                      child: MusicPlayDiscCover(
                        outerSize: 50,
                        onTap: () => _setShowLyrics(false),
                        isPlaying: blocks.isPlaying,
                        innerSize: 34,
                        discAsset: blocks.discAsset,
                        coverUrl: blocks.coverUrl,
                      ),
                    ),
                  ],
                )
              : blocks.disc;
          return Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
            child: AnimatedSwitcher(
              switchOutCurve: Curves.easeIn,
              switchInCurve: Curves.easeOut,
              layoutBuilder: (currentChild, previousChildren) {
                return Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.center,
                  children: <Widget>[
                    ...previousChildren,
                    if (currentChild != null) currentChild,
                  ],
                );
              },
              duration: const Duration(milliseconds: 180),
              child: KeyedSubtree(
                key: ValueKey<bool>(_showLyrics),
                child: Center(child: current),
              ),
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(22, 0, 22, 8),
          child: Row(
            children: <Widget>[
              Expanded(flex: 5, child: blocks.disc),
              const SizedBox(width: 28.0),
              Expanded(flex: 6, child: blocks.lyric),
            ],
          ),
        );
      },
    );
  }
}
