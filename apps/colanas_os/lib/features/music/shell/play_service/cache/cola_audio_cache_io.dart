import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../compat/dio_lite.dart' as dio;
import '../../compat/host.dart';
import '../player/cola_player_adapter.dart';
import 'cache_contracts.dart';
import 'cache_downloader.dart';
import 'cache_index.dart';

export 'cache_contracts.dart';

/// 原生端的音频缓存门面。
///
/// 只负责三件事：决定「本地文件 / 网络直播」、维护下载任务的生命周期、
/// 把结果包装成播放器需要的源。索引账本在 [AudioCacheIndex]，字节传输在
/// [AudioCacheDownloader]，两者都不感知 UI 或播放器类型。
class MusicAudioCacheService {
  MusicAudioCacheService({required this.options});

  MusicAudioCacheOptions options;

  Directory? _root;
  late final AudioCacheIndex _ledger = AudioCacheIndex(() => _root);
  final AudioCacheDownloader _transfer = AudioCacheDownloader();

  dio.CancelToken? _token;
  String? _activeHash;
  bool _downloading = false;

  bool get isDownloading => _downloading;

  String? get activeHash => _activeHash;

  Future<void> init() async {
    final support = await getApplicationSupportDirectory();
    final folder = Directory(p.join(support.path, 'music_audio_cache'));
    if (!await folder.exists()) await folder.create(recursive: true);
    _root = folder;
    await _ledger.restore();
  }

  void updateOptions(MusicAudioCacheOptions value) => options = value;

  Future<MusicAudioCacheStats> getStats() => _ledger.stats();

  Future<void> clearAll() async {
    await cancelActiveDownload();
    await _ledger.clear();
  }

  Future<void> remove(String fileHash) => _ledger.forget(fileHash.trim());

  Future<void> cancelActiveDownload() async {
    final current = _token;
    if (current != null && !current.isCancelled) current.cancel();
    _token = null;
    _activeHash = null;
    _downloading = false;
  }

  Future<bool> hasCached(String fileHash) async {
    if (_root == null) return false;
    final file = _ledger.completedFile(fileHash.trim());
    return file != null && await file.exists();
  }

  /// 给 just_audio 一类的播放器准备播放源；命中缓存时仍会取一次 url 作为兜底。
  Future<MusicPlaySource> prepareSource({
    required String fileHash,
    required String fileExt,
    required int fileSize,
    required Future<String> Function() buildUrl,
    required Future<bool> Function() refreshAuthToken,
    required MusicAudioCacheProgressCallback onProgress,
  }) async {
    final request = CacheSourceRequest(
      fileHash: fileHash,
      fileExt: fileExt,
      fileSize: fileSize,
      buildUrl: buildUrl,
      refreshAuthToken: refreshAuthToken,
      onProgress: onProgress,
    );
    final artifact = await _resolve(request);
    final url = await buildUrl();
    final local = artifact.localPath;
    if (local != null) {
      return MusicPlaySource(
        filePath: local,
        url: url,
        fileExt: artifact.extension,
      );
    }
    return MusicPlaySource(url: url, fileExt: artifact.extension);
  }

  /// 给 media_kit 准备控制器；命中缓存时不需要再取网络地址。
  Future<VideoPlayerController> prepareController({
    required String fileHash,
    required String fileExt,
    required int fileSize,
    required Future<String> Function() buildUrl,
    required Future<bool> Function() refreshAuthToken,
    required MusicAudioCacheProgressCallback onProgress,
  }) async {
    final request = CacheSourceRequest(
      fileHash: fileHash,
      fileExt: fileExt,
      fileSize: fileSize,
      buildUrl: buildUrl,
      refreshAuthToken: refreshAuthToken,
      onProgress: onProgress,
    );
    final artifact = await _resolve(request);
    final local = artifact.localPath;
    if (local != null) return VideoPlayerController.file(File(local));
    return createVideoController(await buildUrl());
  }

  Future<CacheArtifact> _resolve(CacheSourceRequest request) async {
    final folder = _root;
    final hash = request.normalizedHash;
    if (!options.enabled || folder == null || hash.isEmpty) {
      return CacheArtifact.remote('');
    }

    final ext = request.normalizedExt;
    final filename = '$hash.$ext';
    final complete = File(p.join(folder.path, filename));

    if (await complete.exists()) {
      final sizeMatches =
          request.fileSize <= 0 || await complete.length() == request.fileSize;
      if (sizeMatches) {
        await _ledger.mark(hash: hash, filename: filename, completed: true);
        await _ledger.trimTo(options.maxItems);
        return CacheArtifact.local(complete.path, ext);
      }
      await complete.delete();
    }

    await _ledger.mark(hash: hash, filename: filename, completed: false);
    await _spawn(request, folder: folder, hash: hash, filename: filename);
    return CacheArtifact.pending(ext);
  }

  Future<void> _spawn(
    CacheSourceRequest request, {
    required Directory folder,
    required String hash,
    required String filename,
  }) async {
    await cancelActiveDownload();

    final part = File(p.join(folder.path, '$filename.part'));
    final complete = File(p.join(folder.path, filename));
    final offset = await part.exists() ? await part.length() : 0;
    request.onProgress(
      MusicAudioCacheProgress(
        receivedBytes: offset,
        totalBytes: request.sizeHint,
      ),
    );

    final token = dio.CancelToken();
    _token = token;
    _activeHash = hash;
    _downloading = true;

    final job = AudioCacheTransfer(
      partFile: part,
      finalFile: complete,
      resumeFrom: offset,
      expectedBytes: request.sizeHint,
      buildUrl: request.buildUrl,
      refreshAuthToken: request.refreshAuthToken,
      cancelToken: token,
      onProgress: request.onProgress,
    );
    unawaited(_run(job, hash: hash, filename: filename, offset: offset));
  }

  Future<void> _run(
    AudioCacheTransfer job, {
    required String hash,
    required String filename,
    required int offset,
  }) async {
    try {
      await _transfer.transfer(job);
      await _ledger.mark(hash: hash, filename: filename, completed: true);
      await _ledger.trimTo(options.maxItems);
    } on dio.DioException catch (error) {
      if (!dio.CancelToken.isCancel(error)) {
        await _markIncomplete(hash, filename);
      }
    } catch (_) {
      await _markIncomplete(hash, filename);
    } finally {
      job.onProgress(
        MusicAudioCacheProgress(
          receivedBytes: await _receivedBytes(job, offset),
          totalBytes: job.expectedBytes,
          finished: true,
        ),
      );
      if (identical(_token, job.cancelToken)) {
        _downloading = false;
        _token = null;
        _activeHash = null;
      }
    }
  }

  Future<void> _markIncomplete(String hash, String filename) =>
      _ledger.mark(hash: hash, filename: filename, completed: false);

  Future<int> _receivedBytes(AudioCacheTransfer job, int offset) async {
    try {
      if (await job.partFile.exists()) return await job.partFile.length();
      if (await job.finalFile.exists()) return await job.finalFile.length();
    } catch (_) {
      // 读取失败时沿用断点位置，UI 至少不会倒退。
    }
    return offset;
  }
}
