import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../compat/getx.dart';
import '../../compat/host.dart';
import '../../compat/list_batch_ops.dart';
import '../../list/models/cola_list_models.dart';
import '../../play_service/controller/cola_player_controller.dart';
import '../../sub_list/controller/cola_sub_list_controller.dart';
import '../models/music_detail_models.dart';
import '../service/music_detail_api_service.dart';

/// 专辑 / 歌手详情页共享的操作（播放、收藏整张、随机、分享）。
///
/// 曲目列表本身的分页 / 多选 / 右键全在 `MusicSubListController` 里，
/// 这里只补「整张 / 整位歌手」这个维度的动作。
mixin MusicDetailActions {
  MusicSubListController? get tracks;

  List<MusicListItem> get _items => tracks?.items.toList() ?? const [];

  bool get allFavorited =>
      _items.isNotEmpty && _items.every((e) => e.isFavorite);

  void playAll() => tracks?.playAll();

  /// 随机播放：把当前（已筛选 / 已排序）列表打乱后整队播放。
  /// 不去碰播放器的全局循环模式 —— 用户切到别的页面时不该带着「随机」状态。
  void playShuffled() {
    final list = _items.toList()..shuffle();
    if (list.isEmpty) return;
    MusicPlayServiceController.instance.playFromList(
      items: list,
      startItem: list.first,
    );
  }

  /// 「收藏专辑」= 批量收藏本专辑全部曲目（曲库没有专辑级收藏表，
  /// 但曲目级收藏是共用的，这样收藏后到「我的收藏」里能直接看到）。
  Future<void> toggleFavoriteAll() async {
    final ctrl = tracks;
    if (ctrl == null || _items.isEmpty) return;
    final makeFavorite = !allFavorited;
    await applyBatchFavorite(
      ids: _items.map((e) => e.id).where((id) => id > 0).toList(),
      makeFavorite: makeFavorite,
      onState: ctrl.updateFavoriteState,
    );
  }

  Future<void> downloadAll() async => tracks?.downloadAll();

  /// 分享：NAS 场景没有外部分享后端，这里把「专辑名 / 歌手 / 曲目数」复制到剪贴板，
  /// 用户自己粘到微信里 —— 比放一个点了没反应的按钮强。
  Future<void> copySummary() async {
    final line = summaryText.trim();
    if (line.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: line));
    ToastUtil.show('music_detail_copied'.tr);
  }

  String get summaryText;

  bool get isEmpty => _items.isEmpty;
}

/// 专辑 / 歌手详情页的状态。
///
/// 两个页面共享同一套「头部信息 + 曲目列表」结构：
/// - 头部元信息由 [MusicDetailApiService] 的聚合口一次拿全；
/// - 曲目列表交给 `MusicSubListController`（分页 / 多选 / 右键 / 播放续页全在那儿），
///   这里只负责按页面语义决定它的排序与去重参数。
class AlbumDetailController extends GetxController with MusicDetailActions {
  AlbumDetailController({required this.name, this.artist = ''});

  final String name;
  final String artist;

  final Rx<AlbumDetailInfo?> info = Rx<AlbumDetailInfo?>(null);
  final RxBool loading = true.obs;
  final RxBool failed = false.obs;
  final RxBool introExpanded = false.obs;

  /// 曲目列表（专辑内按音轨号，不跟随全局「文件名排序」缓存）
  @override
  MusicSubListController? tracks;

  final MusicDetailApiService _api = MusicDetailApiService.instance;

  @override
  String get summaryText {
    final i = info.value;
    if (i == null) return '';
    final bits = <String>[i.name, if (i.artist.isNotEmpty) i.artist];
    return '${bits.join(' - ')}（${i.trackCount} 首）';
  }

  @override
  void onInit() {
    super.onInit();
    // 快速来回切换（专辑 → 歌手 → 专辑）时旧实例可能还没被 dispose 掉，
    // 直接 put 会撞「already registered」；有就复用。
    tracks = Get.isRegistered<MusicSubListController>(tag: tracksTag)
        ? Get.find<MusicSubListController>(tag: tracksTag)
        : Get.put(
            MusicSubListController(
              keyType: 'album',
              name: name,
              initialSortBy: MusicSubListSortBy.albumOrder,
              initialSortOrder: MusicSubListSortOrder.asc,
              ignoreStoredSort: true,
            ),
            tag: tracksTag,
          );
    unawaited(load());
  }

  String get tracksTag => 'album_tracks::$name::$artist';

  /// 同一张专辑在列表里反复点开不该每次都等接口：内存里留一份，先秒开再静默刷新。
  static final Map<String, AlbumDetailInfo> _albumCache = {};

  String get _cacheKey => '$name::$artist';

  Future<void> load() async {
    final cached = _albumCache[_cacheKey];
    if (cached != null) {
      info.value = cached;
      failed.value = !cached.found;
      loading.value = false;
      unawaited(_silentRefresh());
      return;
    }
    loading.value = true;
    failed.value = false;
    try {
      final result = await _api.albumDetail(name: name, artist: artist);
      _albumCache[_cacheKey] = result;
      info.value = result;
      failed.value = !result.found;
      _scheduleCrowdRefresh(result.crowd.cached);
    } catch (e) {
      debugPrint('[music] album detail failed: $e');
      failed.value = true;
    } finally {
      loading.value = false;
    }
  }

  /// 热度的 Last.fm 请求已改为服务端后台补抓；这里延迟取一次缓存即可
  void _scheduleCrowdRefresh(bool cached) {
    if (cached) return;
    Future.delayed(const Duration(seconds: 2), () {
      if (!isClosed) unawaited(_silentRefresh());
    });
  }

  /// 静默刷新不转圈、失败不覆盖已有内容（热度数据可能刚由后台补抓到）
  Future<void> _silentRefresh() async {
    try {
      final result = await _api.albumDetail(name: name, artist: artist);
      if (!result.found) return;
      _albumCache[_cacheKey] = result;
      if (!isClosed) info.value = result;
    } catch (_) {
      // 保持旧数据
    }
  }

  void toggleIntro() => introExpanded.value = !introExpanded.value;
}

/// 歌手详情页状态。曲目默认按专辑顺序、**去重**（同名同歌手只留最新一版）。
class ArtistDetailController extends GetxController with MusicDetailActions {
  ArtistDetailController({required this.name});

  final String name;

  final Rx<ArtistDetailInfo?> info = Rx<ArtistDetailInfo?>(null);
  final RxBool loading = true.obs;
  final RxBool failed = false.obs;
  final RxBool introExpanded = false.obs;
  final RxString searchText = ''.obs;

  @override
  MusicSubListController? tracks;

  final MusicDetailApiService _api = MusicDetailApiService.instance;

  @override
  String get summaryText {
    final i = info.value;
    if (i == null) return '';
    return '${i.name}（${i.trackCount} 首 / ${i.albumCount} 张专辑）';
  }

  @override
  void onInit() {
    super.onInit();
    tracks = Get.isRegistered<MusicSubListController>(tag: tracksTag)
        ? Get.find<MusicSubListController>(tag: tracksTag)
        : Get.put(
            MusicSubListController(
              keyType: 'artist',
              name: name,
              initialSortBy: MusicSubListSortBy.albumOrder,
              initialSortOrder: MusicSubListSortOrder.asc,
              ignoreStoredSort: true,
              dedupe: true,
            ),
            tag: tracksTag,
          );
    unawaited(load());
  }

  String get tracksTag => 'artist_tracks::$name';

  /// 歌手页同理：内存缓存先秒开，热度等后台补抓完再静默更新。
  static final Map<String, ArtistDetailInfo> _artistCache = {};

  Future<void> load() async {
    final cached = _artistCache[name];
    if (cached != null) {
      info.value = cached;
      failed.value = !cached.found;
      loading.value = false;
      unawaited(_silentRefresh());
      return;
    }
    loading.value = true;
    failed.value = false;
    try {
      final result = await _api.artistDetail(name: name);
      _artistCache[name] = result;
      info.value = result;
      failed.value = !result.found;
      _scheduleCrowdRefresh(result.crowd.cached);
    } catch (e) {
      debugPrint('[music] artist detail failed: $e');
      failed.value = true;
    } finally {
      loading.value = false;
    }
  }

  /// 歌手热度同样由服务端后台补抓，延迟静默取一次缓存
  void _scheduleCrowdRefresh(bool cached) {
    if (cached) return;
    Future.delayed(const Duration(seconds: 2), () {
      if (!isClosed) unawaited(_silentRefresh());
    });
  }

  Future<void> _silentRefresh() async {
    try {
      final result = await _api.artistDetail(name: name);
      if (!result.found) return;
      _artistCache[name] = result;
      if (!isClosed) info.value = result;
    } catch (_) {
      // 保持旧数据
    }
  }

  void toggleIntro() => introExpanded.value = !introExpanded.value;

  /// 本歌手内搜索：交给曲目 controller（服务端按 artists + search 过滤）
  void onSearchChanged(String value) {
    searchText.value = value;
    tracks?.onSearchChanged(value);
  }

  void clearSearch() {
    searchText.value = '';
    tracks?.clearSearch();
  }

  void setSortBy(MusicSubListSortBy by) {
    // 热度是「越热越靠前」，天然降序；其余（专辑顺序 / 歌名）按升序读起来更顺。
    tracks?.setSort(
      by,
      by == MusicSubListSortBy.hot
          ? MusicSubListSortOrder.desc
          : MusicSubListSortOrder.asc,
    );
  }
}
