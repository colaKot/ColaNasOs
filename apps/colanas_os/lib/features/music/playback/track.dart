/// 播放内核的领域模型（纯 Dart，不 import Flutter，可直接单测）。
///
/// 这一层**不认识** UI 也不认识后端：`Track` 只说「放什么」，
/// `PlaybackQueue` 只说「按什么顺序放」。谁把后端 JSON 变成 `Track`、
/// 谁把封面 URL 画到屏幕上，都是外面的事。
library;

/// 一首待播放的曲目。
///
/// `uri` 是唯一真正交给播放引擎的东西；其余字段都是给界面和通知栏看的。
/// `origin` 保留原始数据（比如列表里的 `MusicListItem`），
/// 需要「打开所在文件夹」「加进歌单」这类业务动作时再向下转型，避免领域层
/// 反过来依赖某个具体页面模型。
class Track {
  const Track({
    required this.id,
    required this.uri,
    required this.title,
    this.artist = '',
    this.album = '',
    this.duration,
    this.coverUrl,
    this.origin,
  });

  /// 稳定标识：同一首歌在队列里只应出现一次。用后端 indexId 或路径都行，
  /// 由构造方保证唯一。
  final String id;

  final Uri uri;
  final String title;
  final String artist;
  final String album;

  /// 已知时长（列表里就带回来的）。null 表示要等引擎报。
  final Duration? duration;

  final String? coverUrl;

  /// 原始业务对象（`MusicListItem` / 搜索结果等），领域层不解读它
  final Object? origin;

  /// 通知栏 / 播放器头部用的一行副标题
  String get subtitle {
    if (artist.isNotEmpty && album.isNotEmpty) return '$artist · $album';
    if (artist.isNotEmpty) return artist;
    return album;
  }

  @override
  String toString() => 'Track($id, $title)';
}

/// 循环模式（引擎层只认这三种；「随机」由队列自己决定下一首是谁）
enum PlaybackLoop {
  /// 顺序播到队尾就停
  none,

  /// 播到队尾回到第一首
  all,

  /// 单曲循环
  one,
}

/// 一次「接下来放什么」的回答。
///
/// 队列本身不知道数据从哪来，翻页由 [QueueSource] 负责补给。
enum QueueAdvance {
  /// 正常前进到下一首
  next,

  /// 已到队尾且不允许循环
  exhausted,

  /// 单曲循环：重播当前这首
  repeatCurrent,
}
