import 'dart:math';

import 'package:flutter/material.dart';

import '../../../compat/cola_api_controller.dart';
import '../../../compat/base_components.dart';
import '../../../list/models/cola_list_models.dart';

/// 歌单卡片的四宫格封面。
///
/// 封面来源优先级：内嵌封面接口 → 流派随机占位图 → 默认封面。
/// 路径解析与占位图规则集中在这里，卡片本身不再关心图片从哪来。
class PlayListCoverGrid extends StatelessWidget {
  const PlayListCoverGrid({super.key, required this.previews});

  final List<dynamic> previews;

  static const int _maxTiles = 4;
  static const String _placeholder = 'assets/music/icons/default_cover.jpg';
  static const Set<String> _genreAssets = <String>{
    'blues',
    'classical',
    'country',
    'gospel',
    'hiphop',
    'pop',
    'rock',
  };

  @override
  Widget build(BuildContext context) {
    final tiles = previews.take(_maxTiles).toList(growable: false);
    if (tiles.isEmpty) return _defaultCover();

    final row = <Widget>[];
    for (var i = 0; i < tiles.length; i++) {
      row.add(Expanded(child: _CoverTile(model: tiles[i])));
      if (i != tiles.length - 1) row.add(const SizedBox(width: 1));
    }
    return Row(children: row);
  }

  static Widget _defaultCover() => Image.asset(
    _placeholder,
    fit: BoxFit.cover,
    width: double.infinity,
    height: double.infinity,
  );
}

class _CoverTile extends StatelessWidget {
  const _CoverTile({required this.model});

  final dynamic model;

  @override
  Widget build(BuildContext context) {
    if (_innerCoverFlag(model) != 1) return _fallback(context, model);
    final path = _coverPath(model);
    if (path.isEmpty) return _fallback(context, model);

    final url = ApiController.instance.getMusicCoverUrl(
      filePath: path,
      size: 500,
    );
    if (url.isEmpty) return _fallback(context, model);

    return CustomExtendedImage(
      width: double.infinity,
      showLoading: false,
      imageUrl: url,
      height: double.infinity,
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => _fallback(context, model),
      borderRadius: 0,
    );
  }

  static int _innerCoverFlag(dynamic m) {
    if (m is MusicListItem) return m.hasInnerCover;
    return (m.has_inner_cover as num?)?.toInt() ?? 0;
  }

  static String _coverPath(dynamic m) {
    final showType = (m.showType ?? m.show_type ?? '').toString().trim();
    if (showType.toLowerCase() == 'series') {
      return (m.firstFilePath ?? m.first_file_path ?? '').toString().trim();
    }

    final full = (m.fullPath ?? m.full_path ?? '').toString().trim();
    if (full.isNotEmpty) return full;
    final name = (m.filename ?? '').toString().trim();
    final base = (m.path ?? '').toString().trim();
    return base.isNotEmpty && name.isNotEmpty ? '$base/$name' : base;
  }

  static Widget _fallback(BuildContext context, dynamic m) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest
          .withValues(alpha: 0.4),
      child: Image.asset(
        _genreAsset(m),
        width: double.infinity,
        height: double.infinity,
        fit: BoxFit.cover,
      ),
    );
  }

  static String _genreAsset(dynamic m) {
    final genre = (m.genre ?? '').toString().trim().toLowerCase();
    final segments = genre.split(RegExp(r'[\/,;|]')).map((part) => part.trim());
    final head = segments.isEmpty ? '' : segments.first;
    final random = Random((m.id as int?) ?? 0);
    final normalized = head.replaceAll(RegExp(r'[^a-z0-9]'), '');

    if (normalized.isNotEmpty &&
        PlayListCoverGrid._genreAssets.contains(normalized)) {
      return 'assets/music/musicCover/$normalized${random.nextInt(6) + 1}.jpg';
    }
    return 'assets/music/musicCover/other${random.nextInt(20) + 1}.jpg';
  }
}
