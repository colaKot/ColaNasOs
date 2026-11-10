import 'package:flutter/material.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../compat/getx.dart';
import '../../shared/music_paging.dart';
import '../../sub_list/controller/cola_sub_list_controller.dart';
import '../../detail/controller/music_detail_controllers.dart';
import '../../detail/controller/music_detail_router.dart';
import '../../detail/models/music_detail_models.dart';
import '../../detail/view/parts/music_detail_pieces.dart';
import '../../detail/view/parts/music_detail_selection_bar.dart';
import '../../detail/view/parts/music_detail_track_table.dart';

/// 专辑详情（三级页面）。
///
/// 形态要求（用户 2026-11-09 明确）：**留在右侧内容区**，左侧一二级栏不动、
/// 能一层层返回 —— 所以它不是 `Navigator.push` 的整页，而是由
/// `MusicDetailRouter` 在 `MusicShellView` 的内容区里叠出来的一层。
///
/// 断点沿用项目既有口径：>= 1024 左右分栏（左 380 固定信息面板 + 右独立滚动），
/// < 1024 单列（紧凑信息块 + 曲目列表，顶部不留展开头图）。
///
/// 不做评论、不做相似专辑推荐（PRD 明确移除）。
class AlbumDetailPage extends StatefulWidget {
  const AlbumDetailPage({super.key, required this.name, this.artist = ''});

  final String name;
  final String artist;

  @override
  State<AlbumDetailPage> createState() => _AlbumDetailPageState();
}

class _AlbumDetailPageState extends State<AlbumDetailPage> {
  static const double _wideBreakpoint = 1024;

  final ScrollController _scroll = ScrollController();
  late final String _tag;
  late final AlbumDetailController _ctrl;

  @override
  void initState() {
    super.initState();
    _tag = 'album_detail::${widget.name}::${widget.artist}';
    _ctrl = Get.put(
      AlbumDetailController(name: widget.name, artist: widget.artist),
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
    if (Get.isRegistered<AlbumDetailController>(tag: _tag)) {
      Get.delete<AlbumDetailController>(tag: _tag);
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
    // 三级页是叠在列表之上的一层：不能透明（会漏出下面的列表），也不能用
    // `surface`（深色主题下是纯黑，跟外层的极光背景完全两个世界）。
    // 直接复用 App 的**背景 Widget**，做到和其他页面一模一样。
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
                  message: 'music_detail_album_not_found'.tr,
                  onRetry: _ctrl.load,
                );
              }
              final tracks = _ctrl.tracks;
              if (tracks == null) return const MusicDetailSkeleton();
              final body = wide
                  ? _wide(context, info, tracks)
                  : _narrow(context, info, tracks);
              return Stack(
                children: <Widget>[
                  Positioned.fill(child: body),
                  // 多选工具条：贴底（内部自己判断显示与否，并在多选时让播放条让位）
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
    AlbumDetailInfo info,
    MusicSubListController tracks,
  ) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SizedBox(width: 380, child: _sidePanel(context, info)),
        const VerticalDivider(width: 1),
        Expanded(child: _trackArea(context, info, tracks)),
      ],
    );
  }

  Widget _sidePanel(BuildContext context, AlbumDetailInfo info) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 112),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _backRow(context),
          const SizedBox(height: 8),
          Center(child: MusicDetailCover(path: info.coverPath, size: 220)),
          const SizedBox(height: 20),
          Text(
            info.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          if (info.artist.isNotEmpty)
            InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: () => MusicDetailRouter.instance.open(
                MusicDetailTarget.artist(info.artist),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      info.artist,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 2),
                    Icon(
                      Icons.chevron_right,
                      size: 18,
                      color: theme.colorScheme.primary,
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 10),
          _typeChip(context, info),
          const SizedBox(height: 14),
          MusicMetaLine(
            label: 'music_detail_publish'.tr,
            value: info.year.isEmpty ? '—' : info.year,
          ),
          MusicMetaLine(label: 'music_detail_genre'.tr, value: info.genre),
          MusicMetaLine(
            label: 'music_detail_track_count'.tr,
            value: '${info.trackCount} 首',
          ),
          MusicMetaLine(
            label: 'music_detail_total_duration'.tr,
            value: formatLongDuration(info.totalDuration),
          ),
          if (info.crowd.hasStats)
            MusicMetaLine(
              label: 'music_detail_hot'.tr,
              value:
                  '${formatCompactCount(info.crowd.playcount)} 播放 · '
                  '${formatCompactCount(info.crowd.listeners)} 听众',
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

  Widget _typeChip(BuildContext context, AlbumDetailInfo info) {
    final theme = Theme.of(context);
    final label = info.trackCount <= 3
        ? 'music_detail_type_single'.tr
        : (info.trackCount <= 6
              ? 'music_detail_type_ep'.tr
              : 'music_detail_type_album'.tr);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.4),
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

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

  Widget _trackArea(
    BuildContext context,
    AlbumDetailInfo info,
    MusicSubListController tracks,
  ) {
    final theme = Theme.of(context);
    return Column(
      children: <Widget>[
        Container(
          height: 52,
          // 右侧只留 4：IconButton 自带 8 的内边距，再加 12 会显得按钮浮在中间
          padding: const EdgeInsets.fromLTRB(16, 0, 4, 0),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: theme.dividerColor)),
          ),
          child: Row(
            children: <Widget>[
              // ⚠️ 这里**不能**包 Obx：`info` 是普通值不是 Rx，Obx 里一个 observable
              // 都读不到时 GetX 会直接抛「improper use of a GetX」，整棵子树构建失败
              // （现象就是「打开专辑报错 + 页面透明 + 巨额 overflow」）。
              Flexible(
                child: Text(
                  '${info.trackCount} 首 · ${formatLongDuration(info.totalDuration)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
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
            showArtist: true,
            trailing: _intro(context),
          ),
        ),
      ],
    );
  }

  Widget _intro(BuildContext context) => Obx(() {
    final info = _ctrl.info.value;
    return MusicIntroSection(
      title: 'music_detail_intro'.tr,
      text: info?.crowd.summary ?? '',
      expanded: _ctrl.introExpanded.value,
      onToggle: _ctrl.toggleIntro,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
    );
  });

  // ------------------------------------------------------------ 窄屏

  Widget _narrow(
    BuildContext context,
    AlbumDetailInfo info,
    MusicSubListController tracks,
  ) {
    return CustomScrollView(
      controller: _scroll,
      slivers: <Widget>[
        // 手机端不留展开式头图：外层顶栏已有返回，名称 / 信息 / 操作按钮都在
        // 信息块里，280px 的封面背景在手机上只是一整片空白 + 一次大图请求。
        SliverToBoxAdapter(child: _narrowHeader(context, info)),
        ...buildMusicTrackSlivers(
          context,
          controller: tracks,
          showArtist: true,
          showTableHeader: false,
          trailing: _intro(context),
        ),
      ],
    );
  }

  Widget _narrowHeader(BuildContext context, AlbumDetailInfo info) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            info.name,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          if (info.artist.isNotEmpty)
            InkWell(
              onTap: () => MusicDetailRouter.instance.open(
                MusicDetailTarget.artist(info.artist),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  info.artist,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              _typeChip(context, info),
              Text(
                info.year.isEmpty ? '' : info.year,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              Text(
                '${info.trackCount} 首 · ${formatLongDuration(info.totalDuration)}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              if (info.crowd.hasStats)
                Text(
                  '${formatCompactCount(info.crowd.playcount)} 播放',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
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
