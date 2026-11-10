part of '../cola_player_controller.dart';

/// 是否启用新的播放内核（`playback/` 下的状态机实现）。
///
/// 关掉就完全回到旧实现（`_player` + 五个布尔标志那套），行为不变。
/// 之所以留开关而不是直接删旧代码：播放牵扯后台服务、通知栏、分页追加、
/// 音频缓存，任何一处没接好都会退化成「能出声但别处坏掉」，
/// 留着旧路径才能一行回退。
const bool kNewPlaybackCore = true;

/// 新旧内核之间的适配层。
///
/// UI 完全不知道它存在：对外仍然是 [MusicPlayServiceController] 的那套 Rx 字段
/// 和方法名，这里负责把新内核的**单向状态**翻译回去，并把「缓存 / 分页 / 通知栏 /
/// 歌词」这些老能力挂到新内核的钩子上。
class _MusicNewCoreAdapter {
  _MusicNewCoreAdapter(this._owner) {
    _bindHooks();
    _core.addListener(_syncToOwner);
  }

  final MusicPlayServiceController _owner;
  final PlaybackController _core = PlaybackController(MediaKitPlaybackEngine());

  bool _hooksBound = false;

  PlaybackController get core => _core;

  /// 曲目唯一键：优先用后端 indexId，没有就退回文件路径
  static String idOf(MusicListItem item) =>
      item.id > 0 ? 'i${item.id}' : 'p${_pathOf(item)}';

  static String _pathOf(MusicListItem item) {
    final full = item.fullPath.trim();
    if (full.isNotEmpty) return full;
    final name = item.filename.trim();
    final dir = item.path.trim();
    if (dir.isNotEmpty && name.isNotEmpty) return '$dir/$name';
    return dir;
  }

  void _bindHooks() {
    if (_hooksBound) return;
    _hooksBound = true;

    // 打开前解析真实地址：优先走音频缓存（边下边播 / 复用已下载文件），
    // 缓存不可用再退回直链。转码流地址会随分片变化，**不进缓存**直接播。
    _core.resolveUri = (track) async {
      final item = _itemOf(track);
      if (item == null) return track.uri;

      final direct = _owner._buildPlayUrl(item);
      final path = _pathOf(item);
      Uri fallback() =>
          direct.trim().isEmpty ? Uri.file(path) : Uri.parse(direct);

      final ext = item.ext.trim().isNotEmpty
          ? item.ext.trim()
          : (path.contains('.') ? path.split('.').last : '');
      // ape / wma 以及 web 端不支持的容器要走转码，地址不稳定，跳过缓存
      if (_owner._preferTranscodeByExt(ext) ||
          _owner._isWebUnsupportedByPath(path)) {
        return fallback();
      }

      try {
        final source = await _owner._audioCache.prepareSource(
          refreshAuthToken: ApiController.instance.refreshAuthToken,
          onProgress: (progress) {
            if (_owner.isClosed) return;
            if (progress.finished) {
              _owner._setDownloadUi(
                downloading: false,
                fileHash: '',
                received: 0,
                total: 0,
              );
            } else {
              _owner._setDownloadUi(
                downloading: true,
                fileHash: item.fileHash,
                received: progress.receivedBytes,
                total: progress.totalBytes,
              );
            }
          },
          fileSize: item.size,
          fileHash: item.fileHash.trim(),
          fileExt: ext.isEmpty ? 'dat' : ext,
          buildUrl: () async => direct,
        );
        final local = source.filePath?.trim() ?? '';
        if (local.isNotEmpty) return Uri.file(local);
        final url = source.url.trim();
        return url.isEmpty ? fallback() : Uri.parse(url);
      } catch (_) {
        // 缓存层出错不能让播放挂掉，退回直链
        return fallback();
      }
    };

    // 播到队尾：按分页拉下一页并追加进队列，接住「列表翻页播放」
    _core.onExhausted = () async {
      final before = _owner.playlist.length;
      await _owner._loadMoreAndAppendInPlace(
        currentIndex: before == 0 ? 0 : before - 1,
      );
      if (_owner.playlist.length <= before) return false;
      final added = _owner.playlist
          .skip(before)
          .map(trackOf)
          .toList(growable: false);
      if (added.isEmpty) return false;
      _core.appendToQueue(added);
      return true;
    };
  }

  MusicListItem? _itemOf(Track track) {
    final origin = track.origin;
    if (origin is MusicListItem) return origin;
    for (final item in _owner.playlist) {
      if (idOf(item) == track.id) return item;
    }
    return null;
  }

  static Track trackOf(MusicListItem item) => Track(
    id: idOf(item),
    // uri 只是占位，真正地址由 resolveUri 决定；这里给一个合法值避免空 Uri
    uri: Uri.parse('colanas://track/${Uri.encodeComponent(idOf(item))}'),
    title: item.displayTitle,
    artist: item.artist.trim(),
    album: item.album.trim(),
    duration: item.duration > 0 ? Duration(seconds: item.duration) : null,
    origin: item,
  );

  // ------------------------------------------------------------------ 对外入口

  Future<void> playAll(
    List<MusicListItem> items, {
    required int startIndex,
    required bool autoPlay,
  }) async {
    await _owner._initService();
    await _owner._activateIosAudioSessionForPlayback();
    final tracks = items.map(trackOf).toList(growable: false);
    if (tracks.isEmpty) {
      await _owner._handleNoPlayableItems();
      return;
    }
    await _core.playAll(
      tracks,
      startAt: startIndex.clamp(0, tracks.length - 1),
      loop: _loopOf(_owner.loopMode.value),
    );
    // 引擎实例是新的，把用户偏好补上（音量、随机）
    await _core.setVolume(_owner.volume.value);
    _core.setShuffle(_owner.loopMode.value == MusicLoopMode.shuffle);
    if (!autoPlay) await _core.togglePlayPause();
  }

  Future<void> jumpTo(int index) => _core.jumpTo(index);

  Future<void> toggle() => _core.togglePlayPause();

  Future<void> pause() async {
    if (_core.isPlaying) await _core.togglePlayPause();
  }

  Future<void> resume() async {
    if (!_core.isPlaying) await _core.togglePlayPause();
  }

  Future<void> seek(Duration position) => _core.seek(position);

  Future<void> next() => _core.next();

  Future<void> previous() => _core.previous();

  Future<void> setVolume(double value) => _core.setVolume(value);

  Future<void> applyLoop(MusicLoopMode mode) async {
    _core.setShuffle(mode == MusicLoopMode.shuffle);
    await _core.setLoop(_loopOf(mode));
  }

  /// 旧的四档循环 → 新内核的三档 + 一个随机开关
  static PlaybackLoop _loopOf(MusicLoopMode mode) => switch (mode) {
    MusicLoopMode.sequence => PlaybackLoop.none,
    MusicLoopMode.listLoop => PlaybackLoop.all,
    MusicLoopMode.singleLoop => PlaybackLoop.one,
    // 「随机」的循环语义是「放完一圈回到开头」，顺序由队列的 shuffle 负责
    MusicLoopMode.shuffle => PlaybackLoop.all,
  };

  // ------------------------------------------------------------------ 状态回写

  /// 把内核状态翻译回旧的 Rx 字段 + 通知栏 + 歌词 + 进度监听。
  ///
  /// 这是整个适配层唯一的写入口：内核怎么变，这里都只做「投影」，
  /// 不反过来改内核状态，所以不会出现两边打架。
  void _syncToOwner() {
    if (_owner.isClosed) return;
    final state = _core.state;
    _owner.isPlaying.value = state.isPlaying;
    _owner.position.value = _core.position;

    final total = _core.duration;
    if (total > Duration.zero) _owner.duration.value = total;

    final track = state.trackOrNull;
    if (track != null) {
      final index = _owner.playlist.indexWhere((e) => idOf(e) == track.id);
      if (index >= 0 && index != _owner.currentIndex.value) {
        _owner.currentIndex.value = index;
        _owner._invalidateMediaItemCache();
        _owner._syncMediaItem(index);
        // 切歌后补拉详情：旁挂 .lrc 才会被读到（旧实现漏了这一步）
        unawaited(_owner._refreshDetailForIndex(index));
      }
    }

    _owner._syncHandlerPlaybackState();
    _owner._notifyProgress();
  }

  Future<void> dispose() async {
    _core.removeListener(_syncToOwner);
    _core.dispose();
  }
}
