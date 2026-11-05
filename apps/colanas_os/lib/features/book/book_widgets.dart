import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';

/// 书封地址（`NasCoverImage` 用）。
String bookCoverUrl(String id) => ApiSession.instance.coverUrl('book', id);

/// 书籍封面卡片：2:3 封面 + 标题 + 作者，悬浮出现收藏 / 更多，右键与「更多」同一批动作。
class BookCard extends StatefulWidget {
  const BookCard({
    super.key,
    required this.book,
    required this.onOpen,
    required this.onToggleFavorite,
    this.menuEntries = const [],
    this.current = false,
    this.selectionMode = false,
    this.selected = false,
    this.onToggleSelected,
  });

  final BookItem book;
  final VoidCallback onOpen;
  final VoidCallback onToggleFavorite;
  final List<NasMenuEntry> menuEntries;

  /// 历史 / 当前阅读项高亮
  final bool current;

  /// 多选态：隐藏菜单、右下角显示勾选框
  final bool selectionMode;
  final bool selected;
  final VoidCallback? onToggleSelected;

  @override
  State<BookCard> createState() => _BookCardState();
}

class _BookCardState extends State<BookCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final compact =
        layoutFor(MediaQuery.sizeOf(context).width) == LayoutMode.compact;
    final showActions = !widget.selectionMode && (_hovered || compact);
    final progress = widget.book.progressPercent;

    final cover = Stack(
      fit: StackFit.expand,
      children: [
        if (widget.book.hasCover)
          NasCoverImage(
            url: bookCoverUrl(widget.book.id),
            headers: ApiSession.instance.authHeaders,
            cacheWidth: 360,
            fallbackText: widget.book.title,
            icon: Icons.menu_book_outlined,
            borderRadius: 0,
          )
        else
          NasCoverImage(
            url: null,
            fallbackText: widget.book.title,
            icon: Icons.menu_book_outlined,
            borderRadius: 0,
          ),
        if (_hovered) ColoredBox(color: Colors.black.withValues(alpha: 0.24)),
        if (_hovered)
          Center(
            child: Material(
              color: Colors.black.withValues(alpha: 0.5),
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: widget.onOpen,
                child: const SizedBox(
                  width: 38,
                  height: 38,
                  child: Icon(Icons.menu_book, color: Colors.white, size: 22),
                ),
              ),
            ),
          ),
        if (!widget.selectionMode && (showActions || widget.book.favorite))
          Positioned(
            left: 4,
            top: 4,
            child: _RoundIconButton(
              tooltip: widget.book.favorite
                  ? tr('ui.book.021')
                  : tr('ui.book.014'),
              icon: widget.book.favorite
                  ? Icons.favorite
                  : Icons.favorite_border,
              color: widget.book.favorite ? Colors.redAccent : Colors.white,
              onTap: widget.onToggleFavorite,
            ),
          ),
        if (showActions && widget.menuEntries.isNotEmpty)
          Positioned(
            right: 4,
            top: 4,
            child: _BookMoreButton(entries: widget.menuEntries),
          ),
        if (widget.selectionMode)
          Positioned(
            right: 4,
            bottom: 4,
            child: Icon(
              widget.selected
                  ? Icons.check_circle
                  : Icons.radio_button_unchecked,
              color: widget.selected ? Colors.lightGreenAccent : Colors.white,
              size: 22,
            ),
          ),
        Positioned(
          left: 4,
          bottom: 4,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(NasTokens.radiusSm),
            ),
            child: Text(
              widget.book.format.toUpperCase(),
              style: const TextStyle(
                color: Colors.white,
                fontSize: NasTokens.fontMicro,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
        if (progress != null && progress > 0)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: LinearProgressIndicator(
              value: progress / 100,
              minHeight: 3,
              backgroundColor: Colors.black26,
            ),
          ),
      ],
    );

    final child = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(NasTokens.radiusMd),
          child: AspectRatio(aspectRatio: 2 / 3, child: cover),
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: 42,
          child: Column(
            children: [
              Text(
                widget.book.title,
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
              Text(
                [
                  widget.book.author ?? tr('ui.book.h9c5bde'),
                  if (progress != null && progress > 0) '$progress%',
                ].join(' · '),
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
      child: GestureDetector(
        onTap: widget.selectionMode ? widget.onToggleSelected : widget.onOpen,
        child: child,
      ),
    );

    return NasContextMenuRegion(
      entries: widget.selectionMode ? const [] : widget.menuEntries,
      child: hoverChild,
    );
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

class _BookMoreButton extends StatelessWidget {
  const _BookMoreButton({required this.entries});

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

/// 书籍网格：封面是 2:3，行高 = 格子宽 * 1.5 + 文字区，避免比例反推在窄屏溢出。
class BookGridSliver extends StatelessWidget {
  const BookGridSliver({
    super.key,
    required this.books,
    required this.itemBuilder,
  });

  final List<BookItem> books;
  final Widget Function(BuildContext, BookItem, int) itemBuilder;

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
              mainAxisExtent: cellWidth * 1.5 + 52,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, i) => itemBuilder(context, books[i], i),
              childCount: books.length,
            ),
          );
        },
      ),
    );
  }
}

/// 书籍行（历史 / 书单详情用）。
class BookRow extends StatelessWidget {
  const BookRow({
    super.key,
    required this.book,
    required this.onOpen,
    this.leading,
    this.trailing,
    this.trailingWidth = 72,
  });

  final BookItem book;
  final VoidCallback onOpen;
  final Widget? leading;
  final Widget? trailing;
  final double trailingWidth;

  @override
  Widget build(BuildContext context) {
    final progress = book.progressPercent ?? 0;
    return InkWell(
      onTap: onOpen,
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
              width: 42,
              height: 56,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(NasTokens.radiusSm),
                child: book.hasCover
                    ? NasCoverImage(
                        url: bookCoverUrl(book.id),
                        headers: ApiSession.instance.authHeaders,
                        cacheWidth: 96,
                        fallbackText: book.title,
                        borderRadius: 0,
                      )
                    : NasCoverImage(
                        url: null,
                        fallbackText: book.title,
                        borderRadius: 0,
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
                    book.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: NasTokens.fontBody),
                  ),
                  Text(
                    [
                      book.author ?? tr('ui.book.h9c5bde'),
                      book.format.toUpperCase(),
                      if (progress > 0) '$progress%',
                    ].join(' · '),
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

/// 顶部工具条：搜索 + 右侧动作。
class BookToolbar extends StatelessWidget {
  const BookToolbar({
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

class BookSortButton extends StatelessWidget {
  const BookSortButton({
    super.key,
    required this.value,
    required this.desc,
    required this.options,
    required this.onChanged,
  });

  final String value;
  final bool desc;
  final List<(String, String)> options;
  final void Function(String value, bool desc) onChanged;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: tr('book.sort.title'),
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
              Text(tr(desc ? 'book.sort.desc' : 'book.sort.asc')),
            ],
          ),
        ),
      ],
    );
  }
}

class BookPaneHeader extends StatelessWidget {
  const BookPaneHeader({super.key, required this.title, this.trailing});

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

/// 搜索防抖（300ms）
class BookSearchDebouncer {
  BookSearchDebouncer(this.onFire);

  final VoidCallback onFire;
  Timer? _timer;

  void run() {
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 300), onFire);
  }

  void dispose() => _timer?.cancel();
}
