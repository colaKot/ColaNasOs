import '../../../compat/ui_kit.dart';

import 'package:flutter/material.dart';
import 'package:flutter_context_menu/flutter_context_menu.dart';

import '../../../compat/cola_api_controller.dart';
import '../../../compat/cola_app_routes.dart';
import '../../../compat/cola_device_utils.dart';
import '../../../compat/getx.dart';
import '../../../compat/host.dart';
import '../../../compat/spinkit.dart';
import '../../../list/models/cola_list_models.dart';
import '../../../list/view/parts/cola_item_context_menu.dart';
import '../../../play_service/controller/cola_player_controller.dart';
import '../../../sub_list/controller/cola_sub_list_controller.dart';

/// 专辑 / 歌手详情页的曲目表。
///
/// 与曲库下钻用的 `MusicSubListTable` 共用同一个 controller（分页、多选、播放续页、
/// 收藏 / 移出歌单 / 删除都在 controller 里），只是**外观按详情页 PRD 重做**：
/// PC 是带表头的表格（hover 高亮 + 右键菜单），移动端是单行列表。
///
/// [showArtist]：专辑页要显示每首的歌手（合辑里一首一个歌手），歌手页整页都是
/// 同一个人，再重复一遍纯属噪音 —— PRD 明确要求隐藏。
class MusicDetailTrackTable extends StatefulWidget {
  const MusicDetailTrackTable({
    super.key,
    required this.controller,
    required this.scrollController,
    this.showArtist = true,
    this.showAlbumSubtitle = false,
    this.trailing,
  });

  final MusicSubListController controller;
  final ScrollController scrollController;
  final bool showArtist;

  /// 副标题显示专辑名（歌手页用；专辑页整页同一个专辑，不需要）
  final bool showAlbumSubtitle;

  /// 曲目列表之后的附加区块（专辑简介）
  final Widget? trailing;

  @override
  State<MusicDetailTrackTable> createState() => _MusicDetailTrackTableState();
}

class _MusicDetailTrackTableState extends State<MusicDetailTrackTable> {
  bool get _isCompact => DeviceUtils.isMobile || DeviceUtils.isPhone(context);

  @override
  Widget build(BuildContext context) {
    final compact = _isCompact;
    return Obx(() {
      final ctrl = widget.controller;
      return Scrollbar(
        thumbVisibility: !compact,
        controller: widget.scrollController,
        child: CustomScrollView(
          controller: widget.scrollController,
          slivers: buildMusicTrackSlivers(
            context,
            controller: ctrl,
            showArtist: widget.showArtist,
            showAlbumSubtitle: widget.showAlbumSubtitle,
            showTableHeader: !compact,
            trailing: widget.trailing,
          ),
        ),
      );
    });
  }
}

/// 曲目区的 sliver 序列（表头 + 行 + 底部三态 + 播放器避让 + [trailing]）。
///
/// 为什么是「返回 sliver 列表」而不是一个 Widget：窄屏（<1024）整页是一个
/// `CustomScrollView`（SliverAppBar + 信息块 + 曲目 + 简介必须一起滚），
/// 宽屏则是左侧固定面板 + 右侧独立滚动。两种布局必须共用同一份行实现，
/// 否则「点击播放 / 右键菜单 / 多选」会在两套代码里各修一遍。
List<Widget> buildMusicTrackSlivers(
  BuildContext context, {
  required MusicSubListController controller,
  required bool showArtist,
  bool showAlbumSubtitle = false,
  bool showTableHeader = true,
  Widget? trailing,
  bool reservePlayerSpace = true,
}) {
  final compact = DeviceUtils.isMobile || DeviceUtils.isPhone(context);
  final items = controller.items;
  return <Widget>[
    if (showTableHeader)
      SliverToBoxAdapter(child: _header(context, showArtist)),
    if (items.isEmpty)
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 48),
          child: controller.loading.value
              ? const Center(child: CircularProgressIndicator())
              : const MusicEmptyState(),
        ),
      )
    else
      SliverList(
        delegate: SliverChildBuilderDelegate((context, index) {
          final item = items[index];
          if (compact) {
            return _MobileRow(
              key: ValueKey('detail_track_m_${item.id}'),
              item: item,
              index: index,
              controller: controller,
              showAlbumSubtitle: showAlbumSubtitle,
            );
          }
          return _PcRow(
            key: ValueKey('detail_track_pc_${item.id}'),
            item: item,
            index: index,
            controller: controller,
            showArtist: showArtist,
            showAlbumSubtitle: showAlbumSubtitle,
          );
        }, childCount: items.length),
      ),
    if (items.isNotEmpty)
      SliverToBoxAdapter(child: _Footer(controller: controller)),
    if (trailing != null) SliverToBoxAdapter(child: trailing),
    SliverToBoxAdapter(
      child: SizedBox(
        height: reservePlayerSpace
            ? (controller.isMultiSelectMode.value
                  ? 150
                  : 112 + MediaQuery.of(context).padding.bottom)
            : 24,
      ),
    ),
  ];
}

Widget _header(BuildContext context, bool showArtist) {
  final theme = Theme.of(context);
  final style = theme.textTheme.labelMedium?.copyWith(
    color: theme.colorScheme.onSurfaceVariant,
    fontWeight: FontWeight.w600,
  );
  return Container(
    height: 38,
    padding: const EdgeInsets.fromLTRB(16, 0, 12, 0),
    decoration: BoxDecoration(
      border: Border(bottom: BorderSide(color: theme.dividerColor)),
    ),
    child: Row(
      children: <Widget>[
        SizedBox(width: 40, child: Text('#', style: style)),
        const SizedBox(width: 12),
        Expanded(child: Text('music_detail_col_track'.tr, style: style)),
        if (showArtist)
          SizedBox(
            width: 180,
            child: Text('music_detail_col_artist'.tr, style: style),
          ),
        SizedBox(
          width: 72,
          child: Text(
            'music_detail_col_duration'.tr,
            textAlign: TextAlign.center,
            style: style,
          ),
        ),
        SizedBox(
          width: 52,
          child: Text(
            'music_detail_col_actions'.tr,
            textAlign: TextAlign.center,
            style: style,
          ),
        ),
      ],
    ),
  );
}

// ---------------------------------------------------------------- 共用逻辑

/// 播放地址解析（与列表页保持同一套兜底顺序）
String detailPlayablePath(MusicListItem item) {
  if (item.isSeries) {
    final p = item.firstFilePath.trim();
    if (p.isNotEmpty) return p;
  }
  final full = item.fullPath.trim();
  if (full.isNotEmpty) return full;
  final name = item.filename.trim();
  final base = item.path.trim();
  if (base.isNotEmpty && name.isNotEmpty) return '$base/$name';
  return base;
}

bool isTrackCurrent(MusicListItem item, MusicPlayServiceController ctrl) {
  final idx = ctrl.currentIndex.value;
  if (idx < 0 || idx >= ctrl.playlist.length) return false;
  final current = ctrl.playlist[idx];
  final a = detailPlayablePath(current);
  return a.isNotEmpty && a == detailPlayablePath(item);
}

/// 打开「所在文件夹」（桌面进文件应用并定位，Web / 移动端跳文件页）
void openTrackInFiles(BuildContext context, MusicListItem item) {
  final full = item.fullPath.trim();
  final base = item.path.trim();
  final target = full.isNotEmpty
      ? browseFolderPathMusic(full)
      : browseFolderPathMusic(base);
  if (target.isEmpty) return;
  if (DeviceUtils.isDesktop && Get.isRegistered<PcHomeController>()) {
    PcHomeController.instance.openFolderAt(target);
    return;
  }
  AppRoutes.toFiles(initialPath: target);
}

/// 三点 / 右键共用的一份菜单项
List<ContextMenuEntry<dynamic>> detailTrackMenuEntries(
  BuildContext context,
  MusicSubListController ctrl,
  MusicListItem item,
  bool selectionMode,
) {
  return MusicItemContextMenu.buildEntries(
    selectionMode: selectionMode,
    isFavorite: item.isFavorite,
    inPlayList: ctrl.insidePlaylist,
    isSameMachine:
        DeviceUtils.isDesktopOrWeb && ApiController.instance.isSameMachine,
    onFileBrowse: () => openTrackInFiles(context, item),
    onToggleFavorite: () => ctrl.toggleFavorite(item),
    onDownload: () => ctrl.downloadItem(item),
    onAddToPlayList: () => ctrl.addToPlayListItem(item),
    onRemoveFromPlayList: () => ctrl.removeFromPlayListItem(item),
    onDelete: () => ctrl.deleteItem(item),
  );
}

Widget _wave(double size, Color color) =>
    SpinKitWave(size: size, itemCount: 5, color: color.withValues(alpha: 0.9));

String _duration(int seconds) =>
    FormatUtil.formatDurationSeconds(seconds, autoPadZero: true);

// ---------------------------------------------------------------- PC 行

class _PcRow extends StatefulWidget {
  const _PcRow({
    super.key,
    required this.item,
    required this.index,
    required this.controller,
    required this.showArtist,
    required this.showAlbumSubtitle,
  });

  final MusicListItem item;
  final int index;
  final MusicSubListController controller;
  final bool showArtist;
  final bool showAlbumSubtitle;

  @override
  State<_PcRow> createState() => _PcRowState();
}

class _PcRowState extends State<_PcRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Obx(() {
      final ctrl = widget.controller;
      final selectionMode = ctrl.isMultiSelectMode.value;
      final selected = ctrl.selectedItems.contains(widget.item.id);
      final playCtrl = MusicPlayServiceController.instance;
      final current = isTrackCurrent(widget.item, playCtrl);
      final playing = current && playCtrl.isPlaying.value;

      final titleStyle = theme.textTheme.bodyMedium?.copyWith(
        fontWeight: FontWeight.w600,
        color: current ? theme.colorScheme.primary : null,
      );
      final subStyle = theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
      );

      final entries = detailTrackMenuEntries(
        context,
        ctrl,
        widget.item,
        selectionMode,
      );

      final row = InkWell(
        onTap: () {
          if (selectionMode) {
            ctrl.toggleSelection(widget.item.id);
            return;
          }
          if (current) {
            playing ? playCtrl.pause() : playCtrl.play();
            return;
          }
          ctrl.playAt(widget.index);
        },
        child: MouseRegion(
          onEnter: (_) {
            if (ctrl.isScrolling.value || _hovered) return;
            setState(() => _hovered = true);
          },
          onExit: (_) {
            if (!_hovered) return;
            setState(() => _hovered = false);
          },
          child: Container(
            height: 52,
            padding: const EdgeInsets.fromLTRB(16, 0, 12, 0),
            color: selected
                ? theme.colorScheme.primary.withValues(alpha: 0.08)
                : (_hovered
                      ? theme.colorScheme.onSurface.withValues(alpha: 0.04)
                      : Colors.transparent),
            child: Row(
              children: <Widget>[
                SizedBox(
                  width: 40,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: selectionMode
                        ? CustomCheckbox(
                            value: selected,
                            onChanged: (_) =>
                                ctrl.toggleSelection(widget.item.id),
                            isCircle: false,
                          )
                        : playing
                        ? _wave(14, theme.colorScheme.primary)
                        : Text('${widget.index + 1}', style: subStyle),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        widget.item.title.trim().isEmpty
                            ? widget.item.displayTitle
                            : widget.item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: titleStyle,
                      ),
                      if (widget.showAlbumSubtitle &&
                          widget.item.album.trim().isNotEmpty)
                        Text(
                          widget.item.album,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: subStyle,
                        ),
                    ],
                  ),
                ),
                if (widget.showArtist)
                  SizedBox(
                    width: 180,
                    child: Text(
                      widget.item.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: subStyle,
                    ),
                  ),
                SizedBox(
                  width: 72,
                  child: Text(
                    _duration(widget.item.duration),
                    textAlign: TextAlign.center,
                    style: subStyle,
                  ),
                ),
                SizedBox(
                  width: 52,
                  child: Opacity(
                    // 常显但淡一点：触屏 PC 上没有 hover，全靠它才能打开菜单
                    opacity: _hovered ? 1 : 0.35,
                    child: IconButton(
                      tooltip: 'more'.tr,
                      iconSize: 18,
                      onPressed: () {
                        final box = context.findRenderObject() as RenderBox?;
                        final origin = box == null
                            ? Offset.zero
                            : box.localToGlobal(
                                Offset(box.size.width - 40, box.size.height),
                              );
                        ContextMenuUtil.showAtPosition(
                          context,
                          position: origin,
                          entries: entries,
                        );
                      },
                      icon: const Icon(Icons.more_horiz),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      if (entries.isEmpty) return row;
      return ContextMenuUtil.region(child: row, entries: entries);
    });
  }
}

// ---------------------------------------------------------------- 移动行

class _MobileRow extends StatefulWidget {
  const _MobileRow({
    super.key,
    required this.item,
    required this.index,
    required this.controller,
    required this.showAlbumSubtitle,
  });

  final MusicListItem item;
  final int index;
  final MusicSubListController controller;
  final bool showAlbumSubtitle;

  @override
  State<_MobileRow> createState() => _MobileRowState();
}

class _MobileRowState extends State<_MobileRow> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Obx(() {
      final ctrl = widget.controller;
      final selectionMode = ctrl.isMultiSelectMode.value;
      final selected = ctrl.selectedItems.contains(widget.item.id);
      final playCtrl = MusicPlayServiceController.instance;
      final current = isTrackCurrent(widget.item, playCtrl);
      final playing = current && playCtrl.isPlaying.value;
      final titleStyle = theme.textTheme.bodyMedium?.copyWith(
        fontWeight: FontWeight.w600,
        color: current ? theme.colorScheme.primary : null,
      );
      final subStyle = theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
      );
      // 移动端只有一行副标题的位置：专辑页显示歌手（合辑里一首一个歌手），
      // 歌手页显示专辑名（整页同一个歌手，再显示歌手名是纯噪音）
      final subtitle = widget.showAlbumSubtitle
          ? widget.item.album.trim()
          : widget.item.artist.trim();

      return InkWell(
        onTap: () {
          if (selectionMode) {
            ctrl.toggleSelection(widget.item.id);
            return;
          }
          if (current) {
            playing ? playCtrl.pause() : playCtrl.play();
            return;
          }
          ctrl.playAt(widget.index);
        },
        child: Container(
          height: 56,
          padding: const EdgeInsets.fromLTRB(14, 0, 6, 0),
          color: selected
              ? theme.colorScheme.primary.withValues(alpha: 0.08)
              : Colors.transparent,
          child: Row(
            children: <Widget>[
              SizedBox(
                width: 28,
                child: Center(
                  child: selectionMode
                      ? CustomCheckbox(
                          value: selected,
                          onChanged: (_) =>
                              ctrl.toggleSelection(widget.item.id),
                          isCircle: false,
                        )
                      : playing
                      ? _wave(13, theme.colorScheme.primary)
                      : Text('${widget.index + 1}', style: subStyle),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      widget.item.title.trim().isEmpty
                          ? widget.item.displayTitle
                          : widget.item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: titleStyle,
                    ),
                    if (subtitle.isNotEmpty)
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: subStyle,
                      ),
                  ],
                ),
              ),
              Text(_duration(widget.item.duration), style: subStyle),
              IconButton(
                tooltip: 'more'.tr,
                iconSize: 20,
                onPressed: () {
                  final entries = detailTrackMenuEntries(
                    context,
                    ctrl,
                    widget.item,
                    selectionMode,
                  );
                  if (entries.isEmpty) return;
                  ContextMenuUtil.showAtPosition(
                    context,
                    position: Offset(
                      MediaQuery.sizeOf(context).width - 56,
                      MediaQuery.sizeOf(context).height * 0.6,
                    ),
                    entries: entries,
                  );
                },
                icon: const Icon(Icons.more_horiz),
              ),
            ],
          ),
        ),
      );
    });
  }
}

// ---------------------------------------------------------------- 底部三态

class _Footer extends StatelessWidget {
  const _Footer({required this.controller});

  final MusicSubListController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Obx(() {
      if (controller.loadingMore.value) {
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 18),
          child: Center(
            child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        );
      }
      if (!controller.hasMore.value) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 18),
          child: Center(
            child: Text(
              'music_no_more'.tr,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        );
      }
      return Center(
        child: TextButton(
          onPressed: () =>
              controller.loadMore(fromAuto: false).catchError((_) {}),
          child: Text('load_more'.tr),
        ),
      );
    });
  }
}
