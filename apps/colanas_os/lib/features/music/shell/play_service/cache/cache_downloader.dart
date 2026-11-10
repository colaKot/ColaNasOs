import 'dart:async';
import 'dart:io';

import '../../compat/cola_api_controller.dart';
import '../../compat/dio_lite.dart' as dio;
import '../../compat/host.dart';
import 'cache_contracts.dart';

/// 一次后台补缓存任务所需的全部上下文。
class AudioCacheTransfer {
  const AudioCacheTransfer({
    required this.partFile,
    required this.finalFile,
    required this.resumeFrom,
    required this.expectedBytes,
    required this.buildUrl,
    required this.refreshAuthToken,
    required this.cancelToken,
    required this.onProgress,
  });

  final File partFile;
  final File finalFile;
  final int resumeFrom;
  final int expectedBytes;
  final Future<String> Function() buildUrl;
  final Future<bool> Function() refreshAuthToken;
  final dio.CancelToken cancelToken;
  final MusicAudioCacheProgressCallback onProgress;
}

/// 把散落的进度回调收口成「节流推送 + 结束推送」。
class _ProgressEmitter {
  _ProgressEmitter(this._sink, this._total);

  final MusicAudioCacheProgressCallback _sink;
  int _total;
  int _lastEmitAt = 0;

  void started(int bytes) => _send(bytes, force: true);

  void updateTotal(int total) {
    _total = total;
  }

  void onChunk(int bytes) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastEmitAt < 120) return;
    _send(bytes, force: true, now: now);
  }

  void finished(int bytes) {
    _sink(
      MusicAudioCacheProgress(
        receivedBytes: bytes,
        totalBytes: _total,
        finished: true,
      ),
    );
  }

  void _send(int bytes, {required bool force, int? now}) {
    if (force) {
      _lastEmitAt = now ?? DateTime.now().millisecondsSinceEpoch;
    }
    _sink(
      MusicAudioCacheProgress(
        receivedBytes: bytes,
        totalBytes: _total,
        finished: false,
      ),
    );
  }
}

/// 负责「把远端音频写进 .part，再改名为最终文件」的全部网络细节。
///
/// 门面层只管命中判断与索引账本；鉴权重试、P2P 地址映射、Range 断点续传、
/// 进度节流都在这里，方便单独替换传输实现。
class AudioCacheDownloader {
  AudioCacheDownloader({dio.Dio? client})
    : _client = client ?? createDioWithBadCertificateCompat();

  final dio.Dio _client;

  static const Duration _timeout = Duration(seconds: 30);
  static final RegExp _contentRange = RegExp(r'bytes\s+\d+-\d+/(\d+)');

  /// 执行一轮下载；401/403 时刷新令牌后重试一次。
  Future<void> transfer(AudioCacheTransfer job) async {
    var proxyHeld = false;

    Future<String> resolve(String raw) async {
      final url = raw.trim();
      final controller = ApiController.instance;
      if (!controller.isP2pMode || !url.startsWith(ApiController.p2pBaseUrl)) {
        return url;
      }
      Uri remote;
      try {
        remote = Uri.parse(url);
      } catch (_) {
        return url;
      }
      final base = await LocalWebAssetServer.instance.acquire();
      proxyHeld = true;
      return Uri.parse(base)
          .replace(path: remote.path, query: remote.query)
          .toString();
    }

    try {
      final firstUrl = await resolve(await job.buildUrl());
      await _streamToFile(job, url: firstUrl, resumeFrom: job.resumeFrom);
    } on dio.DioException catch (error) {
      final status = error.response?.statusCode ?? 0;
      if (status != 401 && status != 403) rethrow;
      if (!await job.refreshAuthToken()) rethrow;
      final retryUrl = await resolve(await job.buildUrl());
      final offset = await job.partFile.exists()
          ? await job.partFile.length()
          : 0;
      await _streamToFile(job, url: retryUrl, resumeFrom: offset);
    } finally {
      if (proxyHeld) await LocalWebAssetServer.instance.release();
    }
  }

  Future<void> _streamToFile(
    AudioCacheTransfer job, {
    required String url,
    required int resumeFrom,
  }) async {
    final parent = job.partFile.parent;
    if (!await parent.exists()) await parent.create(recursive: true);

    var received = resumeFrom;
    var response = await _request(job, url, startAt: received);

    // 服务端忽略 Range 时不能把新数据接到旧文件后面，直接重来。
    if (received > 0 && response.statusCode != 206) {
      if (await job.partFile.exists()) await job.partFile.delete();
      received = 0;
      response = await _request(job, url, startAt: 0);
    }

    final status = response.statusCode ?? 0;
    if (status != 200 && status != 206) {
      throw dio.DioException(
        requestOptions: response.requestOptions,
        response: response,
        type: dio.DioExceptionType.badResponse,
      );
    }

    final emitter = _ProgressEmitter(job.onProgress, job.expectedBytes);
    emitter.updateTotal(
      _totalLength(response, receivedBefore: received, hint: job.expectedBytes),
    );
    emitter.started(received);

    final body = response.data;
    if (body == null) {
      throw dio.DioException(
        requestOptions: response.requestOptions,
        response: response,
        type: dio.DioExceptionType.unknown,
      );
    }

    final sink = job.partFile.openWrite(
      mode: received > 0 ? FileMode.append : FileMode.writeOnly,
    );
    try {
      await for (final chunk in body.stream) {
        sink.add(chunk);
        received += chunk.length;
        emitter.onChunk(received);
      }
    } finally {
      await sink.flush();
      await sink.close();
    }

    if (await job.finalFile.exists()) await job.finalFile.delete();
    await job.partFile.rename(job.finalFile.path);
  }

  Future<dio.Response<dio.ResponseBody>> _request(
    AudioCacheTransfer job,
    String url, {
    required int startAt,
  }) {
    return _client.get<dio.ResponseBody>(
      url,
      options: dio.Options(
        responseType: dio.ResponseType.stream,
        headers: startAt > 0
            ? <String, dynamic>{'Range': 'bytes=$startAt-'}
            : null,
        validateStatus: (code) => code != null && code < 500,
        receiveTimeout: _timeout,
        sendTimeout: _timeout,
      ),
      cancelToken: job.cancelToken,
    );
  }

  int _totalLength(
    dio.Response<dio.ResponseBody> response, {
    required int receivedBefore,
    required int hint,
  }) {
    if (hint > 0) return hint;
    final headers = response.headers?.map ?? const <String, List<String>>{};
    final rangeValues = headers['content-range'];
    final range = rangeValues == null || rangeValues.isEmpty
        ? null
        : rangeValues.first;
    if (range != null) {
      final match = _contentRange.firstMatch(range);
      final parsed = int.tryParse(match?.group(1) ?? '');
      if (parsed != null && parsed > 0) return parsed;
    }
    final lengthValues = headers['content-length'];
    final lengthText = lengthValues == null || lengthValues.isEmpty
        ? ''
        : lengthValues.first;
    final length = int.tryParse(lengthText);
    if (length == null || length <= 0) return 0;
    if (response.statusCode == 206 && receivedBefore > 0) {
      return receivedBefore + length;
    }
    return length;
  }
}
