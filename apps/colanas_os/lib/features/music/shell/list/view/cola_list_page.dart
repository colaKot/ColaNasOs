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
    this.isFavorite = false,
    this.collectionId,
    this.seriesIndexId,
    this.listType = '',
    this.listId,
    this.initialSortOrder = MusicListSortOrder.desc,
    this.initialSortBy = MusicListSortBy.mtime,
  });

  @override
  State<MusicListPage> createState() => _MusicListPageState();
}

class _MusicListPageState extends State<MusicListPage> {
  static const double _kMarqueeThreshold = 8;

  final ScrollController _scroll = ScrollController();
  MusicListController? _list;
  Timer? _autoScrollTimer;
  Timer? _hitTestTimer;
  bool? _lastMultiBar;
  late final String _ctrlTag;

  bool _marqueeOn = false;
  bool _dragging = false;
  bool _multiAtPress = false;
  bool _shiftAtPress = false;
  Offset _dragLocal = const Offset(0, 0);
  Offset? _pressLocal;
  double _viewportH = 0;

  String _cellCacheKey = '';
  List<_CellBox> _cellBoxes = const <_CellBox>[];

  @override
  void initState() {
    super.initState();
    _ctrlTag = _buildCtrlTag();
    _scroll.addListener(_handleScroll);
  }

  @override
  void dispose() {
    _autoScrollTimer?.cancel();
    _hitTestTimer?.cancel();
    _releaseSharedState();
    _scroll.removeListener(_handleScroll);
    _scroll.dispose();
    super.dispose();
  }

  String _buildCtrlTag() {
    final w = widget;
    return [
      'music_list',
      w.listType,
      w.listId ?? 0,
      w.seriesIndexId ?? 0,
      w.collectionId ?? 0,
      w.isFavorite,
      w.initialSortBy,
      w.initialSortOrder,
      UniqueKey(),
    ].join('_');
  }

  void _releaseSharedState() {
    // dispose 发生在 build / unmount 期间（framework 处于锁内），此处直接改 Rx
    // 会让仍在树上的 Obx 报「markNeedsBuild called when widget tree was locked」。
    // 共享状态（播放条 / 框选浮层）收回统一挪到本帧结束之后。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (Get.isRegistered<MusicMainController>()) {
        Get.find<MusicMainController>().hidePlayerBar.value = false;
      }
      if (Get.isRegistered<MusicSubListOverlayController>()) {
        Get.find<MusicSubListOverlayController>().close();
      }
    });
  }

  MusicListController? _locateList() =>
      _list ??
      (Get.isRegistered<MusicListController>(tag: _ctrlTag)
          ? Get.find<MusicListController>(tag: _ctrlTag)
          : null);

  void _handleScroll() {
    final list = _locateList();
    if (list == null) return;
    // 列表按页加载，滚动到底不自动续页；这里只复用公共滚动手势：
    // 框选跟随、停止滚动标记与阈值判定都在 onScrolling 内完成。
    attachPagedScroll(
      _scroll,
      loadMore: () {},
      onScrolling: () {
        if (_dragging) {
          list.updateDragSelection(_dragLocal, scrollOffset: _scroll.offset);
          _queueHitTest();
        }
        list.markScrolling();
      },
      threshold: 360,
    );
  }

  bool get _shiftPressed {
    final pressed = HardwareKeyboard.instance.logicalKeysPressed;
    return pressed.contains(LogicalKeyboardKey.shiftLeft) ||
        pressed.contains(LogicalKeyboardKey.shiftRight);
  }

  void _queueHitTest() {
    if (_hitTestTimer?.isActive ?? false) return;
    _hitTestTimer = Timer(const Duration(milliseconds: 60), _collectHits);
  }

  Set<int> _collectHits() {
    final list = _list;
    if (!_dragging || list == null) return const <int>{};
    final area = list.selectionRectContent.value;
    if (area == null) return const <int>{};
    final hitIds = <int>{};
    for (final cell in _cellBoxes) {
      if (cell.rect.bottom <= area.top) continue;
      if (cell.rect.top > area.bottom) break;
      if (cell.rect.overlaps(area)) hitIds.add(cell.id);
    }
    list.updateDragPreview(hitIds, additive: _shiftAtPress);
    return hitIds;
  }

  void _startEdgeAutoScroll() {
    _autoScrollTimer ??= Timer.periodic(
      const Duration(milliseconds: 30),
      (_) => _edgeScrollTick(),
    );
  }

  void _edgeScrollTick() {
    if (!_dragging || !_scroll.hasClients) return;
    final position = _scroll.position;
    if (!position.hasPixels) return;
    final step = _edgeStepFor(_dragLocal.dy);
    if (step == 0) return;
    _scroll.jumpTo(
      (position.pixels + step).clamp(0.0, position.maxScrollExtent),
    );
  }

  double _edgeStepFor(double y) {
    const zone = 30.0;
    const speed = 12.0;
    if (y < zone) {
      return -speed * ((zone - y).clamp(0.0, zone) / zone);
    }
    final toBottom = _viewportH - y;
    if (toBottom < zone) {
      return speed * ((zone - toBottom).clamp(0.0, zone) / zone);
    }
    return 0.0;
  }

  void _syncCellCache(MusicListController list, double maxWidth) {
    final key = '${list.items.length}@${maxWidth.toStringAsFixed(2)}';
    if (key == _cellCacheKey) return;
    _cellCacheKey = key;

    const gutter = 16.0;
    const tileWidth = 115.0;
    const gap = 4.0;
    final usable = math.max(0.0, maxWidth - gutter * 2);
    final columns = (usable / tileWidth).floor().clamp(2, 10);
    final cellW = ((usable - gap * (columns - 1)) / columns).floorToDouble();
    final cellH = cellW + 56.0;

    final boxes = <_CellBox>[];
    for (var i = 0; i < list.items.length; i++) {
      final id = (list.items[i].id as int?) ?? 0;
      if (id <= 0) continue;
      final row = i ~/ columns;
      final col = i % columns;
      boxes.add(
        _CellBox(
          id: id,
          rect: Rect.fromLTWH(
            gutter + col * (cellW + gap),
            row * (cellH + gap),
            cellW,
            cellH,
          ),
        ),
      );
    }
    _cellBoxes = boxes;
  }

  void _onMarqueeDown(PointerDownEvent event, MusicListController list) {
    if (event.buttons != kPrimaryButton) return;
    _pressLocal = event.localPosition;
    _multiAtPress = list.isMultiSelectMode.value;
    _shiftAtPress = _shiftPressed;
    _marqueeOn = false;
  }

  void _onMarqueeMove(PointerMoveEvent event, MusicListController list) {
    if (event.buttons != kPrimaryButton) return;
    final origin = _pressLocal;
    if (origin == null) return;
    final local = event.localPosition;
    if (!_marqueeOn && (local - origin).distance > _kMarqueeThreshold) {
      _marqueeOn = true;
      _dragging = true;
      _dragLocal = local;
      _startEdgeAutoScroll();
      _shiftAtPress = _shiftPressed;
      list.startDragSelection(origin, scrollOffset: _scroll.offset);
    }
    if (!_marqueeOn) return;
    _dragLocal = local;
    list.updateDragSelection(local, scrollOffset: _scroll.offset);
    _queueHitTest();
  }

  void _onMarqueeUp(PointerUpEvent event, MusicListController list) {
    if (_marqueeOn) {
      final hitIds = _collectHits();
      _dragging = false;
      list.finishDragSelection();
      list.applyDragSelection(
        hitIds,
        multiModeAtStart: _multiAtPress,
        additive: _shiftAtPress,
      );
    } else {
      list.finishDragSelection();
    }
    _pressLocal = null;
    _marqueeOn = false;
  }

  void _onMarqueeCancel(PointerCancelEvent event, MusicListController list) {
    _dragging = false;
    list.finishDragSelection();
    _pressLocal = null;
    _marqueeOn = false;
  }

  MusicListController _createController() => MusicListController(
    seriesIndexId: widget.seriesIndexId,
    listType: widget.listType,
    listId: widget.listId,
    isFavorite: widget.isFavorite,
    initialSortOrder: widget.initialSortOrder,
    initialSortBy: widget.initialSortBy,
    collectionId: widget.collectionId,
  );

  MusicSubListOverlayController _overlayController() =>
      Get.isRegistered<MusicSubListOverlayController>()
      ? Get.find<MusicSubListOverlayController>()
      : Get.put(MusicSubListOverlayController());

  void _syncPlayerBar(bool multiVisible) {
    if (_lastMultiBar == multiVisible) return;
    _lastMultiBar = multiVisible;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !Get.isRegistered<MusicMainController>()) return;
      final main = Get.find<MusicMainController>();
      if (main.hidePlayerBar.value != multiVisible) {
        main.hidePlayerBar.value = multiVisible;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return GetBuilder<MusicListController>(
      tag: _ctrlTag,
      init: _createController(),
      builder: (list) {
        _list = list;
        final theme = Theme.of(context);
        final palette = theme.extension<CustomColors>();
        final barColor =
            palette?.oprationBarBgColor ?? theme.colorScheme.surfaceContainerLow;
        final overlay = _overlayController();

        final page = Column(
          children: <Widget>[
            DeviceUtils.isPhone(context)
                ? ColoredBox(
                    color: barColor,
                    child: AppMusicListTopBar(controller: list),
                  )
                : MusicListTopBar(controller: list),
            Expanded(child: _buildBody(context, list)),
          ],
        );

        return MusicOverlayHost<MusicSubListPayload>(
          active: overlay.active,
          child: page,
          overlayBuilder: (payload) => MusicSubListOverlay(
            seriesIndexId: payload.seriesIndexId,
            onClose: overlay.close,
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

  Widget _buildBody(BuildContext context, MusicListController list) {
    return MusicAsyncListState(
      loading: list.loading,
      isEmpty: () => list.items.isEmpty,
      emptyBuilder: (_) =>
          Stack(children: <Widget>[Center(child: const MusicEmptyState())]),
      child: Obx(() {
        final multi = list.isMultiSelectMode.value;
        _syncPlayerBar(multi);

        final playCtrl = Get.isRegistered<MusicPlayServiceController>()
            ? Get.find<MusicPlayServiceController>()
            : null;
        final playerBar =
            !multi &&
            playCtrl != null &&
            playCtrl.isReady.value &&
            playCtrl.playlist.isNotEmpty;
        final playerSpace = playerBar
            ? (112.0 + MediaQuery.of(context).padding.bottom)
            : 0.0;
        final tailSpace = (multi ? 86.0 : 30.0) + playerSpace;

        return Stack(
          children: <Widget>[
            Scrollbar(
              thumbVisibility: true,
              controller: _scroll,
              child: LayoutBuilder(
                builder: (context, constraints) =>
                    _buildScrollingLayer(context, list, constraints, tailSpace),
              ),
            ),
            if (multi)
              Positioned(
                right: 0.0,
                left: 0.0,
                bottom: playerSpace,
                child: MusicListMultiSelectBottomBar(controller: list),
              ),
          ],
        );
      }),
    );
  }

  Widget _buildScrollingLayer(
    BuildContext context,
    MusicListController list,
    BoxConstraints constraints,
    double tailSpace,
  ) {
    final marqueeEnabled =
        DeviceUtils.isDesktop ||
        (DeviceUtils.isWeb && DeviceUtils.isDesktopLayout(context));
    _viewportH = constraints.maxHeight;
    _syncCellCache(list, constraints.maxWidth);

    final scrollView = CustomScrollView(
      controller: _scroll,
      slivers: <Widget>[
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          sliver: MusicListGrid(controller: list),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(0, 0, 0, 20),
            child: MusicListFooter(controller: list),
          ),
        ),
        SliverToBoxAdapter(child: SizedBox(height: tailSpace)),
      ],
    );

    if (!marqueeEnabled) return scrollView;

    return Stack(
      children: <Widget>[
        Listener(
          onPointerDown: (event) => _onMarqueeDown(event, list),
          onPointerMove: (event) => _onMarqueeMove(event, list),
          onPointerUp: (event) => _onMarqueeUp(event, list),
          onPointerCancel: (event) => _onMarqueeCancel(event, list),
          behavior: HitTestBehavior.opaque,
          child: scrollView,
        ),
        _buildSelectionBand(list),
      ],
    );
  }

  Widget _buildSelectionBand(MusicListController list) {
    return Obx(() {
      final band = list.selectionRect.value;
      if (band == null) return const SizedBox.shrink();
      return Positioned(
        width: band.width,
        top: band.top,
        left: band.left,
        height: band.height,
        child: IgnorePointer(
          child: Container(
            decoration: BoxDecoration(
              color: Colors.blue.withValues(alpha: 0.15),
              border: Border.all(color: Colors.blue, width: 1.0),
            ),
          ),
        ),
      );
    });
  }
}

class _CellBox {
  final int id;
  final Rect rect;

  const _CellBox({required this.id, required this.rect});
}
