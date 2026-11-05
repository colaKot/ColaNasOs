import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'sync_fs.dart';

/// `window.colanasSync` —— Electron 主进程注入的文件能力桥（见 `electron/preload.ts`）。
///
/// 浏览器里没有这个对象，[canSync] 就是 false（照旧隐藏创建入口）；
/// PC 客户端（Electron 外壳）里有，于是同步在桌面上真正可用 —— 之前
/// 「电脑上装客户端却提示 web 端无法创建同步」就是这里缺桥（2026-11-04）。
@JS('colanasSync')
external JSObject? get _syncBridge;

bool get _hasBridge => _syncBridge != null;

Future<Map<String, dynamic>> _invoke(String op, [Map<String, dynamic>? args]) async {
  final bridge = _syncBridge;
  if (bridge == null) throw StateError('sync bridge unavailable');
  final payload = jsonEncode(<String, dynamic>{'op': op, ...?args});
  final promise = bridge.callMethod<JSPromise<JSAny?>>('invoke'.toJS, payload.toJS);
  final raw = await promise.toDart;
  final text = (raw as JSString?)?.toDart ?? '{}';
  final decoded = jsonDecode(text);
  if (decoded is! Map) throw StateError('bad bridge response');
  final map = Map<String, dynamic>.from(decoded);
  if (map['ok'] != true) throw StateError('${map['error'] ?? 'bridge error'}');
  final data = map['data'];
  return data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
}

/// Web / Electron 端同步文件系统。
///
/// 纯浏览器 → 不可用；Electron 外壳 → 走主进程做真实的目录扫描与读写。
class WebSyncFs implements SyncFs {
  const WebSyncFs();

  @override
  bool get canSync => _hasBridge;

  @override
  Future<String> resolveDeviceId() async {
    if (!_hasBridge) return 'web-browser';
    final r = await _invoke('device');
    return '${r['id'] ?? 'web-browser'}';
  }

  @override
  Future<String> resolveDeviceName() async {
    if (!_hasBridge) return 'browser';
    final r = await _invoke('device');
    return '${r['name'] ?? 'browser'}';
  }

  @override
  Future<String?> pickDirectory() async {
    if (!_hasBridge) return null;
    final r = await _invoke('pickDirectory');
    final p = '${r['path'] ?? ''}';
    return p.isEmpty ? null : p;
  }

  @override
  Future<List<SyncLocalEntry>> scan(
    String root, {
    List<String> include = const [],
    List<String> exclude = const [],
    SyncFilterConfig filter = const SyncFilterConfig(),
  }) async {
    if (!_hasBridge) return const [];
    final r = await _invoke('scan', {'root': root});
    final list = (r['entries'] as List?) ?? const [];
    final out = <SyncLocalEntry>[];
    for (final e in list) {
      if (e is! Map) continue;
      final rel = normalizeRel('${e['path'] ?? ''}');
      if (rel.isEmpty) continue;
      final size = (e['size'] as num?)?.toInt() ?? 0;
      // include/exclude 与体积规则在客户端算（与服务端 `plan.ts` 同一口径），
      // 主进程只负责「把目录扫出来」
      if (!inSyncScope(rel, include, exclude)) continue;
      if (filterExcluded(rel, size, filter)) continue;
      out.add(
        SyncLocalEntry(
          path: rel,
          size: size,
          mtimeMs: (e['mtimeMs'] as num?)?.toInt() ?? 0,
        ),
      );
    }
    return out;
  }

  @override
  @override
  Future<int> sizeOf(String path) async {
    if (!_hasBridge) throw UnsupportedError('sync_requires_desktop');
    final r = await _invoke('sizeOf', {'path': path});
    return (r['size'] as num?)?.toInt() ?? 0;
  }

  @override
  Future<List<int>> readChunk(String path, int start, int end) async {
    if (!_hasBridge) throw UnsupportedError('sync_requires_desktop');
    final r = await _invoke('readChunk', {
      'path': path,
      'start': start,
      'end': end,
    });
    final b64 = '${r['data'] ?? ''}';
    if (b64.isEmpty) return const [];
    return base64Decode(b64);
  }

  @override
  Future<void> download({
    required Uri uri,
    required Map<String, String> headers,
    required String localPath,
    required int mtimeMs,
    required void Function(int received) onProgress,
    required bool Function() cancelled,
  }) async {
    if (!_hasBridge) throw UnsupportedError('sync_requires_desktop');
    final jobId = 'job-${DateTime.now().microsecondsSinceEpoch}';
    await _invoke('download', {
      'jobId': jobId,
      'uri': uri.toString(),
      'headers': headers,
      'localPath': localPath,
      'mtimeMs': mtimeMs,
    });
    // 主进程后台下载，这里轮询进度：不用在 JS 侧注册回调，来回都只是 JSON
    for (var i = 0; i < 86400; i += 1) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (cancelled()) {
        await _invoke('cancel', {'jobId': jobId});
        throw StateError('cancelled');
      }
      final p = await _invoke('progress', {'jobId': jobId});
      onProgress((p['received'] as num?)?.toInt() ?? 0);
      if (p['done'] == true) {
        final err = '${p['error'] ?? ''}';
        if (err.isNotEmpty) throw StateError(err);
        return;
      }
    }
    throw StateError('download timeout');
  }

  @override
  Future<void> deleteLocal(String path) async {
    if (!_hasBridge) throw UnsupportedError('sync_requires_desktop');
    await _invoke('deleteLocal', {'path': path});
  }

  @override
  Future<bool> exists(String path) async {
    if (!_hasBridge) return false;
    final r = await _invoke('exists', {'path': path});
    return r['exists'] == true;
  }
}

SyncFs createPlatformSyncFs() => const WebSyncFs();
