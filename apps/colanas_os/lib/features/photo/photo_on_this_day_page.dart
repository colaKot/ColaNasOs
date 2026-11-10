import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_media/nas_media.dart';
import 'package:nas_ui/nas_ui.dart';
import '../../shell/app_widgets.dart';
import '../../shell/mobile_frame.dart';

import '../../core/session.dart';
import 'photo_viewer_page.dart';

/// 那年今日：按年份列出「同月同日」的照片。
///
/// 首页的 3 列只是最近几年的入口；点任意卡片都进这里看**所有年份**。
class PhotoOnThisDayPage extends StatefulWidget {
  const PhotoOnThisDayPage({super.key, this.embedded = false});

  final bool embedded;

  @override
  State<PhotoOnThisDayPage> createState() => _PhotoOnThisDayPageState();
}

class _PhotoOnThisDayPageState extends State<PhotoOnThisDayPage> {
  bool _loading = true;
  String? _error;
  List<PhotoOnThisDayYear> _years = const [];

  MediaUrls get _media => MediaUrls(ApiSession.instance.baseUrl);

  String _thumb(String path) => _media.thumbnail(path, size: 320);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ApiSession.instance.client.photoOnThisDay(perYear: 120);
      if (!mounted) return;
      setState(() {
        _years = res.years;
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

  String _titleOf(PhotoOnThisDayYear year) {
    final parts = year.date.split('-');
    if (parts.length != 3) return year.date;
    final month = int.tryParse(parts[1]) ?? 0;
    final day = int.tryParse(parts[2]) ?? 0;
    return '${parts[0]}年$month月$day日';
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
    // 与「全部」视图对齐：手机端一行 3 个。以前写死 6 列，390 宽的屏上
    // 每格只有 ~55dp，连人脸都看不清（2026-11-07 反馈）。
    final columns = isCompactWidth(context) ? 3 : 6;
    return Scaffold(
      appBar: widget.embedded
          ? null
          : AppBar(
              title: Text(tr('photo.onThisDay.title')),
              actions: [
                NasRefreshButton(onPressed: _load),
              ],
            ),
      body: _loading
          ? const NasLoading()
          : _error != null
          ? NasErrorState(message: _error!, onRetry: _load)
          : _years.isEmpty
          ? NasEmptyState(
              title: tr('photo.onThisDay.empty'),
              message: tr('photo.onThisDay.emptyHint'),
              icon: Icons.today_outlined,
            )
          : ListView(
              padding: const EdgeInsets.all(NasTokens.spaceSm),
              children: [
                for (final year in _years) ...[
                  Row(
                    children: [
                      Text(
                        _titleOf(year),
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        tr('photo.count', {'count': '${year.photoCount}'}),
                        style: TextStyle(
                          fontSize: NasTokens.fontCaption,
                          color: context.nasTextSecondary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: NasTokens.spaceSm),
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate:
                        SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: columns,
                          crossAxisSpacing: 3,
                          mainAxisSpacing: 3,
                        ),
                    itemCount: year.items.length,
                    itemBuilder: (context, i) {
                      final item = year.items[i];
                      return InkWell(
                        onTap: () => _open(year.items, i, _titleOf(year)),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(
                            NasTokens.radiusSm,
                          ),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              NasCoverImage(
                                url: _thumb(item.path),
                                headers: ApiSession.instance.authHeaders,
                                cacheWidth: 320,
                                icon: Icons.broken_image_outlined,
                              ),
                              Positioned(
                                left: 4,
                                bottom: 4,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 4,
                                    vertical: 1,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.black.withValues(alpha: 0.38),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    item.takenAt > 0
                                        ? _monthDay(item.takenAt)
                                        : '',
                                    style: const TextStyle(
                                      fontSize: 10,
                                      height: 1.1,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: NasTokens.spaceLg),
                ],
              ],
            ),
    );
  }
}

String _monthDay(int seconds) {
  final d = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
  return '${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}