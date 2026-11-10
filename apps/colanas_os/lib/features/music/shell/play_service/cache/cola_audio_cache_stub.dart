import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;

import '../../compat/cola_api_controller.dart';
import '../../compat/host.dart';
import '../player/cola_player_adapter.dart';
import 'cache_contracts.dart';

export 'cache_contracts.dart';

/// Web 端不落盘，唯一需要管理的是 P2P 模式下生成的 Blob URL。
class _BlobUrlPool {
  final Map<String, String> _byHash = <String, String>{};

  String? lookup(String hash) => hash.isEmpty ? null : _byHash[hash];

  void bind(String hash, String url) {
    if (hash.isNotEmpty) _byHash[hash] = url;
  }

  void release(String hash) {
    final key = hash.trim();
    if (key.isEmpty) return;
    final url = _byHash.remove(key);
    if (url != null && url.isNotEmpty) _revoke(url);
  }

  void releaseAll() {
    for (final url in _byHash.values) {
      _revoke(url);
    }
    _byHash.clear();
  }

  static void _revoke(String url) {
    try {
      web.URL.revokeObjectURL(url);
    } catch (_) {
      // 页面卸载时 revoke 可能抛错，忽略即可。
    }
  }
}

/// 把 P2P 音频取成浏览器 Blob，再交给播放器；失败时返回 null 走普通网络源。
class _P2pClip {
  const _P2pClip(this._pool);

  final _BlobUrlPool _pool;

  Future<VideoPlayerController?> controller({
    required String sourceUrl,
    required String hash,
    required String fileExt,
  }) async {
    if (!kIsWeb || !ApiController.instance.isP2pMode) return null;

    final existing = _pool.lookup(hash);
    if (existing != null && existing.isNotEmpty) {
      return VideoPlayerController.networkUrl(Uri.parse(existing));
    }

    final relative = _relativePath(sourceUrl);
    if (relative.isEmpty) return null;

    final response = await _send(relative);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('p2p_audio_http_${response.statusCode}');
    }

    final bytes = await response.stream.toBytes();
    final mime = _mimeOf(response.headers['content-type'], fileExt);
    final blobPart = Uint8List.fromList(bytes).buffer.toJS;
    final blob = web.Blob([blobPart].toJS, web.BlobPropertyBag(type: mime));
    final objectUrl = web.URL.createObjectURL(blob);
    _pool.bind(hash, objectUrl);
    return VideoPlayerController.networkUrl(Uri.parse(objectUrl));
  }

  String _relativePath(String sourceUrl) {
    try {
      final uri = Uri.parse(sourceUrl);
      return uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path;
    } catch (_) {
      return '';
    }
  }

  Future<http.StreamedResponse> _send(String relative) {
    final suffix = relative.startsWith('/') ? relative : '/$relative';
    final request = http.Request(
      'GET',
      Uri.parse('${ApiController.p2pBaseUrl}$suffix'),
    );
    final token = ApiController.instance.accessToken?.trim() ?? '';
    if (token.isNotEmpty) request.headers['Authorization'] = 'Bearer $token';
    return ApiController.instance.sendP2pRequest(request);
  }

  String _mimeOf(String? raw, String fileExt) {
    var mime = raw?.trim() ?? '';
    if (mime.isNotEmpty) {
      final semicolon = mime.indexOf(';');
      return semicolon == -1 ? mime : mime.substring(0, semicolon).trim();
    }
    return switch (fileExt.trim().toLowerCase()) {
      'mp3' => 'audio/mpeg',
      'aac' => 'audio/aac',
      'm4a' || 'mp4' => 'audio/mp4',
      'wav' => 'audio/wav',
      'ogg' || 'opus' => 'audio/ogg',
      'flac' => 'audio/flac',
      _ => 'application/octet-stream',
    };
  }
}

/// Web 端实现：保持与原生端相同的接口，但只做透传与 Blob URL 复用。
class MusicAudioCacheService {
  MusicAudioCacheService({required this.options});

  MusicAudioCacheOptions options;

  final _BlobUrlPool _pool = _BlobUrlPool();
  late final _P2pClip _p2p = _P2pClip(_pool);

  Future<void> init() async {}

  void updateOptions(MusicAudioCacheOptions value) => options = value;

  Future<MusicAudioCacheStats> getStats() async => MusicAudioCacheStats.empty;

  Future<void> clearAll() async {
    if (kIsWeb) _pool.releaseAll();
  }

  Future<void> remove(String fileHash) async {
    if (kIsWeb) _pool.release(fileHash);
  }

  bool get isDownloading => false;

  String? get activeHash => null;

  Future<void> cancelActiveDownload() async {}

  Future<bool> hasCached(String fileHash) async => false;

  Future<MusicPlaySource> prepareSource({
    required String fileHash,
    required String fileExt,
    required int fileSize,
    required Future<String> Function() buildUrl,
    required Future<bool> Function() refreshAuthToken,
    required MusicAudioCacheProgressCallback onProgress,
  }) async {
    final url = await buildUrl();
    return MusicPlaySource(url: url, fileExt: fileExt);
  }

  Future<VideoPlayerController> prepareController({
    required String fileHash,
    required String fileExt,
    required int fileSize,
    required Future<String> Function() buildUrl,
    required Future<bool> Function() refreshAuthToken,
    required MusicAudioCacheProgressCallback onProgress,
  }) async {
    final url = await buildUrl();
    final hash = fileHash.trim();
    try {
      final clip = await _p2p.controller(
        sourceUrl: url,
        hash: hash,
        fileExt: fileExt,
      );
      if (clip != null) return clip;
    } catch (_) {
      // P2P 通道不可用时退回服务端直连，播放不应因此中断。
    }
    return VideoPlayerController.networkUrl(Uri.parse(url));
  }
}
