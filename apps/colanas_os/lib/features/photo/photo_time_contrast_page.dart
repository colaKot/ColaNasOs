import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_media/nas_media.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import 'photo_viewer_page.dart';

/// 时光对照：同一个「月-日」在不同年份的照片并排看。
///
/// 年份列表复用 `/photo/on-this-day`；「为什么是这两张」由
/// `/photo/time-contrast` 负责：优先锁定同一个人脸簇（同一个人），找不到时
/// 明确降级到同一相册 / 画面相似度 / 纯时间跨度，并把原因显示在卡片上。
/// 每一侧还会展示照片里识别到的人脸头像（最多前三张，按面积 × 清晰度）。
class PhotoTimeContrastPage extends StatefulWidget {
  const PhotoTimeContrastPage({super.key});

  @override
  State<PhotoTimeContrastPage> createState() => _PhotoTimeContrastPageState();
}

class _PhotoTimeContrastPageState extends State<PhotoTimeContrastPage> {
  late int _month;
  late int _day;
  bool _loading = true;
  String? _error;
  List<PhotoOnThisDayYear> _years = const [];
  PhotoTimeContrastResponse? _contrast;

  MediaUrls get _media => MediaUrls(ApiSession.instance.baseUrl);

  String _thumb(String path, {int size = 320}) => _media.thumbnail(path, size: size);

  String _faceUrl(String id, {int size = 72}) =>
      '${ApiSession.instance.baseUrl}/api/v1/photo/face/image'
      '?id=${Uri.encodeComponent(id)}&size=$size';

  PhotoTimeContrastSide? _side(dynamic v) => v is Map
      ? PhotoTimeContrastSide.fromJson(Map<String, dynamic>.from(v))
      : null;

  PhotoTimeContrastPerson? _person(dynamic v) => v is Map
      ? PhotoTimeContrastPerson.fromJson(Map<String, dynamic>.from(v))
      : null;

  PhotoTimeContrastAlbum? _album(dynamic v) => v is Map
      ? PhotoTimeContrastAlbum.fromJson(Map<String, dynamic>.from(v))
      : null;

  /// 人物展示名：优先人工命名，其次把人脸簇 id 缩短后作为「人物 xxxx」。
  String _personLabel(PhotoTimeContrastPerson? p) {
    final name = p?.name?.trim();
    if (name != null && name.isNotEmpty) return name;
    if (p == null) return tr('photo.timeContrast.unknownTarget');
    final id = p.id.length > 6 ? p.id.substring(0, 6) : p.id;
    return tr('photo.timeContrast.unnamedPerson', {'id': id});
  }

  String _faceName(PhotoTimeContrastFace f) {
    final name = f.name?.trim();
    return name != null && name.isNotEmpty
        ? name
        : tr('photo.timeContrast.unnamed');
  }

  String _faceNames(PhotoTimeContrastSide side) {
    if (side.faces.isEmpty) return tr('photo.timeContrast.noFace');
    final names = side.faces.map(_faceName).join(' · ');
    final extra = side.faceCount - side.faces.length;
    if (extra <= 0) return names;
    return '$names · ${tr('photo.timeContrast.moreFaces', {'count': '$extra'})}';
  }

  String _fallbackReason(
    PhotoTimeContrastResponse c,
    PhotoTimeContrastAlbum? album,
  ) {
    switch (c.reason) {
      case 'same_album':
        if (album != null) {
          return tr('photo.timeContrast.fallbackAlbum', {'album': album.name});
        }
        return tr('photo.timeContrast.fallbackTime');
      case 'similar':
        return tr('photo.timeContrast.fallbackSimilar');
      default:
        return tr('photo.timeContrast.fallbackTime');
    }
  }

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _month = now.month;
    _day = now.day;
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final client = ApiSession.instance.client;
      // 年份列表与配对信息互不依赖，一起发；配对接口失败也不该让整页空掉
      final pairFuture = client.photoTimeContrast(
        month: _month,
        day: _day,
      ).then<PhotoTimeContrastResponse?>((v) => v, onError: (_) => null);
      final res = await client.photoOnThisDay(
        month: _month,
        day: _day,
        perYear: 120,
      );
      final pair = await pairFuture;
      if (!mounted) return;
      setState(() {
        _years = res.years.where((y) => y.items.isNotEmpty).toList();
        _contrast = pair;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  void _open(List<PhotoItem> items, int index, String title) {
    if (items.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PhotoViewerPage(
          items: items,
          initialIndex: index,
          title: title,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(NasTokens.spaceLg),
      children: [
        _header(),
        const SizedBox(height: NasTokens.spaceLg),
        if (_loading)
          const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_error != null)
          NasErrorState(message: _error!, onRetry: _load)
        else if (_years.length < 2)
          NasEmptyState(
            title: tr('photo.timeContrast.empty'),
            message: tr('photo.timeContrast.emptyHint'),
            icon: Icons.history,
          )
        else ...[
          _contrastCard(),
          const SizedBox(height: NasTokens.spaceLg),
          Text(
            tr('photo.timeContrast.span', {'count': '${_years.length}'}),
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: NasTokens.spaceSm),
          for (final year in _years) ...[
            _yearRow(year),
            const SizedBox(height: NasTokens.spaceLg),
          ],
        ],
      ],
    );
  }

  Widget _header() {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tr('photo.timeContrast.title'),
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            tr('photo.timeContrast.hint'),
            style: TextStyle(fontSize: NasTokens.fontCaption, color: context.nasTextSecondary),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(tr('photo.timeContrast.pickDate')),
              DropdownButton<int>(
                value: _month,
                items: [
                  for (var m = 1; m <= 12; m++)
                    DropdownMenuItem(value: m, child: Text('$m')),
                ],
                onChanged: (v) {
                  if (v == null) return;
                  setState(() => _month = v);
                  _load();
                },
              ),
              DropdownButton<int>(
                value: _day,
                items: [
                  for (var d = 1; d <= 31; d++)
                    DropdownMenuItem(value: d, child: Text('$d')),
                ],
                onChanged: (v) {
                  if (v == null) return;
                  setState(() => _day = v);
                  _load();
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _contrastCard() {
    final c = _contrast;
    final left = c == null ? null : _side(c.left);
    final right = c == null ? null : _side(c.right);
    if (c == null || left == null || right == null) {
      return _pairHint(tr('photo.timeContrast.noPair'));
    }

    final person = _person(c.person);
    final album = _album(c.album);
    final isPerson = c.mode == 'person';
    final target = isPerson
        ? _personLabel(person)
        : tr('photo.timeContrast.unknownTarget');
    final reason = isPerson
        ? tr('photo.timeContrast.samePerson')
        : _fallbackReason(c, album);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isPerson ? Icons.person_search_outlined : Icons.info_outline,
                size: 18,
                color: isPerson ? Theme.of(context).colorScheme.primary : context.nasTextSecondary,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '${tr('photo.timeContrast.target')}：$target',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                tr('photo.timeContrast.gap', {'count': '${c.gapYears}'}),
                style: TextStyle(fontSize: 12, color: context.nasTextSecondary),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            reason,
            style: TextStyle(
              fontSize: 12,
              color: isPerson
                  ? Theme.of(context).colorScheme.primary
                  : context.nasTextSecondary,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _contrastTile(
                  left,
                  tr('photo.timeContrast.earliest'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _contrastTile(
                  right,
                  tr('photo.timeContrast.latest'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _pairHint(String text) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 18, color: context.nasTextSecondary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 12, color: context.nasTextSecondary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _contrastTile(PhotoTimeContrastSide side, String label) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: () => _openSide(side),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(NasTokens.radiusSm),
            child: AspectRatio(
              aspectRatio: 1,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  NasCoverImage(
                    url: _thumb(side.item.path, size: 640),
                    headers: ApiSession.instance.authHeaders,
                    cacheWidth: 640,
                    icon: Icons.broken_image_outlined,
                  ),
                  if (side.faces.isNotEmpty)
                    Positioned(
                      left: 6,
                      bottom: 6,
                      child: _faceStrip(side),
                    ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '$label · ${side.year}',
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
        ),
        const SizedBox(height: 2),
        Text(
          _faceNames(side),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 11, color: context.nasTextSecondary),
        ),
      ],
    );
  }

  /// 照片左下角的头像条：最多三个，再多人用 +N 表示。
  Widget _faceStrip(PhotoTimeContrastSide side) {
    final extra = side.faceCount - side.faces.length;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final f in side.faces) ...[
            Tooltip(
              message: _faceName(f),
              child: Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white70, width: 1.2),
                ),
                child: ClipOval(
                  child: Image.network(
                    _faceUrl(f.id),
                    headers: ApiSession.instance.authHeaders,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const ColoredBox(
                      color: Color(0x33000000),
                      child: Icon(Icons.person, size: 15, color: Colors.white70),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),
          ],
          if (extra > 0)
            Text(
              '+$extra',
              style: const TextStyle(fontSize: 11, color: Colors.white),
            ),
        ],
      ),
    );
  }

  void _openSide(PhotoTimeContrastSide side) {
    var items = <PhotoItem>[side.item];
    var index = 0;
    for (final y in _years) {
      if (y.year != side.year) continue;
      final i = y.items.indexWhere((it) => it.id == side.item.id);
      if (i >= 0) {
        items = y.items;
        index = i;
      }
      break;
    }
    _open(items, index, '${side.year}');
  }

  Widget _yearRow(PhotoOnThisDayYear year) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '${year.year}',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            const Spacer(),
            Text(
              tr('photo.count', {'count': '${year.photoCount}'}),
              style: TextStyle(fontSize: 12, color: context.nasTextSecondary),
            ),
          ],
        ),
        const SizedBox(height: 6),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 6,
            crossAxisSpacing: 3,
            mainAxisSpacing: 3,
          ),
          itemCount: year.items.length > 6 ? 6 : year.items.length,
          itemBuilder: (context, i) => InkWell(
            onTap: () => _open(year.items, i, '${year.year}'),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(NasTokens.radiusSm),
              child: NasCoverImage(
                url: _thumb(year.items[i].path),
                headers: ApiSession.instance.authHeaders,
                cacheWidth: 320,
                icon: Icons.broken_image_outlined,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
