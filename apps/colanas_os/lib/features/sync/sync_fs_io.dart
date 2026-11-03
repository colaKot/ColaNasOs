import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:nas_ui/nas_ui.dart';

import 'sync_fs.dart';

/// 桌面 / 移动端实现：真实读写本地目录。
class IoSyncFs implements SyncFs {
  const IoSyncFs();

  @override
  bool get canSync => true;

  @override
  Future<String> resolveDeviceId() async {
    try {
      if (Platform.isWindows) {
        final r = await Process.run('reg', [
          'query',
          r'HKLM\SOFTWARE\Microsoft\Cryptography',
          '/v',
          'MachineGuid',
        ], runInShell: false).timeout(const Duration(seconds: 6));
        final m = RegExp(r'MachineGuid\s+(.{8}-.{4}-.{4}-.{4}-.{12})')
            .firstMatch('${r.stdout}');
        if (m != null) return 'win-${m.group(1)!.toLowerCase()}';
      } else if (Platform.isMacOS) {
        final r = await Process.run(
          'ioreg',
          ['-rd1', '-c', 'IOPlatformExpertDevice'],
        ).timeout(const Duration(seconds: 6));
        final m = RegExp(r'"IOPlatformUUID"\s*=\s*"([^"]+)"')
            .firstMatch('${r.stdout}');
        if (m != null) return 'mac-${m.group(1)!.toLowerCase()}';
      } else if (Platform.isLinux) {
        final id = await File('/etc/machine-id').readAsString();
        final v = id.trim();
        if (v.isNotEmpty) return 'linux-$v';
      }
    } catch (_) {
      // 读不到就用主机名兜底：宁可重复也要能同步
    }
    return 'host-${_hostName().toLowerCase()}';
  }

  @override
  Future<String> resolveDeviceName() async => _hostName();

  String _hostName() {
    if (Platform.isWindows) {
      final name = Platform.environment['COMPUTERNAME'];
      if (name != null && name.isNotEmpty) return name;
    }
    final name = Platform.localHostname;
    return name.isEmpty ? 'device' : name;
  }

  @override
  Future<String?> pickDirectory() async {
    try {
      return await getDirectoryPath(confirmButtonText: tr('common.select'));
    } catch (_) {
      return null;
    }
  }

  @override
  Future<List<SyncLocalEntry>> scan(
    String root, {
    List<String> include = const [],
    List<String> exclude = const [],
    SyncFilterConfig filter = const SyncFilterConfig(),
  }) async {
    final dir = Directory(root);
    if (!await dir.exists()) {
      throw FileSystemException(tr('sync.dirMissing'), root);
    }
    final out = <SyncLocalEntry>[];
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final rel = normalizeRel(
        entity.path.substring(root.length).replaceAll(RegExp(r'^[/\\]+'), ''),
      );
      if (rel.isEmpty) continue;
      if (!inSyncScope(rel, include, exclude)) continue;
      try {
        final st = await entity.stat();
        if (filterExcluded(rel, st.size, filter)) continue;
        out.add(
          SyncLocalEntry(
            path: rel,
            size: st.size,
            mtimeMs: st.modified.millisecondsSinceEpoch,
          ),
        );
      } catch (_) {
        // 扫描期间被删除 / 占用：跳过，服务端下一轮会重新判定
      }
    }
    out.sort((a, b) => a.path.compareTo(b.path));
    return out;
  }

  @override
  Future<List<int>> readChunk(String path, int start, int end) async {
    final file = File(path);
    final raf = await file.open();
    try {
      await raf.setPosition(start);
      return await raf.read(end - start);
    } finally {
      await raf.close();
    }
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
    final client = HttpClient();
    final target = File(localPath);
    final tmp = File('$localPath.synctmp');
    IOSink? sink;
    try {
      await target.parent.create(recursive: true);
      if (await tmp.exists()) await tmp.delete();

      final req = await client.getUrl(uri).timeout(const Duration(seconds: 30));
      headers.forEach((k, v) => req.headers.set(k, v));
      final res = await req.close().timeout(const Duration(minutes: 30));
      if (res.statusCode != 200) {
        throw HttpException('HTTP ${res.statusCode}', uri: uri);
      }

      sink = tmp.openWrite();
      var received = 0;
      await for (final chunk in res) {
        if (cancelled()) throw const _SyncCancelled();
        sink.add(chunk);
        received += chunk.length;
        onProgress(received);
      }
      await sink.flush();
      await sink.close();
      sink = null;

      if (await target.exists()) await target.delete();
      await tmp.rename(localPath);
      if (mtimeMs > 0) {
        try {
          await File(localPath)
              .setLastModified(DateTime.fromMillisecondsSinceEpoch(mtimeMs));
        } catch (_) {
          // 时间对齐失败不阻断（下一轮最多多传一次）
        }
      }
    } catch (_) {
      try {
        await sink?.flush();
      } catch (_) {}
      try {
        await sink?.close();
      } catch (_) {}
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<void> deleteLocal(String path) async {
    final f = File(path);
    if (await f.exists()) await f.delete();
  }

  @override
  Future<bool> exists(String path) => File(path).exists();
}

class _SyncCancelled implements Exception {
  const _SyncCancelled();
  @override
  String toString() => 'sync_cancelled';
}

SyncFs createPlatformSyncFs() => const IoSyncFs();
