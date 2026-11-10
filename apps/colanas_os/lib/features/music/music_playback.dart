import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:nas_core/nas_core.dart';

import '../../core/audio_background.dart';
import '../../core/audio_focus.dart';
import '../../core/session.dart';
import '../../core/settings_store.dart';
import 'equalizer.dart';
import 'music_cache.dart';
import 'lyrics_sync.dart';
import 'media_session.dart';

/// 播放模式。值用字符串落盘（'off' / 'all' / 'one'），读坏时回落到不循环 ——
/// 不能因为一个脏设置就变成"永远单曲循环"。
enum MusicRepeatMode { off, all, one }

MusicRepeatMode musicRepeatModeOf(String? raw) => switch (raw) {
  'all' => MusicRepeatMode.all,
  'one' => MusicRepeatMode.one,
  _ => MusicRepeatMode.off,
};

String musicRepeatModeId(MusicRepeatMode mode) => switch (mode) {
  MusicRepeatMode.all => 'all',
  MusicRepeatMode.one => 'one',
  MusicRepeatMode.off => 'off',
};

/// 常驻音乐播放服务（SP3-04 二期）。
///
/// 与页面生命周期解耦：离开播放页、切换模块、最小化窗口都不会停止播放；
/// Web 端同时把曲目写进浏览器 Media Session（系统媒体面板 / 媒体键可用）。
/// 桌面端的均衡器通过 libmpv 的 `af` 属性生效，Web 端自动跳过。
class MusicPlaybackService extends ChangeNotifier {
  MusicPlaybackService._();

  static final MusicPlaybackService instance = MusicPlaybackService._();

  static const equalizerKey = 'music.equalizer';
  static const repeatKey = 'music.repeat';
  static const shuffleKey = 'music.shuffle';

  Player? _player;
  final List<StreamSubscription<Object?>> _subs = [];

  List<MusicTrack> queue = const [];
  int index = -1;
  Duration position = Duration.zero;
  Duration duration = Duration.zero;
  bool playing = false;
  String? error;
  MusicLyricsResponse? lyrics;
  bool lyricsLoading = false;
  String equalizerPreset = 'off';

  /// 播放模式：不循环 / 列表循环 / 单曲循环。持久化到本地设置。
  MusicRepeatMode repeatMode = MusicRepeatMode.off;

  /// 随机播放：与 repeatMode 正交（随机 + 单曲循环 = 一直放同一首，语义由 UI 提示）
  bool shuffle = false;

  List<int?> _times = const [];
  int _seq = 0;

  MusicTrack? get track =>
      index >= 0 && index < queue.length ? queue[index] : null;

  bool get hasTrack => track != null;

  bool get bilingual =>
      lyrics?.lines.any((l) => (l.translation ?? '').isNotEmpty) ?? false;

  /// 跟播高亮行；无同步歌词返回 -1
  int get activeLine {
    if (!(lyrics?.synced ?? false) || _times.isEmpty) return -1;
    return activeLyricIndex(_times, position.inMilliseconds);
  }

  String get _baseUrl => ApiSession.instance.baseUrl;

  Player get player => _player ??= _createPlayer();

  Player _createPlayer() {
    equalizerPreset =
        equalizerPresetOf(SettingsStore.instance.getString(equalizerKey))?.id ??
        'off';
    repeatMode = musicRepeatModeOf(SettingsStore.instance.getString(repeatKey));
    shuffle = SettingsStore.instance.getBool(shuffleKey) ?? false;
    final p = Player();
    _subs.add(
      p.stream.position.listen((value) {
        position = value;
        // 原生 Android 的锁屏进度：内部按 900ms 节流，不会每 100ms 重绘通知
        if (!kIsWeb && AudioFocus.instance.holds(this)) _syncMediaSession();
        notifyListeners();
      }),
    );
    _subs.add(
      p.stream.duration.listen((value) {
        duration = value;
        notifyListeners();
      }),
    );
    _subs.add(
      p.stream.playing.listen((value) {
        playing = value;
        _syncMediaSession();
        notifyListeners();
      }),
    );
    _subs.add(
      p.stream.completed.listen((done) {
        if (done) _onCompleted();
      }),
    );
    _subs.add(
      p.stream.error.listen((message) {
        error = message;
        notifyListeners();
      }),
    );
    return p;
  }

  /// 播放一个队列（从 [startIndex] 开始）
  void playQueue(List<MusicTrack> tracks, int startIndex) {
    if (tracks.isEmpty) return;
    // 队列要能被"插入下一首 / 移出 / 拖动排序"改，不能是 unmodifiable
    queue = List<MusicTrack>.from(tracks);
    _load(startIndex.clamp(0, tracks.length - 1));
  }

  bool get hasQueue => queue.isNotEmpty;

  /// 下一首播放（插到当前曲目后面）
  void enqueueNext(MusicTrack t) {
    if (queue.isEmpty) {
      playQueue([t], 0);
      return;
    }
    queue = List<MusicTrack>.from(queue)..insert(index + 1, t);
    notifyListeners();
  }

  /// 加入队列末尾
  void enqueue(MusicTrack t) {
    if (queue.isEmpty) {
      playQueue([t], 0);
      return;
    }
    queue = [...queue, t];
    notifyListeners();
  }

  /// 从队列移除某一首（移除正在播的那首就顺位播下一首）
  void removeAt(int i) {
    if (i < 0 || i >= queue.length) return;
    if (queue.length == 1) {
      clearQueue();
      return;
    }
    final next = List<MusicTrack>.from(queue)..removeAt(i);
    if (i < index) {
      index -= 1;
      queue = next;
      notifyListeners();
      return;
    }
    if (i == index) {
      queue = next;
      _load(index.clamp(0, next.length - 1));
      return;
    }
    queue = next;
    notifyListeners();
  }

  /// 拖动排序。`to` 是**移除之后**的插入位置（ReorderableListView.onReorderItem 语义）
  void moveTo(int from, int to) {
    if (from < 0 || from >= queue.length) return;
    if (from == to) return;
    final next = List<MusicTrack>.from(queue);
    final item = next.removeAt(from);
    next.insert(to.clamp(0, next.length), item);
    // 正在播的那首位置变了，但内容没变：只调 index，不重新加载
    final current = track;
    queue = next;
    if (current != null) {
      final at = next.indexWhere((t) => t.id == current.id);
      if (at >= 0) index = at;
    }
    notifyListeners();
  }

  void jumpTo(int i) {
    if (i < 0 || i >= queue.length) return;
    _load(i);
  }

  void clearQueue() {
    _seq += 1;
    queue = const [];
    index = -1;
    position = Duration.zero;
    duration = Duration.zero;
    playing = false;
    lyrics = null;
    _times = const [];
    player.stop();
    AudioFocus.instance.release(this);
    // 队列清空 = 这一路彻底不播了，通知栏 / 锁屏面板跟着收掉
    audioBackground.clear(this);
    notifyListeners();
  }

  Future<void> _load(int next) async {
    if (queue.isEmpty) return;
    // 开播前先让播客 / 音色试听让路：一路声音都不要叠着放
    await AudioFocus.instance.request(this, () async => pause());
    final seq = ++_seq;
    index = next.clamp(0, queue.length - 1);
    final current = queue[index];
    position = Duration.zero;
    duration = Duration(milliseconds: current.durationMs ?? 0);
    playing = false;
    error = null;
    lyrics = null;
    lyricsLoading = true;
    _times = const [];
    notifyListeners();

    // 播放历史：失败不影响播放（自动歌单依赖这份记录）
    unawaited(
      ApiSession.instance.client
          .musicPlay(body: MusicTrackRefBody(id: current.id))
          .then<void>((_) {})
          .catchError((_) {}),
    );

    try {
      // 已离线缓存的直接放本地文件：省一次令牌签发 + 断网也能播
      await MusicCache.instance.ensureIndexed();
      final cached = MusicCache.instance.pathOf(current.id);
      if (cached != null) {
        if (seq != _seq) return;
        await player.open(Media(cached), play: true);
        if (seq != _seq) return;
        _applyEqualizer();
        _syncMediaSession();
        await _loadLyrics(seq, current.id);
        return;
      }
      final res = await ApiSession.instance.client.musicStreamUrl(
        id: current.id,
        format: kIsWeb ? 'auto' : null,
      );
      if (seq != _seq) return;
      await player.open(Media('$_baseUrl${res.url}'), play: true);
      if (seq != _seq) return;
      _applyEqualizer();
      _syncMediaSession();
    } catch (e) {
      if (seq != _seq) return;
      error = I18n.instance.tr('ui.music.040', {'error': e});
      notifyListeners();
    }
    await _loadLyrics(seq, current.id);
  }

  Future<void> _loadLyrics(int seq, String trackId) async {
    try {
      final data = await ApiSession.instance.client.musicLyrics(
        id: trackId,
        lang: I18n.instance.locale,
      );
      if (seq != _seq) return;
      lyrics = data;
      _times = data.lines.map((l) => l.timeMs).toList(growable: false);
      lyricsLoading = false;
      notifyListeners();
    } catch (_) {
      if (seq != _seq) return;
      lyrics = null;
      _times = const [];
      lyricsLoading = false;
      notifyListeners();
    }
  }

  /// 把当前（或指定）曲目下载到本地缓存
  Future<String> cacheTrack(MusicTrack track) async {
    final res = await ApiSession.instance.client.musicStreamUrl(
      id: track.id,
      format: kIsWeb ? 'auto' : null,
    );
    final ext = track.path.contains('.') ? track.path.split('.').last : 'bin';
    final token = ApiSession.instance.token;
    final path = await MusicCache.instance.download(
      trackId: track.id,
      url: '$_baseUrl${res.url}',
      headers: token == null ? const {} : {'authorization': 'Bearer $token'},
      ext: ext,
    );
    notifyListeners();
    return path;
  }

  bool isCached(String trackId) => MusicCache.instance.has(trackId);

  /// 一首放完：按播放模式决定下一首。
  ///
  /// - 单曲循环：回到开头继续，**不看队列长度**（此前只有一首时会 pause，与"单曲循环"相反）；
  /// - 随机：队列里另挑一首（不是顺序 +1）；
  /// - 列表循环：顺序推进并回绕；
  /// - 不循环：最后一首放完就停（不回绕）。
  void _onCompleted() {
    if (queue.isEmpty) return;
    if (repeatMode == MusicRepeatMode.one) {
      player.seek(Duration.zero);
      player.play();
      return;
    }
    if (shuffle && queue.length > 1) {
      _load(_randomOtherIndex());
      return;
    }
    if (index >= queue.length - 1 && repeatMode == MusicRepeatMode.off) {
      player.pause();
      player.seek(Duration.zero);
      return;
    }
    _load((index + 1) % queue.length);
  }

  int _randomOtherIndex() {
    if (queue.length <= 1) return index;
    final rnd = math.Random();
    var next = index;
    // 只有两首时随机必然命中另一首，循环一次即可，不会死循环
    while (next == index) {
      next = rnd.nextInt(queue.length);
    }
    return next;
  }

  /// 切随机播放（持久化）
  Future<void> setShuffle(bool value) async {
    shuffle = value;
    notifyListeners();
    await SettingsStore.instance.setBool(shuffleKey, value);
  }

  /// 循环切换：不循环 → 列表循环 → 单曲循环 → 不循环
  Future<void> cycleRepeatMode() async {
    repeatMode = switch (repeatMode) {
      MusicRepeatMode.off => MusicRepeatMode.all,
      MusicRepeatMode.all => MusicRepeatMode.one,
      MusicRepeatMode.one => MusicRepeatMode.off,
    };
    notifyListeners();
    await SettingsStore.instance.setString(repeatKey, musicRepeatModeId(repeatMode));
  }

  void next() {
    if (queue.isEmpty) return;
    if (shuffle && queue.length > 1) {
      _load(_randomOtherIndex());
      return;
    }
    _load((index + 1) % queue.length);
  }

  void previous() {
    if (queue.isEmpty) return;
    _load((index - 1 + queue.length) % queue.length);
  }

  void toggle() {
    if (playing) {
      player.pause();
    } else {
      unawaited(_playWithFocus());
    }
  }

  void play() => unawaited(_playWithFocus());

  /// 从暂停恢复 / 系统媒体键点「播放」也算开播，先把别路音源停掉。
  Future<void> _playWithFocus() async {
    await AudioFocus.instance.request(this, () async => pause());
    await player.play();
  }

  void pause() => player.pause();

  void seek(Duration target) => player.seek(target);

  /// 切换均衡器预设并持久化（桌面端立即生效）
  Future<void> setEqualizer(String id) async {
    final preset = equalizerPresetOf(id);
    if (preset == null || preset.id == equalizerPreset) return;
    equalizerPreset = preset.id;
    _applyEqualizer();
    notifyListeners();
    await SettingsStore.instance.setString(equalizerKey, preset.id);
  }

  void _applyEqualizer() {
    if (kIsWeb) return;
    final af = audioFilterForEqualizer(equalizerPreset);
    final platform = _player?.platform;
    if (platform == null) return;
    try {
      // 只有 native（libmpv）后端有 setProperty；Web 端已在上面跳过
      final pending = (platform as dynamic).setProperty('af', af) as Future<void>;
      unawaited(pending.catchError((_) {}));
    } catch (_) {
      // 个别平台没有 af 属性时保持原样
    }
  }

  void _syncMediaSession() {
    final current = track;
    // 系统媒体面板全局只有一份：暂停方不能把播客的锁屏控制抢过来
    if (current == null || !AudioFocus.instance.holds(this)) return;
    if (!kIsWeb) {
      // 原生 Android：前台服务 + 通知栏 / 锁屏控制（Web 端由浏览器自己接管）
      audioBackground.update(
        AudioSnapshot(
          owner: this,
          id: current.id,
          title: current.title,
          artist: current.artist,
          album: current.album,
          playing: playing,
          position: position,
          duration: duration,
          onPlay: play,
          onPause: pause,
          onNext: next,
          onPrevious: previous,
          onSeek: (to) => seek(to),
          onStop: () => clearQueue(),
        ),
      );
      return;
    }
    updateMediaSession(
      title: current.title,
      artist: current.artist,
      album: current.album,
      playing: playing,
      onPlay: play,
      onPause: pause,
      onNext: next,
      onPrevious: previous,
    );
  }
}
