import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import 'music_player_page.dart';

/// 音乐封面地址（`NasCoverImage` 用）。
String musicCoverUrl(String id) => ApiSession.instance.coverUrl('music', id);

/// 打开内置播放器并开始播放（队列可被插入下一首 / 移出，所以传的是当前页列表）。
void musicPlayTracks(BuildContext context, List<MusicTrack> queue, int index) {
  if (queue.isEmpty) return;
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => MusicPlayerPage(queue: queue, initialIndex: index),
    ),
  );
}

/// 收藏 / 取消收藏。返回服务端是否成功；调用方负责本地集合与提示。
Future<bool> musicSetFavorite(String id, bool favorite) async {
  try {
    await ApiSession.instance.client.musicFavorite(
      body: MusicFavoriteBody(id: id, favorite: favorite),
    );
    return true;
  } catch (_) {
    return false;
  }
}

/// 曲目封面网格卡片：方形封面 + 标题 + 艺人·专辑。
///
/// 悬停出现播放 / 收藏 / 更多，
/// 右键与「更多」共用同一批菜单项；移动端没有悬停，所以「更多」常驻。
class MusicTrackCard extends StatefulWidget {
  const MusicTrackCard({
    super.key,
    required this.track,
    required this.favorite,
    required this.onPlay,
    required this.onToggleFavorite,
    this.menuEntries = const [],
    this.current = false,
    this.playing = false,
  });

  final MusicTrack track;
  final bool favorite;
  final VoidCallback onPlay;
  final VoidCallback onToggleFavorite;
  final List<NasMenuEntry> menuEntries;

  /// 是否是当前播放曲目（标题高亮）
  final bool current;
  final bool playing;

  @override
  State<MusicTrackCard> createState() => _MusicTrackCardState();
}

class _MusicTrackCardState extends State<MusicTrackCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final compact =
        layoutFor(MediaQuery.sizeOf(context).width) == LayoutMode.compact;
    final showActions = _hovered || compact;
    final subtitle = [
      widget.track.artist,
      widget.track.album,
    ].where((v) => (v ?? '').trim().isNotEmpty).join(' · ');

    final cover = Stack(
      fit: StackFit.expand,
      children: [
        if (widget.track.hasCover)
          NasCoverImage(
            url: musicCoverUrl(widget.track.id),
            headers: ApiSession.instance.authHeaders,
            cacheWidth: 360,
            icon: Icons.music_note,
            borderRadius: 0,
          )
        else
          ColoredBox(
            color: scheme.surfaceContainerHighest,
            child: Icon(
              Icons.music_note,
              size: 34,
              color: context.nasTextSecondary,
            ),
          ),
        if (_hovered) ColoredBox(color: Colors.black.withValues(alpha: 0.28)),
        if (_hovered || (widget.current && widget.playing))
          Center(
            child: Material(
              color: Colors.black.withValues(alpha: 0.5),
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: widget.onPlay,
                child: SizedBox(
                  width: 38,
                  height: 38,
                  child: Icon(
                    widget.current && widget.playing
                        ? Icons.pause
                        : Icons.play_arrow,
                    color: Colors.white,
                    size: 22,
                  ),
                ),
              ),
            ),
          ),
        if (showActions || widget.favorite)
          Positioned(
            left: 4,
            top: 4,
            child: _RoundIconButton(
              tooltip: widget.favorite
                  ? tr('music.favorite.remove')
                  : tr('music.favorite.add'),
              icon: widget.favorite ? Icons.favorite : Icons.favorite_border,
              color: widget.favorite ? Colors.redAccent : Colors.white,
              onTap: widget.onToggleFavorite,
            ),
          ),
        if (showActions && widget.menuEntries.isNotEmpty)
          Positioned(
            right: 4,
            top: 4,
            child: _TrackMoreButton(entries: widget.menuEntries),
          ),
      ],
    );

    final child = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(NasTokens.radiusMd),
          child: AspectRatio(aspectRatio: 1, child: cover),
        ),
        const SizedBox(height: 6),
        SizedBox(
          // 42 而不是 44：网格按 0.76 比例算出的高度只比「封面 + 文字」多出不到 1px，
          // 44 会在某些宽度下溢出 0.01px（浏览器里会刷屏）。
          height: 42,
          child: Column(
            children: [
              Text(
                widget.track.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: NasTokens.fontBody,
                  fontWeight: widget.current
                      ? FontWeight.w700
                      : FontWeight.w500,
                  color: widget.current ? scheme.primary : null,
                ),
              ),
              const SizedBox(height: 2),
              if (subtitle.isNotEmpty)
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: NasTokens.fontCaption,
                    color: context.nasTextSecondary,
                  ),
                ),
            ],
          ),
        ),
      ],
    );

    final hoverChild = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(onTap: widget.onPlay, child: child),
    );

    return NasContextMenuRegion(entries: widget.menuEntries, child: hoverChild);
  }
}

class _RoundIconButton extends StatelessWidget {
  const _RoundIconButton({
    required this.tooltip,
    required this.icon,
    required this.onTap,
    this.color = Colors.white,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.black.withValues(alpha: 0.5),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: 28,
            height: 28,
            child: Icon(icon, size: 16, color: color),
          ),
        ),
      ),
    );
  }
}

class _TrackMoreButton extends StatelessWidget {
  const _TrackMoreButton({required this.entries});

  final List<NasMenuEntry> entries;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MenuAnchor(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(scheme.surface),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        side: WidgetStatePropertyAll(BorderSide(color: scheme.outlineVariant)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(NasTokens.radiusMd),
          ),
        ),
      ),
      menuChildren: [
        for (final e in entries)
          if (e.isDivider)
            const Divider(height: 9, thickness: 1)
          else
            MenuItemButton(
              leadingIcon: e.icon == null
                  ? null
                  : Icon(
                      e.icon,
                      size: NasTokens.iconSm,
                      color: e.danger ? scheme.error : scheme.onSurface,
                    ),
              style: MenuItemButton.styleFrom(
                foregroundColor: e.danger ? scheme.error : scheme.onSurface,
              ),
              onPressed: e.onSelected,
              child: Text(e.label),
            ),
      ],
      builder: (context, controller, _) => _RoundIconButton(
        tooltip: tr('common.more'),
        icon: Icons.more_horiz,
        onTap: () => controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }
}

/// 曲目网格：参考实现是 115px 左右的小格，这里按 168 上限自适应列数。
class MusicTrackGridSliver extends StatelessWidget {
  const MusicTrackGridSliver({
    super.key,
    required this.tracks,
    required this.itemBuilder,
  });

  final List<MusicTrack> tracks;
  final Widget Function(BuildContext, MusicTrack, int) itemBuilder;

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(
        NasTokens.spaceMd,
        NasTokens.spaceXs,
        NasTokens.spaceMd,
        NasTokens.spaceMd,
      ),
      sliver: SliverLayoutBuilder(
        builder: (context, constraints) {
          // 参考实现按 115px 小格算列数，行高 = 格子宽 + 封面下方文字的高度。
          // 用 mainAxisExtent（而不是 childAspectRatio）是唯一不会在窄屏溢出的写法：
          // 比例是按格子宽反推高度，行高永远比「封面 + 文字」多出几像素。
          const desiredWidth = 128.0;
          const spacing = NasTokens.spaceSm;
          final content = (constraints.crossAxisExtent - NasTokens.spaceMd * 2)
              .clamp(0.0, double.infinity);
          final count = (content / desiredWidth).floor().clamp(2, 12);
          final cellWidth = ((content - spacing * (count - 1)) / count)
              .floorToDouble();
          return SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: count,
              mainAxisSpacing: spacing,
              crossAxisSpacing: spacing,
              // 封面（= 格子宽）+ 6 间距 + 42 文字 + 4 余量
              mainAxisExtent: cellWidth + 52,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, i) => itemBuilder(context, tracks[i], i),
              childCount: tracks.length,
            ),
          );
        },
      ),
    );
  }
}

/// 曲目行（历史 / 专辑详情 / 歌单详情用），高度与参考实现的 62px 表格行接近。
class MusicTrackRow extends StatelessWidget {
  const MusicTrackRow({
    super.key,
    required this.track,
    required this.onPlay,
    this.leading,
    this.trailing,
    this.trailingWidth = 72,
  });

  final MusicTrack track;
  final VoidCallback onPlay;
  final Widget? leading;
  final Widget? trailing;
  final double trailingWidth;

  @override
  Widget build(BuildContext context) {
    final subtitle = [
      track.artist,
      track.album,
    ].where((v) => (v ?? '').trim().isNotEmpty).join(' · ');
    return InkWell(
      onTap: onPlay,
      child: SizedBox(
        height: 62,
        child: Row(
          children: [
            if (leading != null)
              SizedBox(
                width: 34,
                child: Align(alignment: Alignment.center, child: leading!),
              )
            else
              const SizedBox(width: NasTokens.spaceSm),
            SizedBox(
              width: 46,
              height: 46,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(NasTokens.radiusSm),
                child: track.hasCover
                    ? NasCoverImage(
                        url: musicCoverUrl(track.id),
                        headers: ApiSession.instance.authHeaders,
                        cacheWidth: 96,
                        icon: Icons.music_note,
                        borderRadius: 0,
                      )
                    : ColoredBox(
                        color: Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest,
                        child: Icon(
                          Icons.music_note,
                          size: 20,
                          color: context.nasTextSecondary,
                        ),
                      ),
              ),
            ),
            const SizedBox(width: NasTokens.spaceSm),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    track.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: NasTokens.fontBody),
                  ),
                  if (subtitle.isNotEmpty)
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: NasTokens.fontCaption,
                        color: context.nasTextSecondary,
                      ),
                    ),
                ],
              ),
            ),
            if (track.durationMs != null && trailing == null)
              Text(
                formatDurationMs(track.durationMs!),
                style: TextStyle(
                  fontSize: NasTokens.fontCaption,
                  color: context.nasTextSecondary,
                ),
              ),
            if (trailing != null)
              SizedBox(
                width: trailingWidth,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: trailing!,
                ),
              ),
            const SizedBox(width: NasTokens.spaceXs),
          ],
        ),
      ),
    );
  }
}

/// 顶部工具条：搜索框 + 右侧动作（排序 / 来源筛选 / 刷新等）。
class MusicToolbar extends StatelessWidget {
  const MusicToolbar({
    super.key,
    required this.searchController,
    required this.searchHint,
    this.onSubmitted,
    this.onClear,
    this.actions = const [],
  });

  final TextEditingController searchController;
  final String searchHint;
  final ValueChanged<String>? onSubmitted;
  final VoidCallback? onClear;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        NasTokens.spaceMd,
        NasTokens.spaceSm,
        NasTokens.spaceMd,
        NasTokens.spaceXs,
      ),
      child: Row(
        children: [
          Expanded(
            child: NasSearchField(
              controller: searchController,
              hintText: searchHint,
              onSubmitted: onSubmitted,
              onClear: onClear,
            ),
          ),
          if (actions.isNotEmpty) const SizedBox(width: NasTokens.spaceSm),
          ...actions,
        ],
      ),
    );
  }
}

/// 排序按钮：选中项打勾 + 升 / 降序切换。
class MusicSortButton extends StatelessWidget {
  const MusicSortButton({
    super.key,
    required this.value,
    required this.desc,
    required this.options,
    required this.onChanged,
  });

  /// `(排序字段, 文案 key)`
  final String value;
  final bool desc;
  final List<(String, String)> options;
  final void Function(String value, bool desc) onChanged;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: tr('music.sort.title'),
      icon: const Icon(Icons.sort, size: 20),
      onSelected: (v) {
        if (v == 'toggle') {
          onChanged(value, !desc);
        } else {
          onChanged(v, desc);
        }
      },
      itemBuilder: (_) => [
        for (final (field, key) in options)
          CheckedPopupMenuItem<String>(
            value: field,
            checked: value == field,
            child: Text(tr(key)),
          ),
        const PopupMenuDivider(),
        PopupMenuItem<String>(
          value: 'toggle',
          child: Row(
            children: [
              Icon(desc ? Icons.arrow_downward : Icons.arrow_upward, size: 16),
              const SizedBox(width: NasTokens.spaceXs),
              Text(tr(desc ? 'music.sort.desc' : 'music.sort.asc')),
            ],
          ),
        ),
      ],
    );
  }
}

/// 栏目页头部（标题 + 右侧动作）。
class MusicPaneHeader extends StatelessWidget {
  const MusicPaneHeader({super.key, required this.title, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        NasTokens.spaceMd,
        NasTokens.spaceSm,
        NasTokens.spaceSm,
        NasTokens.spaceXs,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: NasTokens.fontSubtitle,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// 搜索防抖（300ms）：参考实现的搜索框是边输入边过滤。
class MusicSearchDebouncer {
  MusicSearchDebouncer(this.onFire);

  final VoidCallback onFire;
  Timer? _timer;

  void run() {
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 300), onFire);
  }

  void dispose() => _timer?.cancel();
}
