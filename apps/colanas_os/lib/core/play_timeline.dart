/// 播放进度条的几个时间口径。
///
/// 转码播放走的是 EVENT 播放列表，`<video>.duration` 只等于**已经转出来的那一段**，
/// 而且 hls.js 每次刷新播放列表还会让它短暂归零。如果拿它当总长，进度条就会在
/// 「已转出长度」和「整片长度」之间反复横跳（实测《匹诺曹》：1:40 ↔ 1:57:45）。
///
/// 所以几件事分开：
///   - **显示的总长**用片源时长（库里就有，恒定）；
///   - **已加载到哪儿**（进度条粗的那一段）用「播放器报的值 / 服务端回报的已转出长度」；
///   - **能不能直接 seek** 看目标是否落在已加载区间里，落在外面就另起一个从中途起转的会话。
///
/// 会话可以从片源中途起转（`startedMs` > 0），此时播放器时间轴 0 不等于片头，
/// 所以对外显示一律要加 [startedMs] 偏移。
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

/// 能直接 seek 的上限（**不建新会话**的那种）。
///
/// - 直链播放：整片都能跳，等于 [timelineDuration]；
/// - 转码播放：只能跳到**已经转出来的位置**。超出的部分要另起一个从中途起转的
///   会话（见 [seekNeedsJump]），不然 hls.js 拿不到分片只会干转圈。
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

/// 已加载（已转出）到的**片源绝对位置**（毫秒）。
///
/// 两个来源取大的那个：
///   - `serverMs`：会话详情回报的 `transcodedMs`（已经是绝对位置，含起转偏移）；
///   - `startMs + playerMs`：播放器报的 HLS 时长 —— 会话是整片一次转完时
///     （`leadMs = 0`）服务端不给 `transcodedMs`，只能靠它。
int loadedEndMs({
  required int startMs,
  required int playerMs,
  required int serverMs,
}) {
  final byPlayer = startMs + (playerMs > 0 ? playerMs : 0);
  final byServer = serverMs > 0 ? serverMs : 0;
  return byServer > byPlayer ? byServer : byPlayer;
}

/// 目标位置是否需要「另起一个中途起转的会话」。
///
/// 需要的情况只有两种：
///   - 目标在会话起点之前（时间轴没有负数，往回跳只能重建）；
///   - 目标超出已加载区间（顺序转码还没转到这里）。
///
/// [toleranceMs] 给一点余量：拖到已加载末尾那一两像素不该反复重建会话。
bool seekNeedsJump({
  required Duration target,
  required Duration start,
  required Duration loadedEnd,
  int toleranceMs = 800,
}) {
  if (target < start) return true;
  return target.inMilliseconds >
      loadedEnd.inMilliseconds + (toleranceMs > 0 ? toleranceMs : 0);
}
