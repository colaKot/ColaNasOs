import 'package:flutter/material.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../../shell/app_nav_shell.dart';
import '../../../shell/app_shell.dart';
import '../../../shell/shell_back.dart';
import 'album_artist_list/controller/cola_album_artist_controller.dart';
import 'album_artist_list/view/cola_album_artist_page.dart';
import 'cache_setting/view/cola_cache_settings_view.dart';
import 'compat/cola_app_routes.dart';
import 'compat/cola_custom_colors.dart';
import 'compat/getx.dart';
import 'compat/host.dart';
import 'detail/controller/music_detail_router.dart';
import 'detail/view/music_detail_host.dart';
import 'lastfm_setting/view/music_lastfm_settings_view.dart';
import 'list/controller/cola_list_controller.dart';
import 'list/view/cola_list_page.dart';
import 'music_main/controller/cola_main_controller.dart';
import 'play_service/controller/cola_player_controller.dart';
import 'play_service/lastfm_scrobbler.dart';
import 'play_service/play_ctrl_bottom/cola_dock.dart';
import 'play_service/play_ctrl_fullscreen/cola_stage_sheet.dart';
import 'playlist/view/cola_playlist_view.dart';
import 'source_setting/view/cola_source_settings_view.dart';
import 'sub_list/view/cola_sub_list_overlay.dart';

/// 是否启用音乐的 1:1 移植版。
/// 置 false 可一行回退到旧的 `MusicShellPage`（旧实现文件全部保留）。
const bool kMusicShell = true;

/// 音乐应用入口（移植版）。
///
/// 与原版的差别只有一处：原版左栏是 `MusicLeftMenu`（自带「曲库 / 歌单 /
/// 设置」三段折叠菜单），本项目统一走 `AppNavShell` + `contracts/apps.json#nav`，
/// 所以这里**不搬左栏**，菜单项来自契约，页面映射在 [_content]。
///
/// 参考 `MusicMainView._buildRight` 里除了页面还有两样东西必须一起搬：
/// 底部播放条 `MusicPlayCtrlBottomBar` 和全屏播放器 `MusicPlayCtrlFullScreenSheet`，
/// 它们是全局的（任何页面都能唤起），因此挂在壳这一层而不是页面里。
class MusicShellView extends StatefulWidget {
  const MusicShellView({super.key});

  @override
  State<MusicShellView> createState() => _MusicShellViewState();
}

class _MusicShellViewState extends State<MusicShellView> {
  late final MusicMainController _ctrl;

  /// 专辑 / 歌手三级页面的栈（不走 Navigator：要保留左侧一二级栏）
  late final MusicDetailRouter _detail;

  /// 上一次渲染的二级菜单 key：换菜单时把详情栈清掉，
  /// 避免「从专辑页切到歌单再切回来，专辑页又冒出来」。
  String _activeKey = '';

  /// Last.fm 播放上报：只在音乐壳存活期间挂钩
  LastfmScrobbler? _scrobbler;

  @override
  void initState() {
    super.initState();
    _ctrl = Get.put(MusicMainController());
    _detail = Get.put(MusicDetailRouter());
    _scrobbler = LastfmScrobbler(MusicPlayServiceController.instance);
    // 「打开所在文件夹」「回到首页」在参考实现里走 GetX 命名路由，
    // 这里注入到统一桌面壳（AppShell.openApp）。
    AppRoutes.toFilesHandler = (_) => AppShell.openApp('files');
    AppRoutes.toHomeHandler = () => AppShell.openApp('home');
  }

  @override
  void dispose() {
    _scrobbler?.dispose();
    _scrobbler = null;
    AppRoutes.toFilesHandler = null;
    AppRoutes.toHomeHandler = null;
    if (Get.isRegistered<MusicDetailRouter>()) {
      Get.delete<MusicDetailRouter>(force: true);
    }
    Get.delete<MusicMainController>(force: true);
    super.dispose();
  }

  /// 契约 nav key → 页面。
  ///
  /// key 与 `contracts/apps.json#apps[music].nav` 一一对应；
  /// `tool/check/app-nav-check.js` 会双向对账，改契约必须同步改这里。
  /// 页面外面那层 Stack 是参考 `MusicMainView._buildRight` 的形态：
  /// 底部常驻播放条（`hidePlayerBar` 可关），页面本身撑满。
  Widget _content(String key) {
    final Widget page;
    switch (key) {
      case 'favorites':
        page = const MusicListPage(
          key: ValueKey('shell-music-favorites'),
          isFavorite: true,
          listType: '',
          initialSortBy: MusicListSortBy.favoriteTime,
          initialSortOrder: MusicListSortOrder.desc,
        );
        break;
      case 'history':
        page = MusicSubListOverlay(
          keyType: 'history',
          name: 'music_menu_library_history'.tr,
          isHistory: true,
          onClose: () => _ctrl.selectPage('library.songs'),
        );
        break;
      case 'albums':
        page = const AlbumArtistListPage(
          key: ValueKey('shell-music-albums'),
          keyType: 'album',
          initialSortBy: AlbumArtistListSortBy.count,
          initialSortOrder: AlbumArtistListSortOrder.desc,
        );
        break;
      case 'artists':
        page = const AlbumArtistListPage(
          key: ValueKey('shell-music-artists'),
          keyType: 'artist',
          initialSortBy: AlbumArtistListSortBy.count,
          initialSortOrder: AlbumArtistListSortOrder.desc,
        );
        break;
      case 'files':
        // 参考侧是独立「文件视图」页；本项目已有正式的文件应用，
        // 这里保留同形态入口，真正浏览交给「文件」应用。
        page = const PcFolderViewPage(moduleType: FolderViewModuleType.music);
        break;
      case 'playlists':
        page = const PlayListListView();
        break;
      case 'settings.source':
        page = const MusicSourceSettingsView();
        break;
      case 'settings.client':
        page = const MusicCacheSettingsView();
        break;
      case 'settings.app':
        // 契约里这一项原本没有对应页面（参考实现只有「来源 / 缓存」两页），
        // 现在放 Last.fm 在线数据源与账号绑定。
        page = const MusicLastfmSettingsView();
        break;
      // nav-default: songs
      default:
        page = const MusicListPage(
          key: ValueKey('shell-music-songs'),
          listType: '',
          initialSortBy: MusicListSortBy.title,
          initialSortOrder: MusicListSortOrder.asc,
        );
        break;
    }

    // 换二级菜单 ⇒ 关掉三级页面。放在帧后执行：这里正处在 AppNavShell 的 build
    // 流程里，同步改 Rx 会让上层在下一次 build 之前就收到通知。
    if (_activeKey != key) {
      _activeKey = key;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _detail.closeAll();
      });
    }

    return Obx(() {
      final detail = _detail.top;
      return Stack(
        children: <Widget>[
          // 内容区背景层：音乐壳的页面大多不铺底（透明），
          // 少了这一层就会直接看到黑底/漏出后面的东西。
          Positioned.fill(child: context.nasStyle.background),
          Positioned.fill(
            child: KeyedSubtree(
              key: ValueKey<String>('shell-music-page-$key'),
              child: page,
            ),
          ),
          // 三级页面：只盖内容区，左侧一二级栏与底部播放条都在它外面。
          // SubPageScope 负责把「返回」注册到顶栏（桌面右上角 / 手机左上角）。
          if (detail != null)
            Positioned.fill(
              child: SubPageScope(
                active: true,
                onBack: _detail.back,
                child: MusicDetailHost(
                  key: ValueKey<String>('music-detail-${detail.key}'),
                  target: detail,
                ),
              ),
            ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Obx(
              () => _ctrl.hidePlayerBar.value
                  ? const SizedBox.shrink()
                  : MusicPlayCtrlBottomBar(
                      onOpenFullscreen: _ctrl.openFullPlayer,
                    ),
            ),
          ),
        ],
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    // 移植页有 13+ 处读 theme.extension<CustomColors>()：不注册时恒为 null，
    // 背景落空 + 页面按深色配色写死 → 手机上整片发灰、白字看不清。
    // 只在音乐壳子树注册，不动全局主题。
    final themed = theme.copyWith(
      extensions: <ThemeExtension<dynamic>>[
        CustomColors(
          nestedCardColor: dark
              ? cs.surfaceContainerLow
              : cs.surfaceContainerLowest,
          emptyCardColor: cs.surfaceContainerLow,
          leftTreeBgColor: dark ? cs.surfaceContainerHigh : cs.surfaceContainer,
          // 透明 = 各页面/遮罩不铺自己的底，统一透出 ShellView 里铺的那层 App 背景。
          // 以前这里是 `cs.surface`，深色主题下等于纯黑，音乐壳所有二级页都像「黑洞」。
          mainContentBgColor: Colors.transparent,
          oprationBarBgColor: cs.surfaceContainerLow,
          hairlineBorderColor: cs.outlineVariant,
        ),
      ],
    );
    return Theme(
      data: themed,
      child: GetBuilder<MusicMainController>(
        init: _ctrl,
        builder: (ctrl) => Stack(
          children: <Widget>[
            Positioned.fill(
              child: AppNavShell(
                appId: 'music',
                // 2026-11-08 用户要求：打开就落在「我的歌单」，不再先过一遍歌曲列表。
                // 手机端底部 tab 的排列也把 playlists 放到了第一位（apps.json#nav.mobile）。
                defaultKey: 'playlists',
                content: _content,
              ),
            ),
            // 全屏播放器：盖在整个二级栏之上（参考侧也是这样）
            Positioned.fill(
              child: Obx(
                () => ctrl.showFullPlayer.value
                    ? MusicPlayCtrlFullScreenSheet(
                        key: const ValueKey('shell-music-full-player'),
                        onClose: ctrl.closeFullPlayer,
                      )
                    : const SizedBox.shrink(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
