import 'package:flutter/material.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../compat/getx.dart';
import '../../detail/controller/music_detail_router.dart';
import '../../detail/view/parts/music_detail_pieces.dart';
import '../../detail/view/parts/music_detail_selection_bar.dart';
import '../../detail/view/parts/music_detail_track_table.dart';
import '../../shared/music_paging.dart';
import '../../sub_list/controller/cola_sub_list_controller.dart';
import '../controller/playlist_detail_controller.dart';

/// 歌单详情（三级页面）。
///
/// 形态与专辑详情一致：留在右侧内容区、左侧一二级栏不动、可逐层返回。
/// 差别只在内容 —— 歌单没有发行年份 / 流派 / 简介，也就没有简介区块；
/// 其余（封面、曲目表、播放全部 / 随机 / 收藏 / 下载 / 复制、多选）全部保留。
///
/// 多选工具条上的「移出歌单」是**从歌单移除**（`removeSelectionFromPlaylist`），
/// 不是删除磁盘文件 —— 这一点由 `MusicSubListController.insidePlaylist` 自动决定。
class PlaylistDetailPage extends StatefulWidget {
  const PlaylistDetailPage({
    super.key,
    required this.listId,
    required this.name,
  });

  final int listId;
  final String name;

  @override
  State<PlaylistDetailPage> createState() => _PlaylistDetailPageState();
}

class _PlaylistDetailPageState extends State<PlaylistDetailPage> {
  static const double _wideBreakpoint = 1024;

  final ScrollController _scroll = ScrollController();
  late final String _tag;
  late final PlaylistDetailController _ctrl;

  @override
  void initState() {
    super.initState();
    _tag = 'playlist_detail::${widget.listId}';
    _ctrl = Get.put(
      PlaylistDetailController(name: widget.name, listId: widget.listId),
      tag: _tag,
    );
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    if (Get.isRegistered<MusicSubListController>(tag: _ctrl.tracksTag)) {
      Get.delete<MusicSubListController>(tag: _ctrl.tracksTag);
    }
    if (Get.isRegistered<PlaylistDetailController>(tag: _tag)) {
      Get.delete<PlaylistDetailController>(tag: _tag);
    }
    super.dispose();
  }

  void _onScroll() {
    final tracks = _ctrl.tracks;
    if (tracks == null) return;
    attachPagedScroll(
      _scroll,
      loadMore: () => tracks.loadMore(fromAuto: true).catchError((_) {}),
      onScrolling: tracks.markScrolling,
      threshold: 360,
    );
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= _wideBreakpoint;
    // 与其它三级页一致：复用 App 背景，浮层不透、又不和外层割裂
    final background = context.nasStyle.background;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        background,
        Positioned.fill(
          child: Material(
            type: MaterialType.transparency,
            // 不用 Obx：这里读的 `_ctrl.tracks`/`_ctrl.coverUrl` 只有 items 变化才需要刷新，
            // 而各块自己有内层 Obx。外层写 Obx 但读不到 Rx 会直接抛
            // 「improper use of a GetX」（专辑页就踩过这个）。
            child: Builder(
              builder: (context) {
                final tracks = _ctrl.tracks;
                if (tracks == null) return const MusicDetailSkeleton();
                final body = wide
                    ? _wide(context, tracks)
                    : _narrow(context, tracks);
                return Stack(
                  children: <Widget>[
                    Positioned.fill(child: body),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      // 歌单页只说「移出歌单」，不给删文件的入口
                      child: MusicDetailSelectionBar(
                        controller: tracks,
                        allowDeleteFile: false,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  // ------------------------------------------------------------ 宽屏

  Widget _wide(BuildContext context, MusicSubListController tracks) {
    return LayoutBuilder(
      builder: (context, c) {
        final sideWidth = (c.maxWidth * 0.34).clamp(300.0, 380.0);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SizedBox(width: sideWidth, child: _sidePanel(context, tracks)),
            const VerticalDivider(width: 1),
            Expanded(child: _trackArea(context, tracks)),
          ],
        );
      },
    );
  }

  Widget _sidePanel(BuildContext context, MusicSubListController tracks) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 112),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _backRow(context),
          const SizedBox(height: 8),
          Center(
            child: Obx(() => MusicDetailCover(path: _ctrl.coverUrl, size: 220)),
          ),
          const SizedBox(height: 20),
          Text(
            widget.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Obx(
            () => Text(
              '${tracks.total.value} 首',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 18),
          _actionColumn(context),
        ],
      ),
    );
  }

  Widget _backRow(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: MusicDetailRouter.instance.back,
        icon: const Icon(Icons.arrow_back_ios_new, size: 15),
        label: Text('back'.tr),
        style: TextButton.styleFrom(
          foregroundColor: theme.colorScheme.onSurfaceVariant,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          minimumSize: const Size(0, 32),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
    );
  }

  /// 与专辑页同一套按钮：播放全部 / 随机 / 收藏 / 下载全部 / 复制信息
  Widget _actionColumn(BuildContext context) {
    return Obx(() {
      final empty = _ctrl.isEmpty;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          MusicActionButton(
            icon: Icons.play_arrow,
            label: 'music_detail_play_all'.tr,
            primary: true,
            expanded: true,
            onPressed: empty ? null : _ctrl.playAll,
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              Expanded(
                child: MusicActionButton(
                  icon: Icons.shuffle,
                  label: 'music_detail_shuffle'.tr,
                  expanded: true,
                  onPressed: empty ? null : _ctrl.playShuffled,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: MusicActionButton(
                  icon: _ctrl.allFavorited
                      ? Icons.favorite
                      : Icons.favorite_border,
                  label: 'music_detail_favorite'.tr,
                  expanded: true,
                  active: _ctrl.allFavorited,
                  onPressed: empty ? null : _ctrl.toggleFavoriteAll,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              Expanded(
                child: MusicActionButton(
                  icon: Icons.download_outlined,
                  label: 'music_detail_download_all'.tr,
                  expanded: true,
                  onPressed: empty ? null : _ctrl.downloadAll,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: MusicActionButton(
                  icon: Icons.link,
                  label: 'music_detail_share'.tr,
                  expanded: true,
                  onPressed: _ctrl.copySummary,
                ),
              ),
            ],
          ),
        ],
      );
    });
  }

  Widget _trackArea(BuildContext context, MusicSubListController tracks) {
    final theme = Theme.of(context);
    return Column(
      children: <Widget>[
        Container(
          height: 52,
          padding: const EdgeInsets.fromLTRB(16, 0, 4, 0),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: theme.dividerColor)),
          ),
          child: Row(
            children: <Widget>[
              Obx(
                () => Text(
                  '${tracks.total.value} 首',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const Spacer(),
              Obx(
                () => IconButton(
                  tooltip: 'multi_select'.tr,
                  iconSize: 20,
                  onPressed: tracks.items.isEmpty
                      ? null
                      : tracks.toggleMultiSelectMode,
                  icon: Icon(
                    tracks.isMultiSelectMode.value
                        ? Icons.checklist
                        : Icons.checklist_outlined,
                    color: tracks.isMultiSelectMode.value
                        ? theme.colorScheme.primary
                        : null,
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: MusicDetailTrackTable(
            controller: tracks,
            scrollController: _scroll,
            // 歌单是混合来源：歌手列 + 专辑副标题都有用
            showArtist: true,
            showAlbumSubtitle: true,
          ),
        ),
      ],
    );
  }

  // ------------------------------------------------------------ 窄屏

  Widget _narrow(BuildContext context, MusicSubListController tracks) {
    return CustomScrollView(
      controller: _scroll,
      slivers: <Widget>[
        // 手机端不留展开式头图：外层顶栏已有返回，封面 / 标题 / 操作按钮都在
        // 信息块里，再叠一层 240px 的封面背景只会变成整片空白，还多一次
        // 800px 封面的网络请求。
        SliverToBoxAdapter(child: _narrowHeader(context, tracks)),
        ...buildMusicTrackSlivers(
          context,
          controller: tracks,
          showArtist: true,
          showAlbumSubtitle: true,
          showTableHeader: false,
        ),
      ],
    );
  }

  Widget _narrowHeader(BuildContext context, MusicSubListController tracks) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Obx(
                () => MusicDetailCover(
                  path: _ctrl.coverUrl,
                  size: 84,
                  radius: 12,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      widget.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Obx(
                      () => Text(
                        '${tracks.total.value} 首',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Obx(
            () => Wrap(
              spacing: 10,
              runSpacing: 10,
              children: <Widget>[
                MusicActionButton(
                  icon: Icons.play_arrow,
                  label: 'music_detail_play_all'.tr,
                  primary: true,
                  onPressed: _ctrl.isEmpty ? null : _ctrl.playAll,
                ),
                MusicActionButton(
                  icon: Icons.shuffle,
                  label: 'music_detail_shuffle'.tr,
                  onPressed: _ctrl.isEmpty ? null : _ctrl.playShuffled,
                ),
                MusicActionButton(
                  icon: _ctrl.allFavorited
                      ? Icons.favorite
                      : Icons.favorite_border,
                  label: 'music_detail_favorite'.tr,
                  active: _ctrl.allFavorited,
                  onPressed: _ctrl.isEmpty ? null : _ctrl.toggleFavoriteAll,
                ),
                MusicActionButton(
                  icon: Icons.download_outlined,
                  label: 'music_detail_download_all'.tr,
                  onPressed: _ctrl.isEmpty ? null : _ctrl.downloadAll,
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Divider(color: theme.dividerColor),
        ],
      ),
    );
  }
}
