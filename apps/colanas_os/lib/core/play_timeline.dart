/// 播放进度条的两个时间口径。
///
/// 转码播放走的是 EVENT 播放列表，`<video>.duration` 只等于**已经转出来的那一段**，
/// 而且 hls.js 每次刷新播放列表还会让它短暂归零。如果拿它当总长，进度条就会在
/// 「已转出长度」和「整片长度」之间反复横跳（实测《匹诺曹》：1:40 ↔ 1:57:45）。
///
/// 所以两件事分开：
///   - **显示的总长**用片源时长（库里就有，恒定）；
///   - **能跳到哪儿**才用播放器报的值（转码没跑到的地方没有分片）。
library;

/// 进度条右端显示的总时长。
///
/// 片源时长优先；只有它拿不到（未知片源 / 时长为 0）时才用播放器报的值，
/// 两个都没有就给 0（界面显示 `--:--`）。
Duration timelineDuration({
  required Duration reported,
  required Duration source,
}) {
  if (source > Duration.zero) return source;
  return reported > Duration.zero ? reported : Duration.zero;
}

/// 能跳到的上限。
///
/// - 直链播放：整片都能跳，等于 [timelineDuration]；
/// - 转码播放：只能跳到**已经转出来的位置**，再往后 hls.js 拿不到分片会一直转圈。
///   播放器还没报出有效值时（刚起播）退回整片长度，别把进度条锁死在 0。
Duration seekLimit({
  required Duration reported,
  required Duration source,
  required bool isTranscode,
}) {
  final full = timelineDuration(reported: reported, source: source);
  if (!isTranscode) return full;
  if (reported <= Duration.zero) return full;
  return reported < full ? reported : full;
}

/// 进度条上「已转出」刻度的位置（0..1）；不需要画时返回 null。
///
/// 分段续转时右端仍显示整片时长，但可拖范围只到已转出位置，
/// 不画个标记用户会以为「拖不到头」是坏了。整片转完 / 直链播放都不画。
double? leadMarker({
  required bool isTranscode,
  required int transcodedMs,
  required Duration total,
}) {
  if (!isTranscode || transcodedMs <= 0) return null;
  final full = total.inMilliseconds;
  if (full <= 0 || transcodedMs >= full - 1000) return null;
  return (transcodedMs / full).clamp(0.0, 1.0);
}
