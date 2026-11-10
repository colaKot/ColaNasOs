import 'package:flutter/material.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../compat/cola_device_utils.dart';
import '../../compat/getx.dart';
import '../../detail/controller/music_detail_controllers.dart';
import '../../detail/controller/music_detail_router.dart';
import '../../detail/models/music_detail_models.dart';
import '../../detail/view/parts/music_detail_pieces.dart';
import '../../detail/view/parts/music_detail_selection_bar.dart';
import '../../detail/view/parts/music_detail_track_table.dart';
import '../../shared/music_paging.dart';
import '../../shared/music_primitives.dart';
import '../../sub_list/controller/cola_sub_list_controller.dart';

/// 歌手详情（三级页面）。
///
/// 与专辑页同一套三级导航（右侧内容区、左栏不动、可逐层返回）。
///
/// 按 PRD 定的几条硬规则：
/// - **不再单独设「热门歌曲」板块**，热度只是「全部歌曲」里的一种排序；
/// - 曲目行**不重复显示歌手名**（整页都是这个人），时长 / 更多菜单保留；
/// - 同名同歌手只留最新一版（服务端 `dedupe=1`）；
/// - 搜索时隐藏「收录专辑」板块；
/// - 只展示库里已有的资源，不拉外网歌曲、无评论、无推荐。
class ArtistDetailPage extends StatefulWidget {
  const ArtistDetailPage({super.key, required this.name});

  final String name;

  @override
  State<ArtistDetailPage> createState() => _ArtistDetailPageState();
}

class _ArtistDetailPageState extends State<ArtistDetailPage> {
  static const double _wideBreakpoint = 1024;

  final ScrollController _scroll = ScrollController();
  late final String _tag;
  late final ArtistDetailController _ctrl;

  @override
  void initState() {
    super.initState();
    _tag = 'artist_detail::${widget.name}';
    _ctrl = Get.put(ArtistDetailController(name: widget.name), tag: _tag);
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    if (Get.isRegistered<MusicSubListController>(tag: _ctrl.tracksTag)) {
      Get.delete<MusicSubListController>(tag: _ctrl.tracksTag);
    }
    if (Get.isRegistered<ArtistDetailController>(tag: _tag)) {
      Get.delete<ArtistDetailController>(tag: _tag);
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
    // 复用 App 的背景 Widget（极光 / 白板 / 云母），
    // 既挡住下面的列表，又与其它页面完全同色（不再是纯黑一块）
    final background = context.nasStyle.background;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        background,
        Positioned.fill(
          child: Material(
            type: MaterialType.transparency,
            child: Obx(() {
              final info = _ctrl.info.value;
              if (info == null) {
                return _ctrl.failed.value
                    ? MusicDetailErrorView(
                        message: 'music_detail_load_failed'.tr,
                        onRetry: _ctrl.load,
                      )
                    : MusicDetailSkeleton(wide: wide);
              }
              if (!info.found) {
                return MusicDetailErrorView(
                  message: 'music_detail_artist_not_found'.tr,
                  onRetry: _ctrl.load,
                );
              }
              final tracks = _ctrl.tracks;
              if (tracks == null) return const MusicDetailSkeleton();
              return Stack(
                children: <Widget>[
                  Positioned.fill(
                    child: wide
                        ? _wide(context, info, tracks)
                        : _narrow(context, info, tracks),
                  ),
                  // 多选工具条：贴底（不要固定 112 —— 那是给播放条的，播放条没出来时
                  // 就变成一条大缝，看起来像「浮在半空」）
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: MusicDetailSelectionBar(controller: tracks),
                  ),
                ],
              );
            }),
          ),
        ),
      ],
    );
  }

  // ------------------------------------------------------------ 宽屏

  Widget _wide(
    BuildContext context,
    ArtistDetailInfo info,
    MusicSubListController tracks,
  ) {
    return LayoutBuilder(
      builder: (context, c) {
        final sideWidth = (c.maxWidth * 0.34).clamp(300.0, 380.0);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SizedBox(width: sideWidth, child: _sidePanel(context, info)),
            const VerticalDivider(width: 1),
            Expanded(child: _rightArea(context, info, tracks)),
          ],
        );
      },
    );
  }

  Widget _sidePanel(BuildContext context, ArtistDetailInfo info) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 112),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _backRow(context),
          const SizedBox(height: 8),
          Center(
            child: MusicDetailCover(
              path: info.coverPath,
              size: 180,
              circle: true,
            ),
          ),
          const SizedBox(height: 18),
          Center(
            child: Text(
              info.name,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Center(
            child: Text(
              '${info.albumCount} 张专辑 · ${info.trackCount} 首'
              '${info.genre.isEmpty ? '' : ' · ${info.genre}'}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          if (info.crowd.hasStats) ...<Widget>[
            const SizedBox(height: 6),
            Center(
              child: Text(
                '${formatCompactCount(info.crowd.listeners)} 听众 · '
                '${formatCompactCount(info.crowd.playcount)} 播放',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          _actionColumn(context),
          const SizedBox(height: 18),
          MusicIntroSection(
            title: 'music_detail_intro'.tr,
            text: info.crowd.summary,
            expanded: _ctrl.introExpanded.value,
            onToggle: _ctrl.toggleIntro,
            padding: EdgeInsets.zero,
          ),
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

  Widget _actionColumn(BuildContext context) {
    return Obx(
      () => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          MusicActionButton(
            icon: Icons.play_arrow,
            label: 'music_detail_play_all'.tr,
            primary: true,
            expanded: true,
            onPressed: _ctrl.isEmpty ? null : _ctrl.playAll,
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              Expanded(
                child: MusicActionButton(
                  icon: Icons.shuffle,
                  label: 'music_detail_shuffle'.tr,
                  expanded: true,
                  onPressed: _ctrl.isEmpty ? null : _ctrl.playShuffled,
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
                  onPressed: _ctrl.isEmpty ? null : _ctrl.toggleFavoriteAll,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          MusicActionButton(
            icon: Icons.download_outlined,
            label: 'music_detail_download_all'.tr,
            expanded: true,
            onPressed: _ctrl.isEmpty ? null : _ctrl.downloadAll,
          ),
        ],
      ),
    );
  }

  Widget _rightArea(
    BuildContext context,
    ArtistDetailInfo info,
    MusicSubListController tracks,
  ) {
    final theme = Theme.of(context);
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
          child: MusicSearchField(
            searchText: _ctrl.searchText,
            onChanged: _ctrl.onSearchChanged,
            onClear: _ctrl.clearSearch,
            hintText: 'music_detail_search_hint'.tr,
            height: 38,
          ),
        ),
        // 搜索时隐藏「收录专辑」（PRD 规则）
        Obx(
          () => _ctrl.searchText.value.trim().isEmpty
              ? ArtistAlbumRail(
                  albums: info.albums,
                  onOpen: (album) => MusicDetailRouter.instance.open(
                    MusicDetailTarget.album(
                      name: album.name,
                      artist: info.name,
                    ),
                  ),
                )
              : const SizedBox.shrink(),
        ),
        _sectionBar(context, tracks),
        Expanded(
          child: MusicDetailTrackTable(
            controller: tracks,
            scrollController: _scroll,
            showArtist: false,
            showAlbumSubtitle: true,
          ),
        ),
        Divider(height: 1, color: theme.dividerColor),
      ],
    );
  }

  Widget _sectionBar(BuildContext context, MusicSubListController tracks) {
    final theme = Theme.of(context);
    return Container(
      height: 52,
      padding: const EdgeInsets.fromLTRB(16, 0, 4, 0),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: theme.dividerColor),
          bottom: BorderSide(color: theme.dividerColor),
        ),
      ),
      child: Row(
        children: <Widget>[
          Text(
            'music_detail_all_tracks'.tr,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 12),
          Obx(
            () => Text(
              '${tracks.total.value}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const Spacer(),
          _sortButton(context, tracks),
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
    );
  }

  Widget _sortButton(BuildContext context, MusicSubListController tracks) {
    final theme = Theme.of(context);
    return Obx(() {
      final current = tracks.sortBy.value;
      String labelOf(MusicSubListSortBy by) => switch (by) {
        MusicSubListSortBy.hot => 'music_detail_sort_hot'.tr,
        MusicSubListSortBy.title => 'music_detail_sort_name'.tr,
        _ => 'music_detail_sort_album'.tr,
      };
      return PopupMenuButton<MusicSubListSortBy>(
        tooltip: 'music_detail_sort'.tr,
        initialValue: current,
        onSelected: _ctrl.setSortBy,
        itemBuilder: (context) => <PopupMenuEntry<MusicSubListSortBy>>[
          PopupMenuItem(
            value: MusicSubListSortBy.albumOrder,
            child: Text('music_detail_sort_album'.tr),
          ),
          PopupMenuItem(
            value: MusicSubListSortBy.hot,
            child: Text('music_detail_sort_hot'.tr),
          ),
          PopupMenuItem(
            value: MusicSubListSortBy.title,
            child: Text('music_detail_sort_name'.tr),
          ),
        ],
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                Icons.swap_vert,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 4),
              Text(
                labelOf(current),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
    });
  }

  // ------------------------------------------------------------ 窄屏

  Widget _narrow(
    BuildContext context,
    ArtistDetailInfo info,
    MusicSubListController tracks,
  ) {
    final compact = DeviceUtils.isPhone(context) || DeviceUtils.isMobile;
    return CustomScrollView(
      controller: _scroll,
      slivers: <Widget>[
        // 手机端不留展开式头图：外层顶栏已有返回，头像 / 名称 / 按钮都在信息块
        // 里，260px 的封面背景在手机上只是一整片空白 + 一次大图请求。
        SliverToBoxAdapter(child: _narrowHeader(context, info)),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: MusicSearchField(
              searchText: _ctrl.searchText,
              onChanged: _ctrl.onSearchChanged,
              onClear: _ctrl.clearSearch,
              hintText: 'music_detail_search_hint'.tr,
              height: 38,
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Obx(
            () => _ctrl.searchText.value.trim().isEmpty
                ? ArtistAlbumRail(
                    albums: info.albums,
                    onOpen: (album) => MusicDetailRouter.instance.open(
                      MusicDetailTarget.album(
                        name: album.name,
                        artist: info.name,
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ),
        SliverToBoxAdapter(child: _sectionBar(context, tracks)),
        ...buildMusicTrackSlivers(
          context,
          controller: tracks,
          showArtist: false,
          showAlbumSubtitle: true,
          showTableHeader: false,
          reservePlayerSpace: true,
        ),
        if (compact) const SliverToBoxAdapter(child: SizedBox(height: 8)),
      ],
    );
  }

  Widget _narrowHeader(BuildContext context, ArtistDetailInfo info) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              MusicDetailCover(path: info.coverPath, size: 84, circle: true),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      info.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${info.albumCount} 张专辑 · ${info.trackCount} 首'
                      '${info.genre.isEmpty ? '' : ' · ${info.genre}'}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    if (info.crowd.hasStats)
                      Text(
                        '${formatCompactCount(info.crowd.listeners)} 听众',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
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
              ],
            ),
          ),
          MusicIntroSection(
            title: 'music_detail_intro'.tr,
            text: info.crowd.summary,
            expanded: _ctrl.introExpanded.value,
            onToggle: _ctrl.toggleIntro,
            padding: const EdgeInsets.only(top: 6),
          ),
        ],
      ),
    );
  }
}
