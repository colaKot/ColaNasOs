/// 播放队列：不可变序列 + 一个游标。
///
/// 旧实现的队列是 controller 里一个可变的 `RxList` + 一个 `currentIndex`，
/// 任何地方都能 `playlist[i] = xxx`，于是「界面正在渲染的那一版」和
/// 「播放器实际打开的那一首」会短暂不一致 —— 切歌瞬间点全屏、列表刷新
/// 打断播放之类的怪现象都是这么来的。
///
/// 这里做成不可变值：每次变化产生新对象，谁持有旧引用谁就看到旧快照，
/// 状态跳变是原子的。**纯 Dart，可单测**。
library;

import 'track.dart';

class PlaybackQueue {
  const PlaybackQueue._({
    required this.tracks,
    required this.cursor,
    required this.loop,
    this.shuffleOrder,
    this.unshuffled,
  });

  /// 空队列
  factory PlaybackQueue.empty() => const PlaybackQueue._(
    tracks: <Track>[],
    cursor: 0,
    loop: PlaybackLoop.none,
  );

  /// 用一批曲目和起始位置建队列
  factory PlaybackQueue.of(
    List<Track> tracks, {
    int startAt = 0,
    PlaybackLoop loop = PlaybackLoop.none,
  }) => PlaybackQueue._(
    tracks: List<Track>.unmodifiable(tracks),
    cursor: tracks.isEmpty ? 0 : startAt.clamp(0, tracks.length - 1),
    loop: loop,
  );

  /// 当前播放顺序（开随机时是打乱后的顺序）
  final List<Track> tracks;

  /// 指向 [tracks] 的下标
  final int cursor;

  final PlaybackLoop loop;

  /// 随机播放时的原始下标排列；null 表示没开随机
  final List<int>? shuffleOrder;

  /// 开随机之前的原始列表，关掉随机时原样恢复
  final List<Track>? unshuffled;

  bool get isEmpty => tracks.isEmpty;

  bool get isNotEmpty => tracks.isNotEmpty;

  bool get shuffleEnabled => shuffleOrder != null;

  Track? get current =>
      cursor >= 0 && cursor < tracks.length ? tracks[cursor] : null;

  int get length => tracks.length;

  bool get hasPrevious => cursor > 0;

  /// 队列后面还有没有下一首（不含循环语义，循环在 [advance] 里判断）
  bool get hasNext => cursor + 1 < tracks.length;

  PlaybackQueue withLoop(PlaybackLoop mode) => PlaybackQueue._(
    tracks: tracks,
    cursor: cursor,
    loop: mode,
    shuffleOrder: shuffleOrder,
    unshuffled: unshuffled,
  );

  /// 跳到指定下标（越界会被夹到合法范围）
  PlaybackQueue jumpTo(int index) => PlaybackQueue._(
    tracks: tracks,
    cursor: tracks.isEmpty ? 0 : index.clamp(0, tracks.length - 1),
    loop: loop,
    shuffleOrder: shuffleOrder,
    unshuffled: unshuffled,
  );

  /// 往队尾补数据（分页加载下一批时用）。不改变当前游标。
  PlaybackQueue append(List<Track> more) {
    if (more.isEmpty) return this;
    final merged = <Track>[...tracks, ...more];
    return PlaybackQueue._(
      tracks: List<Track>.unmodifiable(merged),
      cursor: cursor,
      loop: loop,
      // 随机模式下追加会破坏既有排列，直接退出随机、用自然顺序续上更可预期
      shuffleOrder: null,
      unshuffled: null,
    );
  }

  /// 整队替换（换歌单 / 换列表 / 换搜索结果）
  PlaybackQueue replaceAll(List<Track> next, {int startAt = 0}) => PlaybackQueue.of(
    next,
    startAt: startAt,
    loop: loop,
  );

  /// 开 / 关随机。
  ///
  /// 打开时把**当前位置之后**的曲目打乱（当前这首留在原位，避免正在听的歌
  /// 被打断）；关闭时回到原始顺序，并让游标仍指向当前这首。
  PlaybackQueue withShuffle(bool enabled) {
    if (enabled == shuffleEnabled) return this;
    if (tracks.isEmpty) return this;

    if (!enabled) {
      final restored = unshuffled ?? tracks;
      final currentTrack = current;
      final index = currentTrack == null
          ? 0
          : restored.indexWhere((t) => t.id == currentTrack.id);
      return PlaybackQueue._(
        tracks: restored,
        cursor: index >= 0 ? index : 0,
        loop: loop,
      );
    }

    final head = tracks.sublist(0, cursor + 1);
    final tail = tracks.sublist(cursor + 1).toList();
    // 固定种子没必要：队列本身不参与快照比对，随机结果每次不同是预期行为
    tail.shuffle();
    final order = <Track>[...head, ...tail];
    return PlaybackQueue._(
      tracks: List<Track>.unmodifiable(order),
      cursor: cursor,
      loop: loop,
      shuffleOrder: List<int>.generate(order.length, (i) => i),
      unshuffled: tracks,
    );
  }

  /// 算「下一首该是谁」。
  ///
  /// 返回新队列 + 语义动作：调用方据此决定「重开一首」还是「seek 回 0 继续」。
  /// 单曲循环不换曲目，只回到起点 —— 旧实现把它和「切歌」混在一起，
  /// 导致每次循环都重建播放器（白付一次加载开销）。
  (PlaybackQueue, QueueAdvance) advance() {
    if (tracks.isEmpty) return (this, QueueAdvance.exhausted);
    if (loop == PlaybackLoop.one) return (this, QueueAdvance.repeatCurrent);
    if (hasNext) return (jumpTo(cursor + 1), QueueAdvance.next);
    // 到队尾：列表循环回第一首，否则停住
    if (loop == PlaybackLoop.all) {
      return (jumpTo(0), QueueAdvance.next);
    }
    return (this, QueueAdvance.exhausted);
  }

  /// 上一首。到队首时停在第一首（不绕到队尾，和常见播放器一致）。
  PlaybackQueue retreat() => hasPrevious ? jumpTo(cursor - 1) : this;

  /// 从队列里移除某一首（删除文件后同步队列用）。
  ///
  /// 游标要跟着挪：删掉当前曲的前一首时，当前曲的下标会前移一位，
  /// 不修正就会「跳过一首」。
  PlaybackQueue removeAt(int index) {
    if (index < 0 || index >= tracks.length) return this;
    final next = <Track>[...tracks]..removeAt(index);
    var nextCursor = cursor;
    if (index < cursor) nextCursor = cursor - 1;
    if (nextCursor >= next.length) nextCursor = next.isEmpty ? 0 : next.length - 1;
    return PlaybackQueue._(
      tracks: List<Track>.unmodifiable(next),
      cursor: nextCursor,
      loop: loop,
      shuffleOrder: null,
      unshuffled: null,
    );
  }
}
