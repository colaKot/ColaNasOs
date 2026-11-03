/// 歌词跟播：纯函数，便于单测（不依赖 Player / Widget）。
///
/// 服务端 `/music/lyrics` 返回的 `lines` 已按 `timeMs` 升序排列；这里只做
/// 「当前播放位置应高亮哪一行」的判定。
library;

/// 返回当前应高亮的歌词行下标。
///
/// 规则：取最后一个 `timeMs <= positionMs` 的行；尚未到第一行、或整首歌词
/// 没有时间戳时返回 `-1`（表示不高亮）。
int activeLyricIndex(List<int?> times, int positionMs) {
  var active = -1;
  for (var i = 0; i < times.length; i++) {
    final t = times[i];
    if (t == null) continue;
    if (t > positionMs) break;
    active = i;
  }
  return active;
}
