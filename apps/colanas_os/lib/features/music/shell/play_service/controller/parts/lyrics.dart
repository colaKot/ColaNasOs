part of '../cola_player_controller.dart';

/// 播放器的歌词状态：手动覆盖、切歌时刷新详情、缺词时尝试在线匹配。
///
/// HTTP 与匹配规则已经挪到 `lyric_match.dart`，这里只负责把结果写进
/// `_detailCache` / `_lyricsCache` 以及当前播放项的 Rx 字段。
extension MusicPlayServiceLyrics on MusicPlayServiceController {
  void applyLyricOverride(String musicPath, String lyricText) {
    final path = musicPath.trim();
    if (path.isEmpty) return;
    final text = lyricText.trim();
    _lyricsCache[path] = text;

    final at = currentIndex.value;
    if (at < 0 || at >= playlist.length) return;
    if (_resolvePlayablePath(playlist[at]).trim() == path) {
      currentLyrics.value = text;
    }
  }

  /// 详情里的收藏态与来源标记以列表项为准，避免服务端详情把本地状态覆盖掉。
  MusicListItem _mergeDetail(MusicListItem source, MusicListItem existing) {
    final fromFile =
        existing.isFromFile ||
        existing.showType.trim().toLowerCase() == 'file_browser';
    return fromFile
        ? source.copyWith(
            isFavorite: existing.isFavorite,
            id: 0,
            showType: existing.showType,
            isFromFile: true,
          )
        : source.copyWith(
            isFavorite: existing.isFavorite,
            isFromFile: existing.isFromFile,
          );
  }

  void _maybeFetchOnlineLyric(int index, String filePath, String lyricText) {
    if (index != currentIndex.value || lyricText.trim().isNotEmpty) return;
    unawaited(
      _tryAutoSetLyricIfNoLyric(filePath: filePath, item: playlist[index]),
    );
  }

  Future<void> _refreshDetailForIndex(int index) async {
    if (index < 0 || index >= playlist.length) return;
    final existing = playlist[index];
    final path = _resolvePlayablePath(existing).trim();
    if (path.isEmpty) {
      if (index == currentIndex.value) currentLyrics.value = '';
      return;
    }

    unawaited(
      MusicListApiService.instance.refreshHistory(
        indexId: (!existing.isSeries && existing.id > 0) ? existing.id : null,
        filePath: path,
        showLoading: false,
      ),
    );

    final cachedLyrics = _lyricsCache[path];
    final cachedDetail = _detailCache[path];
    // 详情与歌词两份都齐才短路。只缺歌词必须重拉：空字符串也算「已缓存」的话，
    // 一次失败就永远显示「暂无歌词」，哪怕同目录的 .lrc 就在那里。
    if (cachedDetail != null && cachedLyrics != null) {
      final merged = _mergeDetail(cachedDetail, existing);
      if (playlist[index] != merged) {
        playlist[index] = merged;
        _syncMediaItem(index);
      }
      if (index == currentIndex.value) {
        currentLyrics.value = cachedLyrics.trim();
        _maybeFetchOnlineLyric(index, path, cachedLyrics);
      }
      return;
    }

    final token = ++_detailFetchToken;
    final reply = await MusicListApiService.instance.getDetailByPath(
      path,
      showLoading: false,
    );
    if (token != _detailFetchToken) return;
    if (!reply.success) {
      if (index == currentIndex.value) currentLyrics.value = '';
      return;
    }

    final body = reply.data ?? const <String, dynamic>{};
    final lyrics = (body['lyrics']?.toString() ?? '').trim();
    final rawItem = body['item'];
    if (rawItem is Map) {
      final detail = MusicListItem.fromJson(rawItem.cast<String, dynamic>());
      final merged = _mergeDetail(detail, existing);
      playlist[index] = merged;
      _detailCache[path] = merged;
      _syncMediaItem(index);
    }

    _lyricsCache[path] = lyrics;
    if (index == currentIndex.value) currentLyrics.value = lyrics;
    _maybeFetchOnlineLyric(index, path, lyrics);
  }

  /// 同一路径只自动尝试一次，避免切歌来回触发外部检索。
  Future<void> _tryAutoSetLyricIfNoLyric({
    required String filePath,
    required MusicListItem item,
  }) async {
    final path = filePath.trim();
    if (path.isEmpty || _autoLyricTried.contains(path)) return;
    if ((_lyricsCache[path] ?? '').trim().isNotEmpty) return;

    final fromPlayer = duration.value.inMilliseconds;
    final expectedMs = fromPlayer > 0
        ? fromPlayer
        : durationSecondsToMs(item.duration);
    if (expectedMs <= 0) return;

    final keyword = buildLyricKeyword(item, filePath: path);
    if (keyword.isEmpty) return;
    _autoLyricTried.add(path);

    final candidates = await LyricApiService.instance.search(
      keyword,
      showLoading: false,
    );
    if (candidates.isEmpty) return;

    final stem = normalizeLyricText(lyricFileStem(path));
    final matched = candidates
        .where(
          (candidate) => isHighLyricMatch(
            candidate: candidate,
            fileStemNormalized: stem,
            expectedDurationMs: expectedMs,
          ),
        )
        .toList();
    if (matched.isEmpty) return;

    final text = matched.first.lrc.trim();
    if (text.isEmpty) return;
    final written = await LyricApiService.instance.write(
      musicPath: path,
      lrc: text,
      showLoading: false,
    );
    if (written) applyLyricOverride(path, text);
  }
}
