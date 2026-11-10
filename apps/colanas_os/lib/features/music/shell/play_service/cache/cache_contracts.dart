/// 音乐音频缓存的共享契约。
///
/// Web 与原生实现都需要同一组配置、进度与统计类型；原先两套实现各自复制了一份，
/// 这里收拢成单一来源。调用方只需要 import `cola_audio_cache.dart`。
library;

/// 缓存开关与容量上限。
class MusicAudioCacheOptions {
  const MusicAudioCacheOptions({required this.enabled, required this.maxItems});

  /// 关闭后所有请求直接走网络，不落盘。
  final bool enabled;

  /// 已完成条目的保留数量；<= 0 表示不淘汰。
  final int maxItems;

  static const MusicAudioCacheOptions unlimitedDisabled =
      MusicAudioCacheOptions(enabled: false, maxItems: 0);

  bool get isCapacityBounded => maxItems > 0;

  MusicAudioCacheOptions withEnabled(bool value) =>
      MusicAudioCacheOptions(enabled: value, maxItems: maxItems);

  MusicAudioCacheOptions withMaxItems(int value) =>
      MusicAudioCacheOptions(enabled: enabled, maxItems: value);

  MusicAudioCacheOptions copyWith({bool? enabled, int? maxItems}) =>
      MusicAudioCacheOptions(
        enabled: enabled ?? this.enabled,
        maxItems: maxItems ?? this.maxItems,
      );
}

/// 单次下载的字节进度。`totalBytes` 为 0 表示服务端没给长度。
class MusicAudioCacheProgress {
  const MusicAudioCacheProgress({
    required this.receivedBytes,
    required this.totalBytes,
    this.finished = false,
  });

  final int receivedBytes;
  final int totalBytes;
  final bool finished;

  /// 归一化到 [0, 1]，长度未知或数值异常时返回 0。
  double get progress {
    if (totalBytes <= 0) return 0;
    final ratio = receivedBytes / totalBytes;
    if (ratio.isNaN || ratio.isInfinite) return 0;
    return ratio.clamp(0.0, 1.0).toDouble();
  }

  MusicAudioCacheProgress withFinished() => MusicAudioCacheProgress(
    receivedBytes: receivedBytes,
    totalBytes: totalBytes,
    finished: true,
  );
}

typedef MusicAudioCacheProgressCallback = void Function(
  MusicAudioCacheProgress progress,
);

/// 主动取消下载时抛出，区别于网络失败。
class MusicAudioCacheCanceled implements Exception {
  const MusicAudioCacheCanceled([this.reason = 'canceled']);

  final String reason;

  @override
  String toString() => 'MusicAudioCacheCanceled($reason)';
}

/// 缓存占用统计。
class MusicAudioCacheStats {
  const MusicAudioCacheStats({required this.count, required this.totalBytes});

  static const MusicAudioCacheStats empty = MusicAudioCacheStats(
    count: 0,
    totalBytes: 0,
  );

  final int count;
  final int totalBytes;

  bool get isEmpty => count == 0;
}

/// 一次「准备播放源」请求的输入集合。
///
/// [prepareSource] 与 [prepareController] 的判定逻辑完全一致，用同一个参数对象
/// 避免两份实现各自维护一串 required 命名参数。
class CacheSourceRequest {
  const CacheSourceRequest({
    required this.fileHash,
    required this.fileExt,
    required this.fileSize,
    required this.buildUrl,
    required this.refreshAuthToken,
    required this.onProgress,
  });

  final String fileHash;
  final String fileExt;
  final int fileSize;
  final Future<String> Function() buildUrl;
  final Future<bool> Function() refreshAuthToken;
  final MusicAudioCacheProgressCallback onProgress;

  String get normalizedHash => fileHash.trim();

  /// 统一去掉前导点、转小写；空扩展名用 `dat` 兜底。
  String get normalizedExt {
    final raw = fileExt.trim().toLowerCase();
    if (raw.isEmpty) return 'dat';
    return raw.startsWith('.') ? raw.substring(1) : raw;
  }

  int get sizeHint => fileSize > 0 ? fileSize : 0;
}

/// 一次准备动作的结果：命中本地文件就直接播，否则播网络并后台补缓存。
class CacheArtifact {
  const CacheArtifact._({
    required this.localPath,
    required this.extension,
    required this.downloadStarted,
  });

  factory CacheArtifact.remote(String extension) => CacheArtifact._(
    localPath: null,
    extension: extension,
    downloadStarted: false,
  );

  factory CacheArtifact.local(String path, String extension) => CacheArtifact._(
    localPath: path,
    extension: extension,
    downloadStarted: false,
  );

  factory CacheArtifact.pending(String extension) => CacheArtifact._(
    localPath: null,
    extension: extension,
    downloadStarted: true,
  );

  final String? localPath;
  final String extension;
  final bool downloadStarted;

  bool get hasLocalFile => localPath != null;
}
