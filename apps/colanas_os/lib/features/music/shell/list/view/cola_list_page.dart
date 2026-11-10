import '../../compat/ui_kit.dart';

import 'dart:async';
import 'dart:math' as math;

import '../../compat/cola_custom_colors.dart';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../compat/getx.dart';
import '../../compat/cola_device_utils.dart';
import '../../shared/music_paging.dart';
import '../controller/cola_list_controller.dart';
import 'parts/cola_list_grid.dart';
import 'parts/cola_list_multi_select_bottom_bar.dart';
import 'parts/cola_list_top_bar.dart';
import '../../play_service/controller/cola_player_controller.dart';
import '../../music_main/controller/cola_main_controller.dart';
import '../../sub_list/controller/cola_sub_list_controller.dart';
import '../../sub_list/view/cola_sub_list_overlay.dart';

class MusicListPage extends StatefulWidget {
  final int? seriesIndexId;
  final String listType;
  final int? listId;
  final bool isFavorite;
  final MusicListSortOrder initialSortOrder;
  final MusicListSortBy initialSortBy;
  final int? collectionId;
  const MusicListPage({
    super.key,
    this.listType = '',
    this.listId,
    this.seriesIndexId,
    this.collectionId,
    this.isFavorite = false,
    this.initialSortBy = MusicListSortBy.mtime,
    this.initialSortOrder = MusicListSortOrder.desc,
  });

  @override
  State<MusicListPage> createState() => _MusicListPageState();
}

class _MusicListPageState extends State<MusicListPage> {
  final ScrollController _scrollController = ScrollController();
  Timer? _throttleTimer;
  bool? _lastShowMultiBar;
  late final String _controllerTag;
  MusicListController? _controller;
  Timer? _autoTimer;
  bool _dragging = false;
  bool _marqueeActive = false;
  bool _multiModeAtStart = false;
  bool _additiveAtStart = false;
  Offset _lastGridLocal = const Offset(0, 0);
  Offset? _pointerDownGridPos;
  static const double _kMarqueeThreshold = 8;

  String _rectCacheKey = '';
  List<_GridRectEntry> _gridRectCache = const [];
  List<double> _gridRectBottoms = const [];
  double _gridViewportHeight = 0;

  @override
  void initState() {
    super.initState();
    _controllerTag =
        'music_list_${widget.listType}_${widget.listId ?? 0}_${widget.seriesIndexId ?? 0}_${widget.collectionId ?? 0}_${widget.isFavorite}_${widget.initialSortBy}_${widget.initialSortOrder}_${UniqueKey()}';
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _autoTimer?.cancel();
    _throttleTimer?.cancel();
    if (Get.isRegistered<MusicMainController>()) {
      final mainCtrl = Get.find<MusicMainController>();
      if (mainCtrl.hidePlayerBar.value) {
        mainCtrl.hidePlayerBar.value = false;
      }
    }
    if (Get.isRegistered<MusicSubListOverlayController>()) {
      final overlayCtrl = Get.find<MusicSubListOverlayController>();
      overlayCtrl.close();
    }
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    final listState =
        _controller ??
        (Get.isRegistered<MusicListController>(tag: _controllerTag)
            ? Get.find<MusicListController>(tag: _controllerTag)
            : null);
    if (listState == null) return;
    // 列表是翻页模式：触底不累加下一页，loadMore 留空；这里只借公共组件
    // 统一滚动阈值，并把框选滚动与 markScrolling 收进 onScrolling。
    attachPagedScroll(
      _scrollController,
      loadMore: () {},
      onScrolling: () {
        if (_dragging) {
          listState.updateDragSelection(
            _lastGridLocal,
            scrollOffset: _scrollController.offset,
          );
          _scheduleHitTest();
        }
        listState.markScrolling();
      },
      threshold: 360,
    );
  }

  bool get _isAdditiveSelectionActive {
    final keys = HardwareKeyboard.instance.logicalKeysPressed;
    return keys.contains(LogicalKeyboardKey.shiftLeft) ||
        keys.contains(LogicalKeyboardKey.shiftRight);
  }

  void _scheduleHitTest() {
    if (_throttleTimer?.isActive ?? false) return;
    _throttleTimer = Timer(const Duration(milliseconds: 60), _performHitTest);
  }

  int _lowerBoundBottom(List<double> bottoms, double value) {
    var hi = bottoms.length;
    var lo = 0;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (bottoms[mid] <= value) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  Set<int> _performHitTest() {
    if (!_dragging) return const {};
    final listState = _controller;
    if (listState == null) return const {};
    final rect = listState.selectionRectContent.value;
    if (rect == null) return const {};
    final start = _lowerBoundBottom(_gridRectBottoms, rect.top);
    final hits = <int>{};
    for (var i = start; i < _gridRectCache.length; i++) {
      final r = _gridRectCache[i].rect;
      if (r.top > rect.bottom) break;
      if (r.overlaps(rect)) hits.add(_gridRectCache[i].id);
    }
    listState.updateDragPreview(hits, additive: _additiveAtStart);
    return hits;
  }

  void _ensureAutoTimer() {
    _autoTimer ??= Timer.periodic(const Duration(milliseconds: 30), (_) {
      if (!_dragging) return;
      if (!_scrollController.hasClients) return;
      final pos = _scrollController.position;
      if (!pos.hasPixels) return;
      const edge = 30.0;
      double delta = 0.0;
      if (_lastGridLocal.dy < edge) {
        final t = (edge - _lastGridLocal.dy).clamp(0.0, edge) / edge;
        delta = -12.0 * t;
      } else {
        final distBottom = (_gridViewportHeight - _lastGridLocal.dy);
        if (distBottom < edge) {
          final t = (edge - distBottom).clamp(0.0, edge) / edge;
          delta = 12.0 * t;
        }
      }
      if (delta != 0.0) {
        final target = (pos.pixels + delta).clamp(0.0, pos.maxScrollExtent);
        _scrollController.jumpTo(target);
      }
    });
  }

  void _rebuildGridRectCache({required List items, required double maxWidth}) {
    const rightPadding = 16.0;
    const leftPadding = 16.0;
    const desiredWidth = 115.0;
    final contentWidth = math.max(0.0, maxWidth - leftPadding - rightPadding);
    const spacing = 4.0;
    final crossAxisCount = (contentWidth / desiredWidth).floor().clamp(2, 10);
    final totalSpacing = spacing * (crossAxisCount - 1);
    final cellW = ((contentWidth - totalSpacing) / crossAxisCount)
        .floorToDouble();
    final cellH = cellW + 56.0;

    final bottoms = <double>[];
    final entries = <_GridRectEntry>[];
    for (var i = 0; i < items.length; i++) {
      final id = (items[i].id as int?) ?? 0;
      if (id <= 0) continue;
      final col = i % crossAxisCount;
      final row = i ~/ crossAxisCount;
      final y = row * (cellH + spacing);
      final x = leftPadding + col * (cellW + spacing);
      final r = Rect.fromLTWH(x, y, cellW, cellH);
      entries.add(_GridRectEntry(id: id, rect: r));
      bottoms.add(r.bottom);
    }
    _gridRectCache = entries;
    _gridRectBottoms = bottoms;
  }

  @override
  Widget build(BuildContext context) {
    return GetBuilder<MusicListController>(
      tag: _controllerTag,
      init: MusicListController(
        seriesIndexId: widget.seriesIndexId,
        listType: widget.listType,
        listId: widget.listId,
        isFavorite: widget.isFavorite,
        initialSortOrder: widget.initialSortOrder,
        initialSortBy: widget.initialSortBy,
        collectionId: widget.collectionId,
      ),
      builder: (listState) {
        _controller = listState;
        final theme = Theme.of(context);
        final extendedPalette = theme.extension<CustomColors>();
        final barColor =
            extendedPalette?.oprationBarBgColor ?? theme.colorScheme.surface;
        final overlayCtrl = Get.isRegistered<MusicSubListOverlayController>()
            ? Get.find<MusicSubListOverlayController>()
            : Get.put(MusicSubListOverlayController());

        final list = Column(
          children: <Widget>[
            DeviceUtils.isPhone(context)
                ? ColoredBox(
                    color: barColor,
                    child: AppMusicListTopBar(controller: listState),
                  )
                : MusicListTopBar(controller: listState),
            Expanded(
              child: MusicAsyncListState(
                loading: listState.loading,
                isEmpty: () => listState.items.isEmpty,
                emptyBuilder: (_) => Stack(
                  children: <Widget>[Center(child: const MusicEmptyState())],
                ),
                child: Obx(() {
                  final showMultiBar = listState.isMultiSelectMode.value;
                  if (_lastShowMultiBar != showMultiBar) {
                    _lastShowMultiBar = showMultiBar;
                    final desired = showMultiBar;
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (!mounted) return;
                      if (!Get.isRegistered<MusicMainController>()) return;
                      final mainCtrl = Get.find<MusicMainController>();
                      if (mainCtrl.hidePlayerBar.value != desired) {
                        mainCtrl.hidePlayerBar.value = desired;
                      }
                    });
                  }

                  final playCtrl =
                      Get.isRegistered<MusicPlayServiceController>()
                      ? Get.find<MusicPlayServiceController>()
                      : null;
                  final showPlayerBar =
                      !showMultiBar &&
                      playCtrl != null &&
                      playCtrl.isReady.value &&
                      playCtrl.playlist.isNotEmpty;
                  final playerExtraSpace = showPlayerBar
                      ? (112.0 + MediaQuery.of(context).padding.bottom)
                      : 0.0;

                  final bottomSpace =
                      (showMultiBar ? 86.0 : 30.0) + playerExtraSpace;

                  return Stack(
                    children: <Widget>[
                      Scrollbar(
                        thumbVisibility: true,
                        controller: _scrollController,
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final enableMarquee =
                                DeviceUtils.isDesktop ||
                                (DeviceUtils.isWeb &&
                                    DeviceUtils.isDesktopLayout(context));
                            _gridViewportHeight = constraints.maxHeight;

                            final rectKey = [
                              listState.items.length,
                              constraints.maxWidth.toStringAsFixed(2),
                            ].join('|');
                            if (_rectCacheKey != rectKey) {
                              _rectCacheKey = rectKey;
                              _rebuildGridRectCache(
                                items: listState.items,
                                maxWidth: constraints.maxWidth,
                              );
                            }

                            final scrollView = CustomScrollView(
                              controller: _scrollController,
                              slivers: <Widget>[
                                SliverPadding(
                                  padding: const EdgeInsets.fromLTRB(
                                    16,
                                    0,
                                    16,
                                    16,
                                  ),
                                  sliver: MusicListGrid(controller: listState),
                                ),
                                SliverToBoxAdapter(
                                  child: Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      0,
                                      0,
                                      0,
                                      20,
                                    ),
                                    child: MusicListFooter(
                                      controller: listState,
                                    ),
                                  ),
                                ),
                                SliverToBoxAdapter(
                                  child: SizedBox(height: bottomSpace),
                                ),
                              ],
                            );

                            final scrollLayer = enableMarquee
                                ? Listener(
                                    onPointerUp: (e) {
                                      if (_marqueeActive) {
                                        final hits = _performHitTest();
                                        _dragging = false;
                                        listState.finishDragSelection();
                                        listState.applyDragSelection(
                                          hits,
                                          multiModeAtStart: _multiModeAtStart,
                                          additive: _additiveAtStart,
                                        );
                                      } else {
                                        listState.finishDragSelection();
                                      }
                                      _pointerDownGridPos = null;
                                      _marqueeActive = false;
                                    },
                                    onPointerMove: (e) {
                                      if (e.buttons != kPrimaryButton) return;
                                      final origin = _pointerDownGridPos;
                                      if (origin == null) return;
                                      final local = e.localPosition;
                                      if (!_marqueeActive) {
                                        if ((local - origin).distance >
                                            _kMarqueeThreshold) {
                                          _marqueeActive = true;
                                          _dragging = true;
                                          _lastGridLocal = local;
                                          _ensureAutoTimer();
                                          _additiveAtStart =
                                              _isAdditiveSelectionActive;
                                          listState.startDragSelection(
                                            origin,
                                            scrollOffset:
                                                _scrollController.offset,
                                          );
                                        }
                                      }
                                      if (_marqueeActive) {
                                        _lastGridLocal = local;
                                        listState.updateDragSelection(
                                          local,
                                          scrollOffset:
                                              _scrollController.offset,
                                        );
                                        _scheduleHitTest();
                                      }
                                    },
                                    onPointerDown: (e) {
                                      if (e.buttons != kPrimaryButton) return;
                                      _pointerDownGridPos = e.localPosition;
                                      _multiModeAtStart =
                                          listState.isMultiSelectMode.value;
                                      _additiveAtStart =
                                          _isAdditiveSelectionActive;
                                      _marqueeActive = false;
                                    },
                                    onPointerCancel: (e) {
                                      _dragging = false;
                                      listState.finishDragSelection();
                                      _pointerDownGridPos = null;
                                      _marqueeActive = false;
                                    },
                                    behavior: HitTestBehavior.opaque,
                                    child: scrollView,
                                  )
                                : scrollView;

                            return Stack(
                              children: <Widget>[
                                scrollLayer,
                                if (enableMarquee)
                                  Obx(() {
                                    final r = listState.selectionRect.value;
                                    if (r == null)
                                      return const SizedBox.shrink();
                                    return Positioned(
                                      width: r.width,
                                      top: r.top,
                                      left: r.left,
                                      height: r.height,
                                      child: IgnorePointer(
                                        child: Container(
                                          decoration: BoxDecoration(
                                            color: Colors.blue.withValues(
                                              alpha: 0.15,
                                            ),
                                            border: Border.all(
                                              color: Colors.blue,
                                              width: 1.0,
                                            ),
                                          ),
                                        ),
                                      ),
                                    );
                                  }),
                              ],
                            );
                          },
                        ),
                      ),
                      if (showMultiBar)
                        Positioned(
                          right: 0.0,
                          left: 0.0,
                          child: MusicListMultiSelectBottomBar(
                            controller: listState,
                          ),
                          bottom: playerExtraSpace,
                        ),
                    ],
                  );
                }),
              ),
            ),
          ],
        );

        return MusicOverlayHost<MusicSubListPayload>(
          child: list,
          active: overlayCtrl.active,
          overlayBuilder: (payload) => MusicSubListOverlay(
            seriesIndexId: payload.seriesIndexId,
            onClose: overlayCtrl.close,
            name: payload.name,
            keyType: payload.keyType,
            key: ValueKey(
              'music_sub_list_${payload.keyType}_${payload.seriesIndexId ?? 0}_${payload.name}',
            ),
          ),
        );
      },
    );
  }
}

class _GridRectEntry {
  final int id;
  final Rect rect;

  const _GridRectEntry({required this.id, required this.rect});
}
