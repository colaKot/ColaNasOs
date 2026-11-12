import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../compat/getx.dart';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';

import '../../compat/cola_api_controller.dart';
import '../../compat/host.dart';
import '../../list/models/cola_list_models.dart';
import '../../list/service/cola_list_api_service.dart';
import '../cache/cola_audio_cache.dart';
import '../lyric_match.dart';
// 新播放内核（playback/）：引擎 + 状态机 + 不可变队列，与旧实现并存
import '../../../playback/playback_controller.dart';
import '../../../playback/playback_engine.dart';
import '../../../playback/playback_state.dart';
import '../../../playback/track.dart';

part 'parts/audio_handler.dart';
part 'parts/lifecycle.dart';
part 'parts/lyrics.dart';
part 'parts/new_core.dart';
part 'parts/playback.dart';

/// 播放器的固定配置：碟片图、缓存默认值与 iOS 会话通道名。
abstract final class _PlaybackDefaults {
  static const List<String> discs = <String>[
    'assets/music/icons/player_disc1.png',
    'assets/music/icons/player_disc2.png',
    'assets/music/icons/player_disc3.png',
  ];

  static const bool cacheEnabled = true;
  static const int cacheMaxItems = 300;
  static const String iosSessionChannel = 'colanas.music.audio_session';
}

typedef MusicProgressListener = void Function(
  Duration position,
  Duration duration,
  Duration buffered,
);

enum MusicLoopMode { sequence, listLoop, singleLoop, shuffle }

/// 播放队列的翻页句柄：列表页只提供「还有没有」和「取下一页」两个动作。
class MusicPlaylistPaging {
  final bool Function() hasMore;
  final Future<List<MusicListItem>> Function() loadMore;

  const MusicPlaylistPaging({required this.hasMore, required this.loadMore});

  factory MusicPlaylistPaging.fromQuery(MusicListPagingQuery query) {
    var cursorPage = query.page;
    var cursorSize = query.pageSize;
    var hasNext = query.hasMore;

    Future<List<MusicListItem>> fetchNext() async {
      if (!hasNext) return const <MusicListItem>[];
      final result = await MusicListApiService.instance.listPaged(
        sourceList: query.sourceList,
        sortOrder: query.sortOrder,
        sortBy: query.sortBy,
        showLoading: false,
        seriesIndexId: query.seriesIndexId,
        search: query.search,
        pageSize: cursorSize,
        page: cursorPage + 1,
        listType: query.listType,
        listId: query.listId,
        isHistory: query.isHistory,
        isFavorite: query.isFavorite,
        genres: query.genres,
        collectionId: query.collectionId,
        artists: query.artists,
        albums: query.albums,
      );
      cursorPage = result.pagination.page;
      cursorSize = result.pagination.limit;
      hasNext = result.pagination.hasNextPage;
      return result.items.isEmpty ? const <MusicListItem>[] : result.items;
    }

    return MusicPlaylistPaging(hasMore: () => hasNext, loadMore: fetchNext);
  }
}

class MusicPlayServiceController extends GetxController
    with WidgetsBindingObserver {
  static MusicPlayServiceController get instance {
    if (Get.isRegistered<MusicPlayServiceController>()) {
      return Get.find<MusicPlayServiceController>();
    }
    return Get.put(MusicPlayServiceController(), permanent: true);
  }

  static const List<String> discAssets = _PlaybackDefaults.discs;

  final RxInt currentIndex = 0.obs;
  final RxList<MusicListItem> playlist = <MusicListItem>[].obs;

  final Rx<Duration> position = Duration.zero.obs;
  final Rx<Duration> buffered = Duration.zero.obs;
  final Rx<Duration> duration = Duration.zero.obs;
  final RxBool isPlaying = false.obs;

  final Rx<MusicLoopMode> loopMode = MusicLoopMode.sequence.obs;
  final RxDouble volume = 1.0.obs;
  final RxBool isReady = false.obs;
  final RxInt discStyleIndex = 0.obs;

  final RxString currentLyrics = ''.obs;

  final RxInt audioCacheMaxItems = _PlaybackDefaults.cacheMaxItems.obs;
  final RxBool audioCacheEnabled = _PlaybackDefaults.cacheEnabled.obs;
  final RxDouble downloadProgress = 0.0.obs;
  final RxBool isDownloading = false.obs;
  final RxInt downloadTotalBytes = 0.obs;
  final RxInt downloadReceivedBytes = 0.obs;
  final RxString downloadingFileHash = ''.obs;

  double _volumeBeforeMute = 1.0;
  bool _resumeAfterInterruption = false;
  bool _pendingNotificationPermissionGuide = false;

  _MusicAudioHandler? _handler;
  Future<void>? _serviceInitFuture;

  /// 新内核适配层；`kNewPlaybackCore` 关闭时为 null，自动退回旧实现。
  _MusicNewCoreAdapter? _coreAdapter;
  _MusicNewCoreAdapter get _newCore =>
      _coreAdapter ??= _MusicNewCoreAdapter(this);

  final List<MusicProgressListener> _progressListeners = [];

  /// 已推送条目的指纹，用来过滤重复的 mediaItem 通知。
  String? _lastSentMediaItemKey;

  final List<StreamSubscription<dynamic>> _audioSessionSubs = [];
  final Map<String, String> _lyricsCache = {};
  final Map<String, MusicListItem> _detailCache = {};
  final Set<String> _autoLyricTried = <String>{};
  int _detailFetchToken = 0;

  MusicPlaylistPaging? _paging;
  int _pagingToken = 0;

  final MusicAudioCacheService _audioCache = MusicAudioCacheService(
    options: const MusicAudioCacheOptions(
      enabled: _PlaybackDefaults.cacheEnabled,
      maxItems: _PlaybackDefaults.cacheMaxItems,
    ),
  );

  static const MethodChannel _iosAudioSessionChannel = MethodChannel(
    _PlaybackDefaults.iosSessionChannel,
  );

  @override
  void onInit() {
    super.onInit();
    // 启动顺序固定为：监听生命周期 → 恢复碟片样式 → 恢复循环模式 → 初始化缓存。
    WidgetsBinding.instance.addObserver(this);
    _loadDiscStyleIndex();
    _loadLoopMode();
    unawaited(_initAudioCache());
  }

  @override
  void onClose() {
    WidgetsBinding.instance.removeObserver(this);
    _dropAudioSessionSubscriptions();
    unawaited(_audioCache.cancelActiveDownload());
    unawaited(_newCore.core.stop());
    super.onClose();
  }

  void _dropAudioSessionSubscriptions() {
    for (final sub in _audioSessionSubs) {
      sub.cancel();
    }
    _audioSessionSubs.clear();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (kIsWeb) return;

    if (defaultTargetPlatform == TargetPlatform.android) {
      final backToForeground = state == AppLifecycleState.resumed;
      if (backToForeground && _pendingNotificationPermissionGuide) {
        _pendingNotificationPermissionGuide = false;
        unawaited(_ensureNotificationPermission());
      }
      return;
    }

    if (defaultTargetPlatform != TargetPlatform.iOS) return;
    if (!isPlaying.value) return;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.resumed) {
      unawaited(_activateIosAudioSessionForPlayback());
    }
  }

  Future<void> setAudioCacheEnabled(bool enabled) async {
    audioCacheEnabled.value = enabled;
    await CacheManager().setBool(CacheKeys.musicAudioCacheEnabled, enabled);
    _syncAudioCacheOptions();
  }

  Future<void> setAudioCacheMaxItems(int maxItems) async {
    final safeValue = maxItems < 0 ? 0 : maxItems;
    audioCacheMaxItems.value = safeValue;
    await CacheManager().setInt(CacheKeys.musicAudioCacheMaxItems, safeValue);
    _syncAudioCacheOptions();
  }

  Future<void> clearAudioCache() => _audioCache.clearAll();

  Future<MusicAudioCacheStats> getAudioCacheStats() => _audioCache.getStats();

  Future<void> cancelDownload() async {
    await _audioCache.cancelActiveDownload();
    _setDownloadUi(downloading: false, fileHash: '', received: 0, total: 0);
  }

  /// 两个缓存配置 setter 共用：把 Rx 值整体写回缓存服务。
  void _syncAudioCacheOptions() {
    _audioCache.updateOptions(
      MusicAudioCacheOptions(
        enabled: audioCacheEnabled.value,
        maxItems: audioCacheMaxItems.value,
      ),
    );
  }

  Future<void> _initAudioCache() async {
    final storedEnabled =
        CacheManager().getBool(CacheKeys.musicAudioCacheEnabled);
    final storedMaxItems =
        CacheManager().getInt(CacheKeys.musicAudioCacheMaxItems);

    audioCacheEnabled.value = storedEnabled ?? _PlaybackDefaults.cacheEnabled;
    audioCacheMaxItems.value =
        storedMaxItems ?? _PlaybackDefaults.cacheMaxItems;
    _syncAudioCacheOptions();
    await _audioCache.init();
  }

  Future<void> _invokeIosSession(String method) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return;
    try {
      await _iosAudioSessionChannel.invokeMethod(method);
    } catch (_) {
      // 通道在非 iOS 宿主或调试环境下可能不存在，忽略即可。
    }
  }

  Future<void> _activateIosAudioSessionForPlayback() =>
      _invokeIosSession('activatePlayback');

  Future<void> _deactivateIosAudioSessionForPlayback() =>
      _invokeIosSession('deactivatePlayback');

  void _setDownloadUi({
    required bool downloading,
    required String fileHash,
    required int received,
    required int total,
  }) {
    isDownloading.value = downloading;
    downloadingFileHash.value = fileHash;
    downloadReceivedBytes.value = received;
    downloadTotalBytes.value = total;
    downloadProgress.value =
        total > 0 ? (received / total).clamp(0.0, 1.0) : 0.0;
  }
}
