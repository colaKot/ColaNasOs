part of '../cola_player_controller.dart';

/// 后台服务的通知渠道配置。抽成文件级常量，避免初始化流程里夹一大段参数表。
final AudioServiceConfig _backgroundAudioConfig = AudioServiceConfig(
  androidStopForegroundOnPause: false,
  androidShowNotificationBadge: false,
  androidResumeOnClick: true,
  androidNotificationClickStartsActivity: true,
  androidNotificationChannelName: 'Music Playback',
  androidNotificationChannelId: 'colanas.music.playback',
  androidNotificationChannelDescription: 'Background music playback controls',
);

/// 声明为音乐用途 + 永久焦点，系统才会把媒体按键和控制中心入口关联到本应用。
const AudioSessionConfiguration _musicAudioSession = AudioSessionConfiguration(
  androidWillPauseWhenDucked: true,
  androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
  androidAudioAttributes: AndroidAudioAttributes(
    contentType: AndroidAudioContentType.music,
    usage: AndroidAudioUsage.media,
    flags: AndroidAudioFlags.none,
  ),
);

extension MusicPlayServiceLifecycle on MusicPlayServiceController {
  bool get _supportBackground =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);

  /// 上一次初始化失败时（某些设备的 MediaBrowserCompat 连不上），清掉缓存的
  /// future 后整轮重试；成功则直接复用，避免多个调用点同时建原生连接。
  Future<void> _awaitEarlierInit() async {
    final earlier = _serviceInitFuture;
    if (earlier == null) return;
    try {
      await earlier;
    } catch (_) {
      _serviceInitFuture = null;
      await _initService();
    }
  }

  Future<void> _bootstrap() async {
    registerFvp();
    if (_supportBackground) {
      _handler = await AudioService.init(
        builder: () => _MusicAudioHandler(this),
        config: _backgroundAudioConfig,
      );
    }
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      await _configureAndroidAudioSession();
    }
    await _loadAndApplyVolume();
    _bindStreams();
    isReady.value = true;
  }

  Future<void> _initService() async {
    if (_serviceInitFuture != null) {
      await _awaitEarlierInit();
      return;
    }
    final attempt = _bootstrap();
    _serviceInitFuture = attempt;
    try {
      await attempt;
    } catch (_) {
      _serviceInitFuture = null;
      rethrow;
    }
  }

  Future<void> _configureAndroidAudioSession() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(_musicAudioSession);
      _subscribeAudioSessionEvents(session);
    } catch (_) {
      // 没有音频焦点服务的设备不影响播放，静默跳过
    }
  }

  void _subscribeAudioSessionEvents(AudioSession session) {
    // 被电话或其他应用打断时先暂停，焦点回来后再按中断前的播放意图续播。
    _audioSessionSubs.add(
      session.interruptionEventStream.listen((event) {
        if (isClosed) return;
        if (event.begin) {
          // 记下「被打断时是否正在放」，焦点回来据此决定要不要续
          _resumeAfterInterruption = isPlaying.value;
          if (_resumeAfterInterruption) {
            // 走 pause() 而不是直接操作旧播放器：新内核由状态机接管
            unawaited(pause());
            _syncHandlerPlaybackState();
          }
        } else if (event.type != AudioInterruptionType.unknown &&
            _resumeAfterInterruption) {
          _resumeAfterInterruption = false;
          unawaited(play());
        }
      }),
    );
    // 耳机被拔出（Becoming Noisy）时停止当前播放，避免声音外放。
    _audioSessionSubs.add(
      session.becomingNoisyEventStream.listen((_) {
        if (isClosed) return;
        if (isPlaying.value) {
          unawaited(pause());
        }
      }),
    );
  }

  /// 本地缓存读取统一兜底：缓存层异常不该阻断服务初始化。
  T? _stored<T>(T? Function() read) {
    try {
      return read();
    } catch (_) {
      return null;
    }
  }

  void _loadDiscStyleIndex() {
    final value = _stored<int>(
      () => CacheManager().getInt(CacheKeys.musicDiscStyleIndex),
    );
    if (value == null) return;
    final last = MusicPlayServiceController.discAssets.length - 1;
    discStyleIndex.value = value.clamp(0, last);
  }

  void _loadLoopMode() {
    final value = _stored<int>(
      () => CacheManager().getInt(CacheKeys.musicLoopModeIndex),
    );
    if (value == null || value < 0 || value >= MusicLoopMode.values.length) {
      return;
    }
    loopMode.value = MusicLoopMode.values[value];
  }

  Future<void> _loadAndApplyVolume() async {
    final beforeMute = _stored<double>(
      () => CacheManager().getDouble(CacheKeys.musicVolumeBeforeMute),
    );
    if (beforeMute != null) {
      _volumeBeforeMute = beforeMute.clamp(0.0, 1.0);
    }
    final saved = _stored<double>(
      () => CacheManager().getDouble(CacheKeys.musicVolume),
    );
    if (saved == null) return;
    final level = saved.clamp(0.0, 1.0);
    volume.value = level;
    // 音量归状态机持有，启动时的缓存值直接送进引擎
    try {
      await _coreAdapter?.core.setVolume(level);
    } catch (_) {
      return;
    }
    if (level > 0.01) _volumeBeforeMute = level;
  }

  /// 旧实现靠 500ms 轮询把播放器状态抄进 Rx 字段；新内核把
  /// position / duration / buffered / playing 都做成事件流，由适配层直接投影，
  /// 这里已经没有要绑的东西了。保留方法名是为了让 `_initService` 的初始化顺序
  /// 保持原样（音量 → 绑定 → isReady），避免以后再插逻辑时漏掉一步。
  void _bindStreams() {}

  void _askOpenNotificationSettings() {
    DialogUtil.showConfirmDialog(
      title: 'permission_notification_title'.tr,
      onConfirm: () => openAppSettings(),
      content: 'permission_notification_content'.tr,
      confirmText: 'open_settings'.tr,
      cancelText: 'cancel'.tr,
    );
  }

  Future<void> _ensureNotificationPermission() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    final status = await Permission.notification.status;
    if (status.isGranted) return;

    final phase = WidgetsBinding.instance.lifecycleState;
    if (phase != null && phase != AppLifecycleState.resumed) {
      // 后台期间不弹系统权限框，等回到前台再补
      _pendingNotificationPermissionGuide = true;
      return;
    }
    if (!status.isPermanentlyDenied) {
      final requested = await Permission.notification.request();
      if (requested.isGranted) return;
    }
    _askOpenNotificationSettings();
  }
}
