import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_media/nas_media.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import 'photo_viewer_page.dart';

/// 时光对照：同一个「月-日」在不同年份的照片并排看。
///
/// 直接复用 `/photo/on-this-day`（服务端已按年份分组），不新增后端接口。
/// 既有实现是「CLIP 找同地点不同年份的相似构图」，这里用同月同日做可解释的
/// 规则版：用户能自己选日期，且每一对都能说清「为什么被放在一起」。
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

  MediaUrls get _media => MediaUrls(ApiSession.instance.baseUrl);

  String _thumb(String path, {int size = 320}) => _media.thumbnail(path, size: size);

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
      final res = await ApiSession.instance.client.photoOnThisDay(
        month: _month,
        day: _day,
        perYear: 120,
      );
      if (!mounted) return;
      setState(() {
        _years = res.years.where((y) => y.items.isNotEmpty).toList();
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
    final latest = _years.first;
    final earliest = _years.last;
    final gap = latest.year - earliest.year;
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
              Text(
                tr('photo.timeContrast.gap', {'count': '$gap'}),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              Text(
                '${_month.toString().padLeft(2, '0')}-${_day.toString().padLeft(2, '0')}',
                style: TextStyle(fontSize: 12, color: context.nasTextSecondary),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _contrastTile(
                  earliest,
                  tr('photo.timeContrast.earliest'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _contrastTile(
                  latest,
                  tr('photo.timeContrast.latest'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _contrastTile(PhotoOnThisDayYear year, String label) {
    final item = year.items.first;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: () => _open(year.items, 0, '${year.year}'),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(NasTokens.radiusSm),
            child: AspectRatio(
              aspectRatio: 1,
              child: NasCoverImage(
                url: _thumb(item.path, size: 640),
                headers: ApiSession.instance.authHeaders,
                cacheWidth: 640,
                icon: Icons.broken_image_outlined,
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text('$label · ${year.year}', style: const TextStyle(fontSize: 12)),
        Text(
          tr('photo.count', {'count': '${year.photoCount}'}),
          style: TextStyle(fontSize: 11, color: context.nasTextSecondary),
        ),
      ],
    );
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
