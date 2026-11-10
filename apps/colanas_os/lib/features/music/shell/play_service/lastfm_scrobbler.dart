import 'dart:async';

import 'package:flutter/foundation.dart';

import '../compat/getx.dart';
import '../detail/service/music_detail_api_service.dart';
import '../list/models/cola_list_models.dart';
import 'controller/cola_player_controller.dart';

/// Last.fm 播放上报（Scrobble）。
///
/// 阈值按 Last.fm 官方口径：**播放满 30 秒**且**超过总时长的一半**才算一次有效播放。
/// 判断放在客户端，服务端只负责签名转发 —— 换客户端不用重新调服务端逻辑。
///
/// 只在音乐壳存活期间挂钩（`MusicShellView` 创建 / 销毁），离开音乐模块就不再
/// 频繁读 position，也不影响别的模块。
///
/// ⚠️ 没绑定账号时服务端会回 `not_linked`，这里静默忽略：不能因为用户没绑
/// Last.fm 就在每首歌上打一串失败日志。
class LastfmScrobbler {
  LastfmScrobbler(this._player) {
    _bind();
  }

  /// 30 秒是 Last.fm 的硬性下限，低于这个数的播放不计入
  static const int minSeconds = 30;

  final MusicPlayServiceController _player;
  Worker? _positionWorker;
  Worker? _indexWorker;

  /// 当前曲目的唯一键（id 优先，退化为路径）
  String _currentKey = '';
  DateTime? _startedAt;
  bool _sent = false;
  bool _busy = false;

  void _bind() {
    _positionWorker = ever<Duration>(_player.position, (_) => _tick());
    _indexWorker = ever<int>(_player.currentIndex, (_) => _onTrackChanged());
  }

  void dispose() {
    _positionWorker?.dispose();
    _indexWorker?.dispose();
    _positionWorker = null;
    _indexWorker = null;
  }

  MusicListItem? get _current {
    final index = _player.currentIndex.value;
    if (index < 0 || index >= _player.playlist.length) return null;
    return _player.playlist[index];
  }

  String _keyOf(MusicListItem item) =>
      item.id > 0 ? 'id:${item.id}' : 'p:${item.fullPath}';

  void _onTrackChanged() {
    final item = _current;
    if (item == null) {
      _currentKey = '';
      _startedAt = null;
      _sent = false;
      return;
    }
    final key = _keyOf(item);
    if (key == _currentKey) return;
    _currentKey = key;
    _startedAt = DateTime.now();
    _sent = false;
  }

  void _tick() {
    if (_busy || _sent) return;
    final item = _current;
    if (item == null) return;
    if (_currentKey != _keyOf(item)) _onTrackChanged();

    final position = _player.position.value;
    final served = _player.duration.value;
    // 时长优先用播放器回报的（更准），没有就用标签里的
    final totalSeconds = served.inSeconds > 0
        ? served.inSeconds
        : item.duration;
    if (position.inSeconds < minSeconds) return;
    if (totalSeconds > 0 && position.inSeconds * 2 < totalSeconds) return;

    _sent = true;
    _busy = true;
    unawaited(_report(item).whenComplete(() => _busy = false));
  }

  Future<void> _report(MusicListItem item) async {
    final artist = item.artist.trim();
    final track = item.title.trim().isNotEmpty
        ? item.title.trim()
        : item.displayTitle.trim();
    if (artist.isEmpty || track.isEmpty) return;
    final startedAt =
        _startedAt ?? DateTime.now().subtract(_player.position.value);
    try {
      await MusicDetailApiService.instance.scrobble(
        artist: artist,
        track: track,
        album: item.album.trim().isEmpty ? null : item.album.trim(),
        timestamp: startedAt.millisecondsSinceEpoch ~/ 1000,
        durationSec: item.duration > 0 ? item.duration : null,
      );
    } catch (e) {
      // 联网失败不上抛：听歌不该被上报失败打断
      debugPrint('[music] scrobble failed: $e');
    }
  }
}
