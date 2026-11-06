import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:nas_core/nas_core.dart';

import '../../core/session.dart';

/// AI 新闻的页内播放器。
///
/// 为什么不复用 `MusicPlaybackService`：那个服务的队列是 `MusicTrack`，
/// 播放地址走 `/api/v1/music/stream`（按曲库 id 取文件）。播客的 mp3 在数据目录里，
/// 是另一套路由；硬塞进音乐队列要伪造曲目、还会把用户的歌单冲掉。
/// 这里用一个**独立的 media_kit Player**，只在本页存活：离开博客就停。
///
/// 进度的 `position / duration` 由 media_kit 的流持续推，UI 直接监听本类的 notifyListeners。
class BlogPlayer extends ChangeNotifier {
  Player? _player;
  final List<StreamSubscription<Object?>> _subs = [];

  List<BlogEpisodeItem> _queue = const [];
  int _index = -1;

  Duration position = Duration.zero;
  Duration duration = Duration.zero;
  bool playing = false;
  bool loading = false;
  String? error;

  BlogEpisodeItem? get episode =>
      _index >= 0 && _index < _queue.length ? _queue[_index] : null;

  String? get episodeId => episode?.id;

  bool isCurrent(String id) => episode?.id == id;

  Player _ensure() {
    final existing = _player;
    if (existing != null) return existing;
    final p = Player();
    _subs.add(p.stream.position.listen((v) {
      position = v;
      notifyListeners();
    }));
    _subs.add(p.stream.duration.listen((v) {
      duration = v;
      notifyListeners();
    }));
    _subs.add(p.stream.playing.listen((v) {
      playing = v;
      notifyListeners();
    }));
    _subs.add(p.stream.completed.listen((done) {
      if (done) unawaited(next());
    }));
    _subs.add(p.stream.error.listen((message) {
      error = message;
      loading = false;
      notifyListeners();
    }));
    _player = p;
    return p;
  }

  /// 播放某一期。`queue` 用来支持上一期 / 下一期。
  Future<void> play(BlogEpisodeItem target, List<BlogEpisodeItem> queue) async {
    final playable = queue.where((e) => e.status == 'done').toList(growable: false);
    if (playable.isEmpty) return;
    _queue = playable;
    _index = playable.indexWhere((e) => e.id == target.id).clamp(0, playable.length - 1);
    await _load();
  }

  Future<void> _load() async {
    final current = episode;
    if (current == null) return;
    error = null;
    loading = true;
    position = Duration.zero;
    duration = Duration(seconds: current.durationSec.round());
    notifyListeners();
    try {
      final res = await ApiSession.instance.client.blogAudioUrl(id: current.id);
      final url = '${ApiSession.instance.baseUrl}${res.url}';
      await _ensure().open(Media(url), play: true);
      loading = false;
      notifyListeners();
    } catch (e) {
      error = '$e';
      loading = false;
      notifyListeners();
    }
  }

  Future<void> toggle() async {
    final p = _player;
    if (p == null) {
      final current = episode;
      if (current != null) await play(current, _queue);
      return;
    }
    await p.playOrPause();
  }

  Future<void> seek(Duration to) async {
    await _player?.seek(to);
  }

  Future<void> next() async {
    if (_queue.isEmpty) return;
    _index = (_index + 1) % _queue.length;
    await _load();
  }

  Future<void> prev() async {
    if (_queue.isEmpty) return;
    _index = (_index - 1 + _queue.length) % _queue.length;
    await _load();
  }

  Future<void> stop() async {
    await _player?.stop();
    playing = false;
    notifyListeners();
  }

  @override
  void dispose() {
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    _subs.clear();
    unawaited(_player?.dispose());
    _player = null;
    super.dispose();
  }
}
