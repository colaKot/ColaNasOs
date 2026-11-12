part of '../cola_player_controller.dart';

/// 需要走转码回退的扩展名集合（浏览器端与原文件格式都不支持的少数几种）。
const Set<String> _kTranscodeFallbackExts = <String>{'ape', 'wma'};

extension MusicPlayServicePlayback on MusicPlayServiceController {
  bool _isWebUnsupportedByPath(String path) {
    if (!kIsWeb) return false;
    final clean = path.split(RegExp(r'[?#]')).first;
    final dot = clean.lastIndexOf('.');
    if (dot < 0 || dot == clean.length - 1) return false;
    final ext = clean.substring(dot + 1).toLowerCase();
    return _kTranscodeFallbackExts.contains(ext);
  }

  bool _preferTranscodeByExt(String ext) {
    final normalized = ext.trim().toLowerCase();
    return normalized.isNotEmpty && _kTranscodeFallbackExts.contains(normalized);
  }

  bool _isPlayableItem(MusicListItem item) {
    return _resolvePlayablePath(item).trim().isNotEmpty;
  }

  Future<void> _handleNoPlayableItems() async {
    _paging = null;
    _pagingToken += 1;

    playlist.clear();
    playlist.refresh();
    currentIndex.value = 0;
    currentLyrics.value = '';
    position.value = Duration.zero;
    duration.value = Duration.zero;
    buffered.value = Duration.zero;

    await _newCore.core.stop();
    isPlaying.value = false;
    _handler?.updateQueue(const <MediaItem>[]);
    _syncHandlerPlaybackState();
  }

  String get discAsset {
    final assets = MusicPlayServiceController.discAssets;
    if (assets.isEmpty) return '';
    final idx = discStyleIndex.value.clamp(0, assets.length - 1);
    return assets[idx];
  }

  void nextDiscStyle() {
    final total = MusicPlayServiceController.discAssets.length;
    if (total <= 0) {
      discStyleIndex.value = 0;
      return;
    }
    final current = discStyleIndex.value.clamp(0, total - 1);
    final next = (current + 1) % total;
    discStyleIndex.value = next;
    CacheManager().setInt(CacheKeys.musicDiscStyleIndex, next);
  }

  void toggleMute() {
    final current = volume.value;
    if (current <= 0.01) {
      setVolume(_volumeBeforeMute > 0.01 ? _volumeBeforeMute : 1.0);
      return;
    }
    _volumeBeforeMute = current;
    CacheManager().setDouble(CacheKeys.musicVolumeBeforeMute, current);
    setVolume(0);
  }

  void addProgressListener(MusicProgressListener listener) {
    _progressListeners.add(listener);
  }

  void removeProgressListener(MusicProgressListener listener) {
    _progressListeners.remove(listener);
  }

  /// 在原列表里找到「从 startItem 开始、往后第一个可播放项」的下标。
  int _locateStartIndex(List<MusicListItem> raw, MusicListItem startItem) {
    final startPath = _resolvePlayablePath(startItem).trim();
    var cursor = -1;
    if (startItem.id > 0) {
      cursor = raw.indexWhere((e) => e.id == startItem.id);
    } else if (startPath.isNotEmpty) {
      cursor = raw.indexWhere((e) => _resolvePlayablePath(e).trim() == startPath);
    }
    if (cursor < 0) return raw.indexWhere(_isPlayableItem);
    while (cursor < raw.length && !_isPlayableItem(raw[cursor])) {
      cursor += 1;
    }
    return cursor < raw.length ? cursor : raw.indexWhere(_isPlayableItem);
  }

  Future<void> playFromList({
    required List<MusicListItem> items,
    required MusicListItem startItem,
    bool autoPlay = true,
    MusicPlaylistPaging? paging,
  }) async {
    final playable = _filterPlayable(items);
    if (playable.isEmpty) {
      await _handleNoPlayableItems();
      return;
    }

    final located = _locateStartIndex(items, startItem);
    final seed = located >= 0 && located < items.length ? items[located] : null;
    final seedPath = seed == null ? '' : _resolvePlayablePath(seed).trim();
    var startIndex = -1;
    if (seed != null) {
      startIndex = seed.id > 0
          ? playable.indexWhere((e) => e.id == seed.id)
          : (seedPath.isEmpty
                ? -1
                : playable.indexWhere(
                    (e) => _resolvePlayablePath(e).trim() == seedPath,
                  ));
    }

    await setPlaylist(
      playable,
      startIndex: startIndex >= 0 ? startIndex : 0,
      autoPlay: autoPlay,
      paging: paging,
    );
  }

  Future<void> setPlaylist(
    List<MusicListItem> items, {
    int startIndex = 0,
    bool autoPlay = true,
    MusicPlaylistPaging? paging,
  }) async {
    final playable = _filterPlayable(items);
    if (playable.isEmpty) {
      await _handleNoPlayableItems();
      return;
    }

    // 队列只保存可播放项；分页句柄留在 controller，由 onExhausted 触发补页。
    _paging = paging;
    _pagingToken += 1;

    playlist.assignAll(playable);
    final safe = startIndex.clamp(0, playable.length - 1);
    currentIndex.value = safe;
    _invalidateMediaItemCache();

    await _ensureNotificationPermission();
    await _refreshDetailForIndex(safe);
    _handler?.updateQueue(_buildQueueMediaItems());
    await _newCore.playAll(playable, startIndex: safe, autoPlay: autoPlay);
  }

  Future<void> playAt(int index) async {
    final total = playlist.length;
    if (total == 0) return;
    final safe = index.clamp(0, total - 1);
    currentIndex.value = safe;
    _invalidateMediaItemCache();
    _syncMediaItem(safe);
    await _refreshDetailForIndex(safe);
    await _newCore.jumpTo(safe);
  }

  Future<void> play() async {
    await _activateIosAudioSessionForPlayback();
    await _ensureNotificationPermission();
    return _newCore.resume();
  }

  Future<void> pause() async {
    return _newCore.pause();
  }

  Future<void> resume() async {
    await _activateIosAudioSessionForPlayback();
    await _ensureNotificationPermission();
    return _newCore.resume();
  }

  Future<void> stop() async {
    await _newCore.core.stop();
    _syncHandlerPlaybackState();
    await _deactivateIosAudioSessionForPlayback();
  }

  Future<void> playNext({bool forcePlay = false}) async {
    if (playlist.isEmpty) return;
    return _newCore.next();
  }

  Future<void> playPrevious({bool forcePlay = false}) async {
    if (playlist.isEmpty) return;
    return _newCore.previous();
  }

  Future<void> seekTo(Duration position) async {
    return _newCore.seek(position);
  }

  Future<void> setVolume(double value) async {
    final next = value.clamp(0.0, 1.0);
    volume.value = next;
    await _newCore.setVolume(next);
    await CacheManager().setDouble(CacheKeys.musicVolume, next);
    if (next > 0.01) {
      _volumeBeforeMute = next;
      await CacheManager().setDouble(
        CacheKeys.musicVolumeBeforeMute,
        next,
      );
    }
  }

  Future<void> setLoopMode(MusicLoopMode mode) async {
    if (loopMode.value == mode) return;
    loopMode.value = mode;
    await CacheManager().setInt(CacheKeys.musicLoopModeIndex, mode.index);
    await _newCore.applyLoop(mode);
  }

  Future<void> _loadMoreAndAppendInPlace({required int currentIndex}) async {
    final paging = _paging;
    if (paging == null) return;

    final token = ++_pagingToken;
    try {
      final more = await paging.loadMore();
      if (isClosed || token != _pagingToken || more.isEmpty) return;

      final knownPaths = <String>{};
      for (final item in playlist) {
        knownPaths.add(_resolvePlayablePath(item).trim());
      }

      final extra = <MusicListItem>[];
      for (final item in more) {
        if (item.isSeries) continue;
        final path = _resolvePlayablePath(item).trim();
        if (path.isEmpty || !knownPaths.add(path)) continue;
        extra.add(item);
      }
      if (extra.isEmpty) return;

      playlist.addAll(extra);
      playlist.refresh();
      _handler?.updateQueue(_buildQueueMediaItems());
    } catch (_) {
      // 补页失败不打断当前播放，下次触底再试。
    }
  }

  void _syncMediaItem(int index, {bool forceUpdate = false}) {
    final handler = _handler;
    if (handler == null) return;
    if (index < 0 || index >= playlist.length) return;

    final base = _buildMediaItem(playlist[index]);
    final total = duration.value;
    final needsDuration =
        (base.duration == null || base.duration! <= Duration.zero) &&
        total > Duration.zero;
    final item = needsDuration ? base.copyWith(duration: total) : base;

    final key = '$index|${item.title}|${item.artist}|${item.duration?.inSeconds ?? -1}';
    if (!forceUpdate && key == _lastSentMediaItemKey) return;

    _lastSentMediaItemKey = key;
    // 当前项时长先写进队列，控制中心/锁屏才能显示正确的总时长。
    if (item.duration != null && item.duration! > Duration.zero) {
      handler.updateQueue(_buildQueueMediaItems());
    }
    handler.mediaItem.add(item);
  }

  void _invalidateMediaItemCache() {
    _lastSentMediaItemKey = null;
  }

  /// 生成通知栏/锁屏使用的队列快照，并补齐当前项缺失的时长。
  List<MediaItem> _buildQueueMediaItems() {
    final snapshot = playlist.map(_buildMediaItem).toList(growable: false);
    if (snapshot.isEmpty) return snapshot;

    final idx = currentIndex.value.clamp(0, snapshot.length - 1);
    final total = duration.value;
    if (total <= Duration.zero) return snapshot;

    final current = snapshot[idx];
    final missingDuration =
        current.duration == null || current.duration! <= Duration.zero;
    if (!missingDuration) return snapshot;

    final patched = snapshot.toList(growable: false);
    patched[idx] = current.copyWith(duration: total);
    return patched;
  }

  List<MusicListItem> _filterPlayable(List<MusicListItem> items) {
    return [
      for (final item in items)
        if (_resolvePlayablePath(item).trim().isNotEmpty) item,
    ];
  }

  MediaItem _buildMediaItem(MusicListItem item) {
    final String coverSource;
    if (item.isSeries) {
      coverSource = item.firstFilePath.trim();
    } else {
      final full = item.fullPath.trim();
      coverSource = full.isNotEmpty ? full : _resolvePlayablePath(item);
    }

    final useCover =
        !ApiController.instance.isP2pMode &&
        coverSource.isNotEmpty &&
        item.hasInnerCover == 1;
    final coverUrl = useCover
        ? ApiController.instance.getMusicCoverUrl(
            filePath: coverSource,
            size: 500,
          )
        : '';

    return MediaItem(
      id: _buildPlayUrl(item),
      title: item.displayTitle,
      artist: item.artist.trim().isEmpty ? null : item.artist.trim(),
      album: item.album.trim().isEmpty ? null : item.album.trim(),
      artUri: coverUrl.isEmpty ? null : Uri.parse(coverUrl),
      // 服务端 duration 为整秒；这里换算成 Duration 交给 audio_service。
      duration: item.duration > 0 ? Duration(seconds: item.duration) : null,
    );
  }

  String _resolvePlayablePath(MusicListItem item) {
    final candidates = <String>[
      if (item.isSeries) item.firstFilePath,
      item.fullPath,
    ];
    for (final raw in candidates) {
      final path = raw.trim();
      if (path.isNotEmpty) return path;
    }

    final dir = item.path.trim();
    final name = item.filename.trim();
    if (dir.isNotEmpty && name.isNotEmpty) {
      return '$dir/$name';
    }
    return dir;
  }

  String _buildPlayUrl(MusicListItem item) {
    return ApiController.instance.getRawFileUrl(
      _resolvePlayablePath(item),
      withAccessToken: true,
      isRawFile: true,
      p2pChannel: 'download',
    );
  }

  void _notifyProgress() {
    for (final listener in _progressListeners) {
      listener(position.value, duration.value, buffered.value);
    }
  }

  void _syncHandlerPlaybackState() {
    final handler = _handler;
    if (handler == null) return;

    // 新内核没有旧 `_player`，这里按引擎状态映射，避免通知栏一直停在「暂停」。
    final state = _coreAdapter?.core.state;
    handler._syncPlaybackState(
      updatePosition: position.value,
      queueIndex: currentIndex.value.clamp(
        0,
        playlist.isEmpty ? 0 : playlist.length - 1,
      ),
      processingState: switch (state) {
        null => AudioProcessingState.idle,
        PlaybackIdle() => AudioProcessingState.idle,
        PlaybackLoading() => AudioProcessingState.loading,
        PlaybackCompleted() => AudioProcessingState.completed,
        PlaybackFailed() => AudioProcessingState.error,
        PlaybackReady() || PlaybackPaused() => AudioProcessingState.ready,
      },
      playing: state?.isPlaying ?? false,
      bufferedPosition: buffered.value,
    );
  }
}
