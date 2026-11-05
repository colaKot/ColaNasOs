import 'package:flutter/material.dart';

import '../../shell/app_nav_shell.dart';
import 'music_library_pages.dart';
import 'music_page.dart';
import 'music_playlists_page.dart';
import 'music_settings_pages.dart';
import 'music_source_page.dart';

/// 音乐主页：左侧二级导航 + 内容区。
///
///   曲库（歌曲 / 收藏 / 播放历史 / 专辑 / 歌手 / 文件夹）
///   歌单（我的歌单 / 合集）
///   设置（音乐来源 / 音乐设置 / 缓存）
///
/// 曲库本身是**全局共享**的，所以这里没有「音乐库」概念，也没有新建库入口 ——
/// 来源在 设置 → 音乐来源 里维护。歌单 / 收藏 / 历史 / 合集按用户隔离。
class MusicShellPage extends StatefulWidget {
  const MusicShellPage({super.key});

  @override
  State<MusicShellPage> createState() => _MusicShellPageState();
}

class _MusicShellPageState extends State<MusicShellPage> {
  Widget _content(String key) {
    switch (key) {
      case 'favorites':
        return const MusicFavoritesPage();
      case 'history':
        return const MusicHistoryPage();
      case 'albums':
        return const MusicGroupedPage(groupBy: 'album');
      case 'artists':
        return const MusicGroupedPage(groupBy: 'artist');
      case 'files':
        return const MusicGroupedPage(groupBy: 'folder');
      case 'playlists':
        return const MusicPlaylistsPage();
      case 'collections':
        return const MusicCollectionsPage();
      case 'settings.source':
        return const MusicSourcePage();
      case 'settings.app':
        return const MusicAppSettingsPage();
      case 'settings.client':
        return const MusicClientSettingsPage();
      // nav-default: songs
      default:
        return const MusicPage(embedded: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppNavShell(appId: 'music', defaultKey: 'songs', content: _content);
  }
}
