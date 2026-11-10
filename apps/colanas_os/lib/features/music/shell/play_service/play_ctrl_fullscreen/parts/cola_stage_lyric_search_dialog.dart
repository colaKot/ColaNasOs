import 'package:flutter/material.dart';

import '../../../compat/getx.dart';

import '../../../compat/api_base.dart';
import '../../../compat/host.dart';
import '../../controller/cola_player_controller.dart';

class _LyricSearchItem {
  final String title;
  final String source;
  final String preview;
  final String lrc;
  final String id;
  final int durationMs;
  final String artist;
  final String album;

  const _LyricSearchItem({
    required this.title,
    required this.source,
    required this.preview,
    required this.lrc,
    required this.id,
    required this.durationMs,
    required this.artist,
    required this.album,
  });

  factory _LyricSearchItem.fromMap(Map<dynamic, dynamic> map) {
    return _LyricSearchItem(
      title: map['title']?.toString() ?? '',
      source: map['source']?.toString() ?? '',
      preview: map['preview']?.toString() ?? '',
      lrc: map['lrc']?.toString() ?? '',
      id: map['id']?.toString() ?? '',
      durationMs: int.tryParse(map['duration']?.toString() ?? '') ?? 0,
      artist: map['artist']?.toString() ?? '',
      album: map['album']?.toString() ?? '',
    );
  }

  Duration get duration =>
      Duration(milliseconds: durationMs < 0 ? 0 : durationMs);

  String get previewLine {
    return _firstLyricLineFromLrc(lrc);
  }

  static String _firstLyricLineFromLrc(String lrc) {
    final localText = lrc.trim();
    if (localText.isEmpty) return '';
    final lines = localText.split(RegExp(r'\r?\n'));
    for (final raw in lines) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('[') && line.contains(']')) {
        final localIdx = line.lastIndexOf(']');
        final localAfter = localIdx >= 0
            ? line.substring(localIdx + 1).trim()
            : '';
        if (localAfter.isNotEmpty) return localAfter;
        continue;
      }
      return line;
    }
    return '';
  }
}

class _LyricApiService extends BaseApiService {
  static _LyricApiService get instance => _LyricApiService();

  Future<List<_LyricSearchItem>> searchLyric(
    String localKeyword, {
    bool showLoading = false,
  }) async {
    final localQ = localKeyword.trim();
    if (localQ.isEmpty) return const <_LyricSearchItem>[];
    final localReply = await apiPost<List<dynamic>>(
      '/api/music/lyric/search',
      body: {'keyword': localQ},
      showLoading: showLoading,
    );
    if (!localReply.success) return const <_LyricSearchItem>[];
    final raw = localReply.data ?? const <dynamic>[];
    return raw
        .whereType<Map>()
        .map((e) => _LyricSearchItem.fromMap(e))
        .toList();
  }

  Future<bool> setLyric({
    required String musicPath,
    required String lrc,
    bool showLoading = false,
  }) async {
    final localLyric = lrc.trim();
    final localP = musicPath.trim();
    if (localP.isEmpty || localLyric.isEmpty) return false;
    final localReply = await apiPost<Map<String, dynamic>>(
      '/api/music/lyric/set',
      body: {'music_path': localP, 'lrc': localLyric},
      showLoading: showLoading,
    );
    return localReply.success;
  }
}

class MusicPlayCtrlFullScreenLyricSearchDialog {
  static String _fileStem(String filePath) {
    final raw = filePath.trim();
    if (raw.isEmpty) return '';
    final localNormalized = raw.replaceAll('\\', '/');
    final localSlash = localNormalized.lastIndexOf('/');
    final name = localSlash >= 0
        ? localNormalized.substring(localSlash + 1)
        : localNormalized;
    final localDot = name.lastIndexOf('.');
    if (localDot > 0) return name.substring(0, localDot);
    return name;
  }

  static String _normalizeForContains(String input) {
    final localS = input.trim().toLowerCase();
    if (localS.isEmpty) return '';
    return localS.replaceAll(RegExp(r'[^0-9a-z\u4e00-\u9fff]+'), '');
  }

  static final RegExp _audioExt = RegExp(
    r'\.(flac|mp3|ape|wav|m4a|aac|ogg|opus|wma|alac|aiff|aif)$',
    caseSensitive: false,
  );

  /// 搜索用的关键词**只取歌名**。
  ///
  /// 以前这里是 `'$title $artist'`，而 `displayTitle` 返回的是**完整文件名**
  /// （`01 永夜.flac`），拼完变成 `01 永夜.flac 任贤齐` —— LRCLIB 的 `q=` 对词序敏感，
  /// 这种串一个结果都不会有。现在剥掉扩展名 / 开头的音轨号，艺人也不拼进去
  /// （服务端查不到时会自动按单词再查一轮）。
  static String _searchTitle(String title, String musicPath) {
    var localT = title.trim();
    if (localT.isEmpty || _audioExt.hasMatch(localT))
      localT = _fileStem(musicPath);
    localT = localT.replaceFirst(_audioExt, '');
    // 开头音轨号：`01 永夜` / `01. 永夜` / `01-永夜` / `[01] 永夜` / `(01)永夜`
    localT = localT.replaceFirst(
      RegExp(r'^\s*[\[\(]?\d{1,3}[\]\)]?[\s\.\-_、]+'),
      '',
    );
    localT = localT.replaceFirst(RegExp(r'^\s*[\[\(]\d{1,3}[\]\)]\s*'), '');
    localT = localT.trim();
    return localT.isEmpty ? _fileStem(musicPath).trim() : localT;
  }

  static Future<String?> show(
    BuildContext context, {
    required String musicPath,
    required String title,
    required String artist,
    required Duration trackDuration,
  }) async {
    var localKeyword = _searchTitle(title, musicPath);
    final localTheme = Theme.of(context);
    var localSelectingId = '';
    var loading = false;
    var didAutoSearch = false;
    var localResults = <_LyricSearchItem>[];

    Future<void> doSearch(StateSetter setState) async {
      final localQ = localKeyword.trim();
      if (localQ.isEmpty) {
        ToastUtil.show('input_please'.tr);
        return;
      }
      setState(() {
        loading = true;
        localResults = <_LyricSearchItem>[];
      });
      try {
        final localList = await _LyricApiService.instance.searchLyric(localQ);
        setState(() {
          localResults = localList;
        });
      } finally {
        setState(() {
          loading = false;
        });
      }
    }

    return showDialog<String>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setState) {
            if (!didAutoSearch) {
              didAutoSearch = true;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (context.mounted) doSearch(setState);
              });
            }
            final input = TextFormField(
              textInputAction: TextInputAction.search,
              onFieldSubmitted: (_) => doSearch(setState),
              onChanged: (v) => localKeyword = v,
              initialValue: localKeyword,
              decoration: InputDecoration(
                hintText: 'search'.tr,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.all(Radius.circular(12)),
                ),
                prefixIcon: const Icon(Icons.search),
                suffixIcon: IconButton(
                  tooltip: 'search'.tr,
                  onPressed: loading ? null : () => doSearch(setState),
                  icon: const Icon(Icons.search),
                ),
              ),
              autofocus: true,
            );

            Widget body;
            if (loading) {
              body = const Center(
                child: SizedBox(
                  width: 22.0,
                  height: 22.0,
                  child: CircularProgressIndicator(strokeWidth: 2.0),
                ),
              );
            } else if (localResults.isEmpty) {
              body = Padding(
                padding: const EdgeInsets.fromLTRB(0, 26, 0, 26),
                child: Center(child: Text('no_data'.tr)),
              );
            } else {
              body = ListView.separated(
                separatorBuilder: (context, _) => const Divider(height: 1.0),
                itemCount: localResults.length,
                itemBuilder: (context, index) {
                  final localItem = localResults[index];
                  final localDurationDiffMs =
                      (localItem.durationMs - trackDuration.inMilliseconds)
                          .abs();
                  final localDurationMatch =
                      localItem.durationMs > 0 && localDurationDiffMs <= 5000;
                  final localFileStemNorm = _normalizeForContains(
                    _fileStem(musicPath),
                  );
                  final localTitleNorm = _normalizeForContains(localItem.title);
                  final localNameMatch =
                      localTitleNorm.isNotEmpty &&
                      localFileStemNorm.isNotEmpty &&
                      localFileStemNorm.contains(localTitleNorm);
                  final localHighMatch = localDurationMatch && localNameMatch;
                  final localMeta = [
                    if (localItem.artist.trim().isNotEmpty)
                      localItem.artist.trim(),
                    if (localItem.album.trim().isNotEmpty)
                      localItem.album.trim(),
                    if (localItem.durationMs > 0)
                      FormatUtil.formatDuration(localItem.duration),
                  ].join(' · ');

                  final localSelecting = localSelectingId == localItem.id;

                  return Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10.0,
                      vertical: 6.0,
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Row(
                                children: <Widget>[
                                  if (localHighMatch)
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6.0,
                                        vertical: 2.0,
                                      ),
                                      decoration: BoxDecoration(
                                        border: Border.all(
                                          color: localTheme
                                              .colorScheme
                                              .onSurface
                                              .withValues(alpha: 0.6),
                                        ),
                                        borderRadius: BorderRadius.all(
                                          Radius.circular(6),
                                        ),
                                      ),
                                      child: Text(
                                        '高匹配度',
                                        style: localTheme.textTheme.bodySmall
                                            ?.copyWith(
                                              fontSize: 11.0,
                                              height: 1.2,
                                              color: localTheme
                                                  .colorScheme
                                                  .onSurface
                                                  .withValues(alpha: 0.85),
                                            ),
                                      ),
                                    ),
                                  if (localHighMatch)
                                    const SizedBox(width: 8.0),
                                  Expanded(
                                    child: Text(
                                      localItem.title.trim().isEmpty
                                          ? localItem.id
                                          : localItem.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: localTheme.textTheme.bodyLarge
                                          ?.copyWith(
                                            fontWeight: FontWeight.w600,
                                          ),
                                    ),
                                  ),
                                ],
                              ),
                              if (localMeta.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    0,
                                    2,
                                    0,
                                    0,
                                  ),
                                  child: Text(
                                    localMeta,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: localTheme.textTheme.bodySmall
                                        ?.copyWith(
                                          color: localTheme
                                              .colorScheme
                                              .onSurface
                                              .withValues(alpha: 0.65),
                                        ),
                                  ),
                                ),
                              Padding(
                                padding: const EdgeInsets.fromLTRB(0, 2, 0, 0),
                                child: Tooltip(
                                  message: localItem.lrc.trim(),
                                  waitDuration: const Duration(
                                    milliseconds: 250,
                                  ),
                                  child: Text(
                                    localItem.previewLine.trim().isEmpty
                                        ? '\u00A0'
                                        : localItem.previewLine.trim(),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: localTheme.textTheme.bodySmall
                                        ?.copyWith(
                                          color: localTheme
                                              .colorScheme
                                              .onSurface
                                              .withValues(alpha: 0.65),
                                        ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 10.0),
                        SizedBox(
                          width: 90.0,
                          child: TextButton(
                            onPressed: localSelecting
                                ? null
                                : () async {
                                    final lrc = localItem.lrc.trim();
                                    if (lrc.isEmpty) {
                                      ToastUtil.show('operation_failed'.tr);
                                      return;
                                    }
                                    setState(() {
                                      localSelectingId = localItem.id;
                                    });
                                    try {
                                      final ok = await _LyricApiService.instance
                                          .setLyric(
                                            musicPath: musicPath,
                                            lrc: lrc,
                                          );
                                      if (!ok) {
                                        ToastUtil.show('operation_failed'.tr);
                                        return;
                                      }
                                      MusicPlayServiceController.instance
                                          .applyLyricOverride(musicPath, lrc);
                                      if (ctx.mounted) {
                                        Navigator.of(ctx).pop(lrc);
                                      }
                                      ToastUtil.show('operation_success'.tr);
                                    } finally {
                                      if (context.mounted) {
                                        setState(() {
                                          localSelectingId = '';
                                        });
                                      }
                                    }
                                  },
                            child: localSelecting
                                ? const SizedBox(
                                    width: 16.0,
                                    height: 16.0,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2.0,
                                    ),
                                  )
                                : Text('select'.tr),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              );
            }

            return DialogUtil.createAlertDialog(
              title: Row(
                children: <Widget>[
                  Expanded(child: Text('music_search_lyric'.tr)),
                  IconButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              content: SizedBox(
                width: 740.0,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    input,
                    const SizedBox(height: 8.0),
                    Flexible(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 420),
                        child: body,
                      ),
                    ),
                  ],
                ),
              ),
              constraints: const BoxConstraints(maxWidth: 780, minWidth: 540),
            );
          },
        );
      },
    );
  }
}
