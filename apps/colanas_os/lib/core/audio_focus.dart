import 'dart:async';

/// 全局音频焦点：同一时刻只允许一路声音。
///
/// 音乐、播客、音色试听各持有独立的 media_kit Player，以前各播各的 ——
/// 开音乐时播客还在响；热重载留下旧 Player 甚至会出现同一期放两遍。
/// 任何一路「真正开始播」之前先 [request]，仲裁器负责把上一路暂停。
class AudioFocus {
  AudioFocus._();

  static final AudioFocus instance = AudioFocus._();

  Object? _holder;
  Future<void> Function()? _pause;

  /// [owner] 传播放器实例本身（按 identity 比较），[pauseSelf] 只暂停、不销毁资源。
  Future<void> request(Object owner, Future<void> Function() pauseSelf) async {
    final prev = _holder;
    if (prev != null && !identical(prev, owner)) {
      final pause = _pause;
      _holder = null;
      _pause = null;
      if (pause != null) {
        try {
          await pause();
        } catch (_) {
          // 上一路已销毁 / 报错：不能挡住新的播放
        }
      }
    }
    _holder = owner;
    _pause = pauseSelf;
  }

  /// 是否由 [owner] 持有焦点。系统媒体面板只有一个，暂停的那路不能去覆盖它。
  bool holds(Object owner) => identical(_holder, owner);

  /// 播放器彻底停止时交还焦点，避免下一路被一个已停的 holder 误判。
  void release(Object owner) {
    if (identical(_holder, owner)) {
      _holder = null;
      _pause = null;
    }
  }
}
