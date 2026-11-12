import 'package:flutter/material.dart';

import '../../../compat/cola_device_utils.dart';
import '../../../compat/host.dart';
import '../../app_components/cola_disc_cover.dart';
import 'cola_stage_disc_block.dart';
import 'cola_stage_lyric_block.dart';

/// 舞台中段：窄屏在「唱片 / 歌词」间切换，宽屏左右并排。
class ColaMusicStageBody extends StatefulWidget {
  const ColaMusicStageBody({
    super.key,
    required this.isPlaying,
    required this.coverUrl,
    required this.discAsset,
    required this.musicPath,
    required this.trackDuration,
    required this.onToggleFavorite,
    required this.favoriteLoading,
    required this.isFavorite,
    required this.onNextDiscStyle,
    required this.onShowProperties,
    required this.onShowPlaylist,
    required this.title,
    required this.album,
    required this.artist,
    required this.lyrics,
    required this.position,
    required this.onSeekTo,
  });

  final bool isPlaying;
  final String coverUrl;
  final String discAsset;
  final String musicPath;
  final Duration trackDuration;
  final VoidCallback? onToggleFavorite;
  final bool favoriteLoading;
  final bool isFavorite;
  final VoidCallback onNextDiscStyle;
  final VoidCallback onShowProperties;
  final VoidCallback onShowPlaylist;
  final String title;
  final String album;
  final String artist;
  final String lyrics;
  final Duration position;
  final Future<void> Function(Duration position) onSeekTo;

  @override
  State<ColaMusicStageBody> createState() => _ColaMusicStageBodyState();
}

class _ColaMusicStageBodyState extends State<ColaMusicStageBody> {
  bool _lyricsOn = false;

  @override
  void initState() {
    super.initState();
    _lyricsOn =
        CacheManager().getBool(CacheKeys.musicFullScreenShowLyrics) ?? false;
  }

  /// 窄屏下唱片与歌词互斥显示，选择结果记到本地缓存，下次进入沿用。
  void _switchTo(bool lyrics) {
    if (_lyricsOn == lyrics) return;
    setState(() => _lyricsOn = lyrics);
    CacheManager().setBool(CacheKeys.musicFullScreenShowLyrics, lyrics);
  }

  Widget _discArea(bool narrow) {
    return ColaMusicStageDisc(
      onToggleFavorite: widget.onToggleFavorite,
      onTapDisc: narrow ? () => _switchTo(true) : null,
      onShowProperties: widget.onShowProperties,
      onShowPlaylist: widget.onShowPlaylist,
      onNextDiscStyle: widget.onNextDiscStyle,
      isPlaying: widget.isPlaying,
      isFavorite: widget.isFavorite,
      favoriteLoading: widget.favoriteLoading,
      discAsset: widget.discAsset,
      coverUrl: widget.coverUrl,
    );
  }

  Widget _lyricArea(bool narrow) {
    return ColaMusicStageLyrics(
      trackDuration: widget.trackDuration,
      title: widget.title,
      position: widget.position,
      onSeekTo: widget.onSeekTo,
      musicPath: widget.musicPath,
      lyrics: widget.lyrics,
      centerMode: narrow,
      artist: widget.artist,
      album: widget.album,
    );
  }

  /// 歌词页右下角的小唱片，点一下切回大唱片。
  Widget _miniDisc() {
    return MusicPlayDiscCover(
      outerSize: 50,
      innerSize: 34,
      isPlaying: widget.isPlaying,
      discAsset: widget.discAsset,
      coverUrl: widget.coverUrl,
      onTap: () => _switchTo(false),
    );
  }

  Widget _narrowLayout() {
    final Widget stage = _lyricsOn
        ? Stack(
            children: <Widget>[
              Positioned.fill(child: Center(child: _lyricArea(true))),
              Positioned(right: 12.0, bottom: 12.0, child: _miniDisc()),
            ],
          )
        : _discArea(true);

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 180),
        switchInCurve: Curves.easeOut,
        switchOutCurve: Curves.easeIn,
        layoutBuilder: (current, previous) => Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: <Widget>[...previous, ?current],
        ),
        child: KeyedSubtree(
          key: ValueKey<bool>(_lyricsOn),
          child: Center(child: stage),
        ),
      ),
    );
  }

  Widget _wideLayout() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 0, 22, 8),
      child: Row(
        children: <Widget>[
          Expanded(flex: 5, child: _discArea(false)),
          const SizedBox(width: 28.0),
          Expanded(flex: 6, child: _lyricArea(false)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (_, _) => DeviceUtils.isMobile ? _narrowLayout() : _wideLayout(),
    );
  }
}
