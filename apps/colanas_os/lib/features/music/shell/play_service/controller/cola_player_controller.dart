import 'dart:async';
import 'dart:math';

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

// ---- 文件级常量：碟片资源、音频缓存默认值、iOS 音频会话通道 ----
const List<String> _kDiscAssets = <String>[
  'assets/music/icons/player_disc1.png',
  'assets/music/icons/player_disc2.png',
  'assets/music/icons/player_disc3.png',
];
const bool _kAudioCacheDefaultEnabled = true;
const int _kAudioCacheDefaultMaxItems = 300;
const String _kIosAudioSessionChannelName = 'colanas.music.audio_session';

typedef MusicProgressListener = void Function(
  Duration position,
  Duration duration,
  Duration buffered,
);

enum MusicLoopMode { sequence, listLoop, singleLoop, shuffle }

class MusicPlaylistPaging {
  final bool Function() hasMore;
  final Future<List<MusicListItem>> Function() loadMore;

  const MusicPlaylistPaging({required this.hasMore, required this.loadMore});

  factory MusicPlaylistPaging.fromQuery(MusicListPagingQuery query) {
    var localPageSize = query.pageSize;
    var localPage = query.page;
    var localMore = query.hasMore;
    return MusicPlaylistPaging(
      hasMore: () => localMore,
      loadMore: () async {
        if (!localMore) return const <MusicListItem>[];
        final localRes = await MusicListApiService.instance.listPaged(
          sourceList: query.sourceList,
          sortOrder: query.sortOrder,
          sortBy: query.sortBy,
          showLoading: false,
          seriesIndexId: query.seriesIndexId,
          search: query.search,
          pageSize: localPageSize,
          page: localPage + 1,
          listType: query.listType,
          listId: query.listId,
          isHistory: query.isHistory,
          isFavorite: query.isFavorite,
          genres: query.genres,
          collectionId: query.collectionId,
          artists: query.artists,
          albums: query.albums,
        );
        localPage = localRes.pagination.page;
        localPageSize = localRes.pagination.limit;
        localMore = localRes.pagination.hasNextPage;
        if (localRes.items.isEmpty) return const <MusicListItem>[];
        return localRes.items;
      },
    );
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

  static const List<String> discAssets = _kDiscAssets;

  // ---- 队列与当前索引 ----
  final RxInt currentIndex = 0.obs;
  final RxList<MusicListItem> playlist = <MusicListItem>[].obs;

  // ---- 播放进度、缓冲与播放态 ----
  final Rx<Duration> position = Duration.zero.obs;
  final RxBool isPlaying = false.obs;
  final Rx<Duration> buffered = Duration.zero.obs;
  final Rx<Duration> duration = Duration.zero.obs;

  // ---- 播放偏好与外观（循环 / 音量 / 碟片 / 就绪态）----
  final Rx<MusicLoopMode> loopMode = MusicLoopMode.sequence.obs;
  final RxDouble volume = 1.0.obs;
  final RxInt discStyleIndex = 0.obs;
  final RxBool isReady = false.obs;
  double _volumeBeforeMute = 1.0;

  // ---- 当前歌词 ----
  final RxString currentLyrics = ''.obs;

  // ---- 音频缓存配置与下载进度 ----
  final RxInt audioCacheMaxItems = _kAudioCacheDefaultMaxItems.obs;
  final RxBool audioCacheEnabled = _kAudioCacheDefaultEnabled.obs;
  final RxDouble downloadProgress = 0.0.obs;
  final RxBool isDownloading = false.obs;
  final RxInt downloadTotalBytes = 0.obs;
  final RxInt downloadReceivedBytes = 0.obs;
  final RxString downloadingFileHash = ''.obs;

  _MusicAudioHandler? _handler;
  Future<void>? _serviceInitFuture;
  final List<MusicProgressListener> _progressListeners = [];

  /// 被来电/其他 App 打断时是否正在播放（焦点归还后据此决定续播）
  bool _resumeAfterInterruption = false;
  bool _pendingNotificationPermissionGuide = false;

  /// 新内核适配层（`kNewPlaybackCore` 为 false 时永远是 null，走旧实现）
  _MusicNewCoreAdapter? _coreAdapter;

  _MusicNewCoreAdapter get _newCore =>
      _coreAdapter ??= _MusicNewCoreAdapter(this);

  /// 上次通过 mediaItem.add() 推送的 MediaItem 缓存键（index:title:durationSec）
  /// 防止 mediaItem.add() 被高频调用时干扰 playbackState 的通知更新（见 audio_service #1055）
  String? _lastSentMediaItemKey;

  /// audio_session 事件订阅（中断/耳机拔出），在 onClose 时取消
  final List<StreamSubscription<dynamic>> _audioSessionSubs = [];

  final Map<String, String> _lyricsCache = {};
  final Map<String, MusicListItem> _detailCache = {};
  final Set<String> _autoLyricTried = <String>{};
  int _detailFetchToken = 0;
  MusicPlaylistPaging? _paging;
  bool _pagingLoading = false;
  int _pagingToken = 0;
  final List<int> _shuffleHistory = <int>[];
  final Random _shuffleRandom = Random();

  final MusicAudioCacheService _audioCache = MusicAudioCacheService(
    options: const MusicAudioCacheOptions(
      enabled: _kAudioCacheDefaultEnabled,
      maxItems: _kAudioCacheDefaultMaxItems,
    ),
  );

  static const MethodChannel _iosAudioSessionChannel = MethodChannel(
    _kIosAudioSessionChannelName,
  );

  /// iOS/Android 使用 just_audio 以支持后台与锁屏播放
  bool get _useJustAudio =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android);

  @override
  void onInit() {
    super.onInit();
    // 初始化步骤按顺序执行；以后新增步骤只需插入列表，不必改动调用顺序
    final steps = <void Function()>[
      () => WidgetsBinding.instance.addObserver(this),
      () => _loadDiscStyleIndex(),
      () => _loadLoopMode(),
      () => unawaited(_initAudioCache()),
    ];
    for (final step in steps) {
      step();
    }
  }

  @override
  void onClose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final sub in _audioSessionSubs) {
      sub.cancel();
    }
    _audioSessionSubs.clear();
    unawaited(_audioCache.cancelActiveDownload());
    unawaited(_newCore.core.stop());
    super.onClose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (kIsWeb) return;
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      switch (state) {
        case AppLifecycleState.paused:
        case AppLifecycleState.inactive:
          if (isPlaying.value) {
            unawaited(_activateIosAudioSessionForPlayback());
          }
          break;
        case AppLifecycleState.resumed:
          if (isPlaying.value) {
            unawaited(_activateIosAudioSessionForPlayback());
          }
          break;
        default:
          break;
      }
      return;
    }
    if (defaultTargetPlatform == TargetPlatform.android) {
      if (state == AppLifecycleState.resumed &&
          _pendingNotificationPermissionGuide) {
        _pendingNotificationPermissionGuide = false;
        unawaited(_ensureNotificationPermission());
      }
    }
  }

  Future<void> setAudioCacheEnabled(bool enabled) async {
    audioCacheEnabled.value = enabled;
    await CacheManager().setBool(CacheKeys.musicAudioCacheEnabled, enabled);
    _syncAudioCacheOptions();
  }

  Future<void> setAudioCacheMaxItems(int maxItems) async {
    final localSafe = maxItems < 0 ? 0 : maxItems;
    audioCacheMaxItems.value = localSafe;
    await CacheManager().setInt(CacheKeys.musicAudioCacheMaxItems, localSafe);
    _syncAudioCacheOptions();
  }

  Future<void> clearAudioCache() async {
    await _audioCache.clearAll();
  }

  /// 把当前 Rx 里的缓存配置同步进缓存服务，两个 setter 共用，避免各拼一遍 copyWith。
  void _syncAudioCacheOptions() {
    _audioCache.updateOptions(
      _audioCache.options.copyWith(
        enabled: audioCacheEnabled.value,
        maxItems: audioCacheMaxItems.value,
      ),
    );
  }

  Future<MusicAudioCacheStats> getAudioCacheStats() async {
    return _audioCache.getStats();
  }

  Future<void> cancelDownload() async {
    await _audioCache.cancelActiveDownload();
    _setDownloadUi(downloading: false, fileHash: '', received: 0, total: 0);
  }

  Future<void> _initAudioCache() async {
    final enabled =
        CacheManager().getBool(CacheKeys.musicAudioCacheEnabled) ??
        _kAudioCacheDefaultEnabled;
    final maxItems =
        CacheManager().getInt(CacheKeys.musicAudioCacheMaxItems) ??
        _kAudioCacheDefaultMaxItems;
    audioCacheEnabled.value = enabled;
    audioCacheMaxItems.value = maxItems;
    _audioCache.updateOptions(
      MusicAudioCacheOptions(enabled: enabled, maxItems: maxItems),
    );
    await _audioCache.init();
  }

  Future<void> _activateIosAudioSessionForPlayback() async {
    if (kIsWeb) return;
    if (defaultTargetPlatform != TargetPlatform.iOS) return;
    try {
      await _iosAudioSessionChannel.invokeMethod('activatePlayback');
    } catch (_) {}
  }

  Future<void> _deactivateIosAudioSessionForPlayback() async {
    if (kIsWeb) return;
    if (defaultTargetPlatform != TargetPlatform.iOS) return;
    try {
      await _iosAudioSessionChannel.invokeMethod('deactivatePlayback');
    } catch (_) {}
  }

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
    downloadProgress.value = total <= 0 ? 0.0 : (received / total).clamp(0, 1);
  }
}
