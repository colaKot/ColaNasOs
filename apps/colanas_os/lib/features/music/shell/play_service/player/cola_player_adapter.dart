import 'package:flutter/foundation.dart';

/// 一次播放所需的地址信息。
///
/// [url] 始终保留，用作本地文件不可用时的回退；[filePath] 存在时播放器优先读本地。
class MusicPlaySource {
  const MusicPlaySource({this.filePath, required this.url, this.fileExt = ''});

  /// 纯网络源。
  const MusicPlaySource.stream(String address, {String extension = ''})
    : filePath = null,
      url = address,
      fileExt = extension;

  /// 已缓存到本地的源，仍附带网络地址作为兜底。
  const MusicPlaySource.cached(
    String path, {
    required String address,
    String extension = '',
  }) : filePath = path,
       url = address,
       fileExt = extension;

  final String url;
  final String? filePath;
  final String fileExt;

  bool get isLocal => (filePath ?? '').trim().isNotEmpty;

  bool get isRemoteOnly => !isLocal;

  /// 不带前导点的扩展名，供 MIME 推断使用。
  String get extension {
    final raw = fileExt.trim().toLowerCase();
    return raw.startsWith('.') ? raw.substring(1) : raw;
  }

  MusicPlaySource copyWith({String? filePath, String? url, String? fileExt}) =>
      MusicPlaySource(
        filePath: filePath ?? this.filePath,
        url: url ?? this.url,
        fileExt: fileExt ?? this.fileExt,
      );

  @override
  String toString() =>
      'MusicPlaySource(${isLocal ? 'local=$filePath' : 'remote'}, url=$url)';
}

/// 播放器适配层约定。
///
/// 具体播放器（media_kit / just_audio 等）实现这组能力，控制器只依赖本接口，
/// 因此切换内核时不需要改动播放列表、进度同步与通知栏逻辑。
abstract interface class MusicPlayerAdapter {
  /// 资源装载与销毁。
  Future<void> initialize();
  Future<void> dispose();

  /// 传输控制。
  Future<void> play();
  Future<void> pause();
  Future<void> seekTo(Duration position);
  Future<void> setVolume(double value);
  Future<void> setLooping(bool looping);

  /// 状态变更订阅。
  void addListener(VoidCallback listener);
  void removeListener(VoidCallback listener);

  /// 播放状态快照。
  Duration get position;
  bool get isPlaying;
  bool get isInitialized;
  bool get isCompleted;
  bool get isBuffering;
  bool get hasError;
  Duration get duration;
  Duration get buffered;
}
