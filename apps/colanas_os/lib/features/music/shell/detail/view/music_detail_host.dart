import 'package:flutter/material.dart';

import '../../album_detail/view/album_detail_page.dart';
import '../../artist_detail/view/artist_detail_page.dart';
import '../../playlist_detail/view/playlist_detail_page.dart';
import '../controller/music_detail_router.dart';

/// 三级页面宿主：把 [MusicDetailTarget] 分派到具体页面。
///
/// 只做分派、不持有状态 —— controller 由各页面自己在 `initState` 里按 tag 注册，
/// 页面销毁即释放，来回切歌手 / 专辑不会串数据。
class MusicDetailHost extends StatelessWidget {
  const MusicDetailHost({super.key, required this.target});

  final MusicDetailTarget target;

  @override
  Widget build(BuildContext context) {
    if (target.isAlbum) {
      return AlbumDetailPage(
        key: ValueKey<String>('album-detail-${target.key}'),
        name: target.name,
        artist: target.artist,
      );
    }
    if (target.isPlaylist) {
      return PlaylistDetailPage(
        key: ValueKey<String>('playlist-detail-${target.key}'),
        listId: target.listId,
        name: target.name,
      );
    }
    return ArtistDetailPage(
      key: ValueKey<String>('artist-detail-${target.key}'),
      name: target.name,
    );
  }
}
