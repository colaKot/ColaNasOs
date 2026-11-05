import 'sync_fs_stub.dart'
    if (dart.library.io) 'sync_fs_io.dart'
    // 用 js_interop 而不是已弃用的 `dart.library.html`：wasm 构建下后者为 false，
    // 会悄悄退回 stub（Electron 文件桥就白搭了）
    if (dart.library.js_interop) 'sync_fs_web.dart';

/// 结构化过滤（与 `src/modules/sync/util.ts#filterExcluded` 同一口径）
class SyncFilterConfig {
  const SyncFilterConfig({
    this.excludeSmallEnabled = false,
    this.excludeSmallSize = 0,
    this.excludeSmallUnit = 'KB',
    this.excludeLargeEnabled = false,
    this.excludeLargeSize = 0,
    this.excludeLargeUnit = 'MB',
    this.excludeHidden = false,
    this.excludeExtensionEnabled = false,
    this.excludeExtensions = const [],
  });

  final bool excludeSmallEnabled;
  final int excludeSmallSize;
  final String excludeSmallUnit;
  final bool excludeLargeEnabled;
  final int excludeLargeSize;
  final String excludeLargeUnit;
  final bool excludeHidden;
  final bool excludeExtensionEnabled;
  final List<String> excludeExtensions;

  SyncFilterConfig copyWith({
    bool? excludeSmallEnabled,
    int? excludeSmallSize,
    String? excludeSmallUnit,
    bool? excludeLargeEnabled,
    int? excludeLargeSize,
    String? excludeLargeUnit,
    bool? excludeHidden,
    bool? excludeExtensionEnabled,
    List<String>? excludeExtensions,
  }) =>
      SyncFilterConfig(
        excludeSmallEnabled: excludeSmallEnabled ?? this.excludeSmallEnabled,
        excludeSmallSize: excludeSmallSize ?? this.excludeSmallSize,
        excludeSmallUnit: excludeSmallUnit ?? this.excludeSmallUnit,
        excludeLargeEnabled: excludeLargeEnabled ?? this.excludeLargeEnabled,
        excludeLargeSize: excludeLargeSize ?? this.excludeLargeSize,
        excludeLargeUnit: excludeLargeUnit ?? this.excludeLargeUnit,
        excludeHidden: excludeHidden ?? this.excludeHidden,
        excludeExtensionEnabled:
            excludeExtensionEnabled ?? this.excludeExtensionEnabled,
        excludeExtensions: excludeExtensions ?? this.excludeExtensions,
      );

  factory SyncFilterConfig.fromJson(Map<String, dynamic>? json) {
    final j = json ?? const <String, dynamic>{};
    String unit(Object? v, String fallback) =>
        v == 'KB' || v == 'MB' || v == 'GB' ? '$v' : fallback;
    return SyncFilterConfig(
      excludeSmallEnabled: j['excludeSmallEnabled'] == true,
      excludeSmallSize: (j['excludeSmallSize'] as num?)?.toInt() ?? 0,
      excludeSmallUnit: unit(j['excludeSmallUnit'], 'KB'),
      excludeLargeEnabled: j['excludeLargeEnabled'] == true,
      excludeLargeSize: (j['excludeLargeSize'] as num?)?.toInt() ?? 0,
      excludeLargeUnit: unit(j['excludeLargeUnit'], 'MB'),
      excludeHidden: j['excludeHidden'] == true,
      excludeExtensionEnabled: j['excludeExtensionEnabled'] == true,
      excludeExtensions: ((j['excludeExtensions'] as List?) ?? const [])
          .map((e) => '$e')
          .where((e) => e.isNotEmpty)
          .toList(),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'excludeSmallEnabled': excludeSmallEnabled,
        'excludeSmallSize': excludeSmallSize,
        'excludeSmallUnit': excludeSmallUnit,
        'excludeLargeEnabled': excludeLargeEnabled,
        'excludeLargeSize': excludeLargeSize,
        'excludeLargeUnit': excludeLargeUnit,
        'excludeHidden': excludeHidden,
        'excludeExtensionEnabled': excludeExtensionEnabled,
        'excludeExtensions': excludeExtensions,
      };
}

const _unitBytes = <String, int>{
  'KB': 1024,
  'MB': 1024 * 1024,
  'GB': 1024 * 1024 * 1024,
};

/// 与 `src/modules/sync/util.ts#filterExcluded` 一致
bool filterExcluded(String relPath, int size, SyncFilterConfig f) {
  final p = relPath.replaceAll('\\', '/');
  if (f.excludeHidden && p.split('/').any((s) => s.startsWith('.'))) {
    return true;
  }
  if (f.excludeExtensionEnabled && f.excludeExtensions.isNotEmpty) {
    final dot = p.lastIndexOf('.');
    final ext = dot >= 0 ? p.substring(dot + 1).toLowerCase() : '';
    if (ext.isNotEmpty &&
        f.excludeExtensions
            .any((e) => e.toLowerCase().replaceFirst(RegExp(r'^\.'), '') == ext)) {
      return true;
    }
  }
  if (f.excludeSmallEnabled && f.excludeSmallSize > 0) {
    if (size < f.excludeSmallSize * (_unitBytes[f.excludeSmallUnit] ?? 1024)) {
      return true;
    }
  }
  if (f.excludeLargeEnabled && f.excludeLargeSize > 0) {
    if (size > f.excludeLargeSize * (_unitBytes[f.excludeLargeUnit] ?? 1024)) {
      return true;
    }
  }
  return false;
}

/// 本地文件系统能力（同步引擎只依赖这个接口）。
///
/// Web 端没有本地目录访问能力，实现为「不可用」：UI 会隐藏创建入口，
/// 引擎在运行前直接返回明确原因，而不是让用户点了才失败。
abstract class SyncFs {
  /// 当前端是否具备本地目录同步能力
  bool get canSync;

  /// 机器级设备标识（同一台机器上主客户端与独立同步端应解析出同一个值）
  Future<String> resolveDeviceId();

  /// 设备显示名（默认用主机名）
  Future<String> resolveDeviceName();

  /// 选择本地目录（桌面 / 移动）；Web 或用户取消返回 null
  Future<String?> pickDirectory();

  /// 递归扫描本地目录（不跟随符号链接），按 include/exclude 过滤
  Future<List<SyncLocalEntry>> scan(
    String root, {
    List<String> include = const [],
    List<String> exclude = const [],
    SyncFilterConfig filter = const SyncFilterConfig(),
  });

  /// 读取本地文件区间（用于分片上传）
  Future<List<int>> readChunk(String path, int start, int end);

  /// 本地文件当前大小（字节）。上传前用它校正 plan 里可能已过期的尺寸。
  Future<int> sizeOf(String path);

  /// 流式下载到本地文件，并在成功后把 mtime 对齐到 [mtimeMs]
  Future<void> download({
    required Uri uri,
    required Map<String, String> headers,
    required String localPath,
    required int mtimeMs,
    required void Function(int received) onProgress,
    required bool Function() cancelled,
  });

  Future<void> deleteLocal(String path);

  Future<bool> exists(String path);
}

class SyncLocalEntry {
  const SyncLocalEntry({
    required this.path,
    required this.size,
    required this.mtimeMs,
  });

  /// 相对本地根目录的 POSIX 路径
  final String path;
  final int size;
  final int mtimeMs;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'path': path,
        'size': size,
        'mtimeMs': mtimeMs,
      };
}

SyncFs createSyncFs() => createPlatformSyncFs();

/// 相对路径归一化（`\` → `/`，去掉首尾斜杠）
String normalizeRel(String value) => value
    .replaceAll('\\', '/')
    .replaceAll(RegExp(r'^/+'), '')
    .replaceAll(RegExp(r'/+$'), '');

/// POSIX 拼接（不引入 path 包，避免在 Web 构建里多一层条件导入）
String joinPosix(List<String> parts) {
  final out = <String>[];
  for (final raw in parts) {
    final p = raw.replaceAll('\\', '/');
    for (final seg in p.split('/')) {
      if (seg.isEmpty || seg == '.') continue;
      out.add(seg);
    }
  }
  return out.join('/');
}

/// include/exclude 匹配：`*` 不跨目录、`**` 跨目录、`?` 单字符，并覆盖其子路径。
///
/// 与 `src/modules/sync/plan.ts#matchPattern` 同一口径；客户端先滤一遍是为了
/// 少传几千条无效条目，服务端仍会再校验一次（两边不一致时以服务端为准）。
bool matchSyncPattern(String relPath, String pattern) {
  final p = normalizeRel(relPath);
  final pat = normalizeRel(pattern);
  if (pat.isEmpty) return false;

  final out = StringBuffer();
  for (var i = 0; i < pat.length; i += 1) {
    final ch = pat[i];
    if (ch == '*') {
      if (i + 1 < pat.length && pat[i + 1] == '*') {
        out.write('.*');
        i += 1;
      } else {
        out.write('[^/]*');
      }
    } else if (ch == '?') {
      out.write('[^/]');
    } else {
      out.write(RegExp.escape(ch));
    }
  }

  try {
    return RegExp('^$out(/.*)?\$').hasMatch(p);
  } catch (_) {
    return false;
  }
}

/// 与 `src/modules/sync/plan.ts#inScope` 一致
bool inSyncScope(String relPath, List<String> include, List<String> exclude) {
  if (exclude.any((x) => matchSyncPattern(relPath, x))) return false;
  if (include.isEmpty) return true;
  return include.any((x) => matchSyncPattern(relPath, x));
}
