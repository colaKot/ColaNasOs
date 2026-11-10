part of '../cola_player_controller.dart';

extension MusicPlayServicePlayback on MusicPlayServiceController {
  bool _isWebUnsupportedByPath(String path) {
    if (!kIsWeb) return false;
    final base = path.split(RegExp(r'[?#]')).first;
    final localName = base.split('/').last.toLowerCase();
    return localName.endsWith('.ape') || localName.endsWith('.wma');
  }

  bool _preferTranscodeByExt(String ext) {
    final e = ext.trim().toLowerCase();
    if (e.isEmpty) return false;
    return e == 'ape' || e == 'wma';
  }

  bool _isPlayableItem(MusicListItem item) {
    final path = _resolvePlayablePath(item).trim();
    if (path.isEmpty) return false;
    return true;
  }

  Future<void> _handleNoPlayableItems() async {
    playlist.clear();
    playlist.refresh();
    currentIndex.value = 0;
    currentLyrics.value = '';
    position.value = Duration.zero;
    duration.value = Duration.zero;
    buffered.value = Duration.zero;
    _paging = null;
    _pagingToken++;
    _pagingLoading = false;
    _shuffleHistory.clear();
    await _newCore.core.stop();
    isPlaying.value = false;
    _handler?.updateQueue(const <MediaItem>[]);
    _syncHandlerPlaybackState();
  }

  String get discAsset {
    final localAssets = MusicPlayServiceController.discAssets;
    final localIdx = discStyleIndex.value.clamp(0, localAssets.length - 1);
    return localAssets[localIdx];
  }

  void nextDiscStyle() {
    final localMax = MusicPlayServiceController.discAssets.length;
    final next = localMax <= 0 ? 0 : (discStyleIndex.value + 1) % localMax;
    discStyleIndex.value = next;
    CacheManager().setInt(CacheKeys.musicDiscStyleIndex, next);
  }

  void toggleMute() {
    final v = volume.value;
    if (v > 0.01) {
      _volumeBeforeMute = v;
      CacheManager().setDouble(CacheKeys.musicVolumeBeforeMute, v);
      setVolume(0);
      return;
    }
    final localRestore = (_volumeBeforeMute > 0.01 ? _volumeBeforeMute : 1.0);
    setVolume(localRestore);
  }

  void addProgressListener(MusicProgressListener listener) {
    _progressListeners.add(listener);
  }

  void removeProgressListener(MusicProgressListener listener) {
    _progressListeners.remove(listener);
  }

  Future<void> playFromList({
    required List<MusicListItem> items,
    required MusicListItem startItem,
    bool autoPlay = true,
    MusicPlaylistPaging? paging,
  }) async {
    final localPlayable = _filterPlayable(items);
    if (localPlayable.isEmpty) {
      await _handleNoPlayableItems();
      return;
    }
    final localStartPath = _resolvePlayablePath(startItem).trim();
    final localStartInOriginal = startItem.id > 0
        ? items.indexWhere((e) => e.id == startItem.id)
        : (localStartPath.isNotEmpty
              ? items.indexWhere(
                  (e) => _resolvePlayablePath(e).trim() == localStartPath,
                )
              : -1);

    var resolvedStartInOriginal = -1;
    if (localStartInOriginal >= 0 && localStartInOriginal < items.length) {
      for (var i = localStartInOriginal; i < items.length; i++) {
        if (_isPlayableItem(items[i])) {
          resolvedStartInOriginal = i;
          break;
        }
      }
      if (resolvedStartInOriginal < 0) {
        resolvedStartInOriginal = items.indexWhere(_isPlayableItem);
      }
    } else {
      resolvedStartInOriginal = items.indexWhere(_isPlayableItem);
    }
    final localResolvedItem = resolvedStartInOriginal >= 0
        ? items[resolvedStartInOriginal]
        : null;
    final localResolvedPath = localResolvedItem == null
        ? ''
        : _resolvePlayablePath(localResolvedItem).trim();
    final localIdx = localResolvedItem == null
        ? 0
        : (localResolvedItem.id > 0
              ? localPlayable.indexWhere((e) => e.id == localResolvedItem.id)
              : (localResolvedPath.isNotEmpty
                    ? localPlayable.indexWhere(
                        (e) =>
                            _resolvePlayablePath(e).trim() == localResolvedPath,
                      )
                    : -1));
    await setPlaylist(
      localPlayable,
      startIndex: localIdx >= 0 ? localIdx : 0,
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
    final localPlayable = _filterPlayable(items);
    if (localPlayable.isEmpty) {
      await _handleNoPlayableItems();
      return;
    }
    // 新内核：队列、状态、自动连播都交给 playback/，这里只把列表交给它。
    // 分页信息仍留在旧字段上 —— 队尾补给走 `onExhausted` 钩子复用 _loadMoreAndAppendInPlace。
    _paging = paging;
    _pagingToken++;
    _pagingLoading = false;
    _shuffleHistory.clear();
    playlist.assignAll(localPlayable);
    final localSafe = startIndex.clamp(0, localPlayable.length - 1);
    currentIndex.value = localSafe;
    _invalidateMediaItemCache();
    await _ensureNotificationPermission();
    await _refreshDetailForIndex(localSafe);
    _handler?.updateQueue(_buildQueueMediaItems());
    await _newCore.playAll(
      localPlayable,
      startIndex: localSafe,
      autoPlay: autoPlay,
    );
    return;
  }

  Future<void> playAt(int index) async {
    if (playlist.isEmpty) return;
    final localSafe = index.clamp(0, playlist.length - 1);
    currentIndex.value = localSafe;
    _invalidateMediaItemCache();
    _syncMediaItem(localSafe);
    await _refreshDetailForIndex(localSafe);
    await _newCore.jumpTo(localSafe);
    return;
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
    return;
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
        _volumeBeforeMute,
      );
    }
  }

  Future<void> setLoopMode(MusicLoopMode mode) async {
    if (loopMode.value == mode) return;
    loopMode.value = mode;
    await CacheManager().setInt(CacheKeys.musicLoopModeIndex, mode.index);
    await _newCore.applyLoop(mode);
    return;
  }

  Future<void> _loadMoreAndAppendInPlace({required int currentIndex}) async {
    final paging = _paging;
    if (paging == null) return;

    final localToken = ++_pagingToken;
    _pagingLoading = true;
    try {
      final localMore = await paging.loadMore();
      if (isClosed || localToken != _pagingToken) return;
      if (localMore.isEmpty) return;

      final localExistingPaths = playlist
          .map((e) => _resolvePlayablePath(e).trim())
          .toSet();
      final localExtra = localMore
          .map((e) => e)
          .where((e) => !e.isSeries)
          .where((e) => _resolvePlayablePath(e).trim().isNotEmpty)
          .where(
            (e) => !localExistingPaths.contains(_resolvePlayablePath(e).trim()),
          )
          .toList(growable: false);
      if (localExtra.isEmpty) return;

      playlist.addAll(localExtra);
      playlist.refresh();
      _handler?.updateQueue(_buildQueueMediaItems());
    } catch (_) {
    } finally {
      if (!isClosed && localToken == _pagingToken) {
        _pagingLoading = false;
      }
    }
  }

  void _syncMediaItem(int index, {bool forceUpdate = false}) {
    if (_handler == null) return;
    if (index < 0 || index >= playlist.length) return;
    final localD = duration.value;
    final base = _buildMediaItem(playlist[index]);
    final item =
        (base.duration == null || base.duration! <= Duration.zero) &&
            localD > Duration.zero
        ? base.copyWith(duration: localD)
        : base;
    final localKey =
        '$index:${item.title}:${item.artist}:${item.duration?.inSeconds ?? -1}';
    final shouldUpdate = forceUpdate || localKey != _lastSentMediaItemKey;
    if (shouldUpdate) {
      _lastSentMediaItemKey = localKey;
      // 先更新 queue（含当前项 duration），再设当前 mediaItem，确保控制中心/锁屏能拿到总时长
      if (item.duration != null && item.duration! > Duration.zero) {
        _handler!.updateQueue(_buildQueueMediaItems());
      }
      _handler!.mediaItem.add(item);
    }
  }

  void _invalidateMediaItemCache() {
    _lastSentMediaItemKey = null;
  }

  /// 构建用于 updateQueue 的列表，当前项会注入 controller 的 duration，确保控制中心/锁屏显示总时长。
  List<MediaItem> _buildQueueMediaItems() {
    final list = playlist.map(_buildMediaItem).toList();
    final localIdx = currentIndex.value.clamp(0, list.length - 1);
    if (localIdx >= list.length) return list;
    final localD = duration.value;
    final base = list[localIdx];
    if ((base.duration == null || base.duration! <= Duration.zero) &&
        localD > Duration.zero) {
      list[localIdx] = base.copyWith(duration: localD);
    }
    return list;
  }

  List<MusicListItem> _filterPlayable(List<MusicListItem> items) {
    return items
        .where((e) => _resolvePlayablePath(e).trim().isNotEmpty)
        .toList();
  }

  MediaItem _buildMediaItem(MusicListItem item) {
    final localCoverPath = item.isSeries
        ? item.firstFilePath.trim()
        : (item.fullPath.trim().isNotEmpty
              ? item.fullPath.trim()
              : _resolvePlayablePath(item));
    final localCoverUrl =
        !ApiController.instance.isP2pMode &&
            localCoverPath.isNotEmpty &&
            item.hasInnerCover == 1
        ? ApiController.instance.getMusicCoverUrl(
            filePath: localCoverPath,
            size: 500,
          )
        : '';
    return MediaItem(
      id: _buildPlayUrl(item),
      title: item.displayTitle,
      artist: item.artist.trim().isNotEmpty ? item.artist.trim() : null,
      album: item.album.trim().isNotEmpty ? item.album.trim() : null,
      artUri: localCoverUrl.isNotEmpty ? Uri.parse(localCoverUrl) : null,
      // 与库/API 一致：duration 字段为整秒（非毫秒）
      duration: item.duration > 0 ? Duration(seconds: item.duration) : null,
    );
  }

  String _resolvePlayablePath(MusicListItem item) {
    if (item.isSeries) {
      final localP = item.firstFilePath.trim();
      if (localP.isNotEmpty) return localP;
    }
    final localFull = item.fullPath.trim();
    if (localFull.isNotEmpty) return localFull;
    final localName = item.filename.trim();
    final base = item.path.trim();
    if (base.isNotEmpty && localName.isNotEmpty) return '$base/$localName';
    return base;
  }

  String _buildPlayUrl(MusicListItem item) {
    final path = _resolvePlayablePath(item);
    return ApiController.instance.getRawFileUrl(
      path,
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
    final localHandler = _handler;
    if (localHandler == null) return;

    // 新内核下 `_player` 永远是 null，照旧取值会让通知栏/锁屏一直显示「暂停」。
    // 这里按新内核的互斥状态映射 processingState。
    final state = _coreAdapter?.core.state;
    localHandler._syncPlaybackState(
      updatePosition: position.value,
      queueIndex: currentIndex.value.clamp(
        0,
        playlist.isEmpty ? 0 : playlist.length - 1,
      ),
      processingState: switch (state) {
        null || PlaybackIdle() => AudioProcessingState.idle,
        PlaybackLoading() => AudioProcessingState.loading,
        PlaybackCompleted() => AudioProcessingState.completed,
        PlaybackFailed() => AudioProcessingState.error,
        PlaybackReady() || PlaybackPaused() => AudioProcessingState.ready,
      },
      playing: state?.isPlaying ?? false,
      bufferedPosition: buffered.value,
    );
    return;
  }

  int? _resolveNextIndex({required bool forward}) {
    if (playlist.isEmpty) return null;
    final mode = loopMode.value;
    final localIdx = currentIndex.value.clamp(0, playlist.length - 1);

    if (mode == MusicLoopMode.shuffle) {
      if (!forward && _shuffleHistory.isNotEmpty) {
        return _shuffleHistory.removeLast().clamp(0, playlist.length - 1);
      }
      if (playlist.length <= 1) return localIdx;
      var guard = 0;
      var next = localIdx;
      while (next == localIdx && guard++ < 10) {
        next = _shuffleRandom.nextInt(playlist.length);
      }
      return next;
    }

    if (forward) {
      if (localIdx < playlist.length - 1) return localIdx + 1;
      if (mode == MusicLoopMode.listLoop) return 0;
      return null;
    } else {
      if (localIdx > 0) return localIdx - 1;
      if (mode == MusicLoopMode.listLoop) return playlist.length - 1;
      return null;
    }
  }
}
