import 'package:flutter/material.dart';

import '../../../compat/api_base.dart';
import '../../../compat/getx.dart';
import '../../../compat/host.dart';
import '../../controller/cola_player_controller.dart';

/// 一条在线歌词搜索结果。
class _LyricHit {
  const _LyricHit({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    required this.durationMs,
    required this.lrc,
  });

  factory _LyricHit.fromMap(Map<dynamic, dynamic> map) {
    String read(String key) => map[key]?.toString() ?? '';
    return _LyricHit(
      id: read('id'),
      title: read('title'),
      artist: read('artist'),
      album: read('album'),
      durationMs: int.tryParse(read('duration')) ?? 0,
      lrc: read('lrc'),
    );
  }

  final String id;
  final String title;
  final String artist;
  final String album;
  final int durationMs;
  final String lrc;

  Duration get duration =>
      Duration(milliseconds: durationMs < 0 ? 0 : durationMs);

  /// 列表里展示第一句有效歌词，整段放在 tooltip 里。
  String get previewLine => _firstContentLine(lrc);

  static String _firstContentLine(String lrc) {
    final text = lrc.trim();
    if (text.isEmpty) return '';
    for (final raw in text.split(RegExp(r'\r?\n'))) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('[') && line.contains(']')) {
        final close = line.lastIndexOf(']');
        final content = close >= 0 ? line.substring(close + 1).trim() : '';
        if (content.isNotEmpty) return content;
        continue;
      }
      return line;
    }
    return '';
  }
}

class _LyricLookupApi extends BaseApiService {
  static _LyricLookupApi get instance => _LyricLookupApi();

  Future<List<_LyricHit>> search(
    String keyword, {
    bool showLoading = false,
  }) async {
    final query = keyword.trim();
    if (query.isEmpty) return const <_LyricHit>[];
    final reply = await apiPost<List<dynamic>>(
      '/api/music/lyric/search',
      body: {'keyword': query},
      showLoading: showLoading,
    );
    if (!reply.success) return const <_LyricHit>[];
    final rows = reply.data ?? const <dynamic>[];
    return rows.whereType<Map>().map(_LyricHit.fromMap).toList();
  }

  Future<bool> write({
    required String musicPath,
    required String lrc,
    bool showLoading = false,
  }) async {
    final path = musicPath.trim();
    final lyric = lrc.trim();
    if (path.isEmpty || lyric.isEmpty) return false;
    final reply = await apiPost<Map<String, dynamic>>(
      '/api/music/lyric/set',
      body: {'music_path': path, 'lrc': lyric},
      showLoading: showLoading,
    );
    return reply.success;
  }
}

/// 在线歌词搜索弹窗。
class ColaMusicStageLyricSearch {
  const ColaMusicStageLyricSearch._();

  static final RegExp _audioExtension = RegExp(
    r'\.(flac|mp3|ape|wav|m4a|aac|ogg|opus|wma|alac|aiff|aif)$',
    caseSensitive: false,
  );

  // 开头的音轨号：`01 永夜`、`01. 永夜`、`[01] 永夜`、`(01)永夜`
  static final RegExp _leadingTrackNo = RegExp(
    r'^\s*[\[\(]?\d{1,3}[\]\)]?[\s\.\-_、]+',
  );
  static final RegExp _bracketedTrackNo = RegExp(r'^\s*[\[\(]\d{1,3}[\]\)]\s*');

  static Future<String?> show(
    BuildContext context, {
    required String musicPath,
    required String title,
    required String artist,
    required Duration trackDuration,
  }) {
    return showDialog<String>(
      context: context,
      builder: (_) => _LyricSearchSheet(
        musicPath: musicPath,
        trackDuration: trackDuration,
        initialKeyword: _keywordFor(title, musicPath),
      ),
    );
  }

  /// 检索词只保留歌名。
  ///
  /// `title` 实际是完整文件名（如 `01 永夜.flac`），直接拼艺人会让
  /// LRCLIB 的 `q=` 一个结果都返回不了，所以这里剥掉扩展名与音轨号，
  /// 艺人交给服务端在查不到时自行放宽。
  static String _keywordFor(String title, String musicPath) {
    var text = title.trim();
    if (text.isEmpty || _audioExtension.hasMatch(text)) {
      text = _stemOf(musicPath);
    }
    text = text.replaceFirst(_audioExtension, '');
    text = text
        .replaceFirst(_leadingTrackNo, '')
        .replaceFirst(_bracketedTrackNo, '')
        .trim();
    return text.isEmpty ? _stemOf(musicPath).trim() : text;
  }

  /// 路径 → 去掉目录与扩展名的文件名。
  static String _stemOf(String filePath) {
    final raw = filePath.trim();
    if (raw.isEmpty) return '';
    final normalized = raw.replaceAll('\\', '/');
    final slash = normalized.lastIndexOf('/');
    final name = slash >= 0 ? normalized.substring(slash + 1) : normalized;
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  /// 只留字母数字与汉字，用于「文件名是否包含歌名」的宽松比对。
  static String _squash(String input) {
    final text = input.trim().toLowerCase();
    if (text.isEmpty) return '';
    return text.replaceAll(RegExp(r'[^0-9a-z\u4e00-\u9fff]+'), '');
  }
}

class _LyricSearchSheet extends StatefulWidget {
  const _LyricSearchSheet({
    required this.musicPath,
    required this.trackDuration,
    required this.initialKeyword,
  });

  final String musicPath;
  final Duration trackDuration;
  final String initialKeyword;

  @override
  State<_LyricSearchSheet> createState() => _LyricSearchSheetState();
}

class _LyricSearchSheetState extends State<_LyricSearchSheet> {
  late String _keyword;
  List<_LyricHit> _hits = const <_LyricHit>[];
  String _applyingId = '';
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _keyword = widget.initialKeyword;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _search();
    });
  }

  Future<void> _search() async {
    final query = _keyword.trim();
    if (query.isEmpty) {
      ToastUtil.show('input_please'.tr);
      return;
    }
    setState(() {
      _loading = true;
      _hits = const <_LyricHit>[];
    });
    try {
      final found = await _LyricLookupApi.instance.search(query);
      if (!mounted) return;
      setState(() => _hits = found);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _apply(_LyricHit hit) async {
    final lrc = hit.lrc.trim();
    if (lrc.isEmpty) {
      ToastUtil.show('operation_failed'.tr);
      return;
    }
    setState(() => _applyingId = hit.id);
    try {
      final ok = await _LyricLookupApi.instance.write(
        musicPath: widget.musicPath,
        lrc: lrc,
      );
      if (!ok) {
        ToastUtil.show('operation_failed'.tr);
        return;
      }
      MusicPlayServiceController.instance.applyLyricOverride(
        widget.musicPath,
        lrc,
      );
      if (!mounted) return;
      Navigator.of(context).pop(lrc);
      ToastUtil.show('operation_success'.tr);
    } finally {
      if (mounted) setState(() => _applyingId = '');
    }
  }

  Widget _searchField() {
    return TextFormField(
      initialValue: _keyword,
      autofocus: true,
      textInputAction: TextInputAction.search,
      onChanged: (value) => _keyword = value,
      onFieldSubmitted: (_) => _search(),
      decoration: InputDecoration(
        hintText: 'search'.tr,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(12)),
        ),
        prefixIcon: const Icon(Icons.search),
        suffixIcon: IconButton(
          tooltip: 'search'.tr,
          onPressed: _loading ? null : _search,
          icon: const Icon(Icons.search),
        ),
      ),
    );
  }

  Widget _hitTile(ThemeData theme, _LyricHit hit) {
    final closeEnoughDuration =
        hit.durationMs > 0 &&
        (hit.durationMs - widget.trackDuration.inMilliseconds).abs() <= 5000;
    final fileStem = ColaMusicStageLyricSearch._squash(
      ColaMusicStageLyricSearch._stemOf(widget.musicPath),
    );
    final hitTitle = ColaMusicStageLyricSearch._squash(hit.title);
    final nameMatches =
        hitTitle.isNotEmpty &&
        fileStem.isNotEmpty &&
        fileStem.contains(hitTitle);
    final highMatch = closeEnoughDuration && nameMatches;

    final meta = <String>[
      if (hit.artist.trim().isNotEmpty) hit.artist.trim(),
      if (hit.album.trim().isNotEmpty) hit.album.trim(),
      if (hit.durationMs > 0) FormatUtil.formatDuration(hit.duration),
    ].join(' · ');
    final applying = _applyingId == hit.id;
    final mutedStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10.0, vertical: 6.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    if (highMatch) _matchBadge(theme),
                    if (highMatch) const SizedBox(width: 8.0),
                    Expanded(
                      child: Text(
                        hit.title.trim().isEmpty ? hit.id : hit.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                if (meta.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(0, 2, 0, 0),
                    child: Text(
                      meta,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: mutedStyle,
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(0, 2, 0, 0),
                  child: Tooltip(
                    message: hit.lrc.trim(),
                    waitDuration: const Duration(milliseconds: 250),
                    child: Text(
                      hit.previewLine.trim().isEmpty
                          ? '\u00A0'
                          : hit.previewLine.trim(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: mutedStyle,
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
              onPressed: applying ? null : () => _apply(hit),
              child: applying
                  ? const SizedBox(
                      width: 16.0,
                      height: 16.0,
                      child: CircularProgressIndicator(strokeWidth: 2.0),
                    )
                  : Text('select'.tr),
            ),
          ),
        ],
      ),
    );
  }

  Widget _matchBadge(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6.0, vertical: 2.0),
      decoration: BoxDecoration(
        border: Border.all(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
        ),
        borderRadius: BorderRadius.all(Radius.circular(6)),
      ),
      child: Text(
        '高匹配度',
        style: theme.textTheme.bodySmall?.copyWith(
          fontSize: 11.0,
          height: 1.2,
          color: theme.colorScheme.onSurface.withValues(alpha: 0.85),
        ),
      ),
    );
  }

  Widget _results(ThemeData theme) {
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 22.0,
          height: 22.0,
          child: CircularProgressIndicator(strokeWidth: 2.0),
        ),
      );
    }
    if (_hits.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(0, 26, 0, 26),
        child: Center(child: Text('no_data'.tr)),
      );
    }
    return ListView.separated(
      itemCount: _hits.length,
      separatorBuilder: (_, _) => const Divider(height: 1.0),
      itemBuilder: (_, index) => _hitTile(theme, _hits[index]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return DialogUtil.createAlertDialog(
      title: Row(
        children: <Widget>[
          Expanded(child: Text('music_search_lyric'.tr)),
          IconButton(
            onPressed: () => Navigator.of(context).pop(),
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
            _searchField(),
            const SizedBox(height: 8.0),
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 420),
                child: _results(theme),
              ),
            ),
          ],
        ),
      ),
      constraints: const BoxConstraints(maxWidth: 780, minWidth: 540),
    );
  }
}
