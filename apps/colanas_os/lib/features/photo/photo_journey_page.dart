import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_media/nas_media.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import 'photo_panel.dart';

/// 旅程回放：把有 GPS 的照片按拍摄时间串成段，选中一段后按时间顺序自动播放。
///
/// 数据直接来自 `/photo/map/journey`（足迹地图已经在用），这里只做「段列表 +
/// 时间线回放」，不加载地图，避免和足迹页抢同一套地图状态。
class PhotoJourneyPage extends StatefulWidget {
  const PhotoJourneyPage({super.key});

  @override
  State<PhotoJourneyPage> createState() => _PhotoJourneyPageState();
}

class _PhotoJourneyPageState extends State<PhotoJourneyPage> {
  static const _speedSeconds = 2;

  bool _loading = true;
  String? _error;
  PhotoMapJourneyResponse? _journey;
  int _segment = 0;
  int _index = 0;
  bool _playing = false;
  Timer? _timer;

  ApiClient get _client => ApiSession.instance.client;

  MediaUrls get _media => MediaUrls(ApiSession.instance.baseUrl);

  List<PhotoMapJourneyPoint> get _points {
    final j = _journey;
    if (j == null || j.segments.isEmpty || _segment >= j.segments.length) return const [];
    return j.segments[_segment].points;
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    _timer?.cancel();
    setState(() {
      _loading = true;
      _error = null;
      _playing = false;
    });
    try {
      final res = await _client.photoMapJourney(gapHours: 12, maxPoints: 600);
      if (!mounted) return;
      setState(() {
        _journey = res;
        _segment = 0;
        _index = 0;
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

  void _stop() {
    _timer?.cancel();
    _timer = null;
    if (_playing) setState(() => _playing = false);
  }

  void _select(int i) {
    _stop();
    setState(() {
      _segment = i;
      _index = 0;
    });
  }

  void _step(int delta) {
    final n = _points.length;
    if (n == 0) return;
    _stop();
    setState(() => _index = (_index + delta).clamp(0, n - 1));
  }

  void _togglePlay() {
    if (_playing) {
      _stop();
      return;
    }
    final n = _points.length;
    if (n == 0) return;
    if (_index >= n - 1) setState(() => _index = 0);
    setState(() => _playing = true);
    _timer = Timer.periodic(const Duration(seconds: _speedSeconds), (_) {
      if (!mounted) return;
      if (_index >= _points.length - 1) {
        _stop();
        return;
      }
      setState(() => _index += 1);
    });
  }

  String _date(int sec) {
    if (sec <= 0) return '-';
    final d = DateTime.fromMillisecondsSinceEpoch(sec * 1000);
    String p(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${p(d.month)}-${p(d.day)} ${p(d.hour)}:${p(d.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const NasLoading();
    if (_error != null) return NasErrorState(message: _error!, onRetry: _load);
    final j = _journey;
    if (j == null || j.segments.isEmpty) {
      return NasEmptyState(
        title: tr('photo.journey.empty'),
        message: tr('photo.journey.emptyHint'),
        icon: Icons.travel_explore_outlined,
      );
    }
    return ListView(
      padding: const EdgeInsets.all(NasTokens.spaceLg),
      children: [
        _header(),
        const SizedBox(height: NasTokens.spaceLg),
        PhotoPanel(
          title: tr('photo.journey.title'),
          child: Wrap(
            spacing: 18,
            runSpacing: 12,
            children: [
              _stat(tr('photo.journey.points'), '${j.points}'),
              _stat(tr('photo.journey.distance'), '${j.distanceKm} km'),
              _stat(tr('photo.journey.days'), '${j.days}'),
              _stat(tr('photo.journey.segments'), '${j.segments.length}'),
            ],
          ),
        ),
        const SizedBox(height: NasTokens.spaceLg),
        PhotoPanel(
          title: tr('photo.journey.segments'),
          // 真机实测有 212 段：Wrap 会一次性把 212 个 ChoiceChip 全构建出来，
          // 改横向 ListView 懒加载，段数再多也不卡首帧。
          child: SizedBox(
            height: 38,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: j.segments.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, i) => ChoiceChip(
                label: Text(tr('photo.journey.segment', {'index': '${i + 1}'})),
                selected: i == _segment,
                onSelected: (_) => _select(i),
              ),
            ),
          ),
        ),
        const SizedBox(height: NasTokens.spaceLg),
        _player(),
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
            tr('photo.journey.title'),
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            tr('photo.journey.hint'),
            style: TextStyle(fontSize: NasTokens.fontCaption, color: context.nasTextSecondary),
          ),
        ],
      ),
    );
  }

  Widget _stat(String label, String value) {
    return SizedBox(
      width: 128,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text(label, style: TextStyle(fontSize: 11, color: context.nasTextSecondary)),
        ],
      ),
    );
  }

  Widget _player() {
    final points = _points;
    final seg = _journey!.segments[_segment];
    final point = points.isEmpty ? null : points[_index.clamp(0, points.length - 1)];
    return PhotoPanel(
      title: '${tr('photo.journey.segment', {'index': '${_segment + 1}'})} · '
          '${_date(seg.startAt)} → ${_date(seg.endAt)}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(NasTokens.radiusSm),
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: point == null
                  ? const Center(child: Icon(Icons.image_outlined, size: 48))
                  : NasCoverImage(
                      url: _media.thumbnail(point.path, size: 1024),
                      headers: ApiSession.instance.authHeaders,
                      cacheWidth: 1024,
                      icon: Icons.broken_image_outlined,
                    ),
            ),
          ),
          const SizedBox(height: 10),
          if (point != null)
            Text(
              '${_date(point.takenAt)} · '
              '${point.latitude.toStringAsFixed(4)}, ${point.longitude.toStringAsFixed(4)}',
              style: TextStyle(fontSize: 12, color: context.nasTextSecondary),
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              IconButton(
                tooltip: tr('photo.journey.prev'),
                onPressed: () => _step(-1),
                icon: const Icon(Icons.skip_previous),
              ),
              IconButton(
                tooltip: _playing ? tr('photo.journey.pause') : tr('photo.journey.play'),
                onPressed: _togglePlay,
                icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
              ),
              IconButton(
                tooltip: tr('photo.journey.next'),
                onPressed: () => _step(1),
                icon: const Icon(Icons.skip_next),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: LinearProgressIndicator(
                  value: points.isEmpty ? 0 : (_index + 1) / points.length,
                  minHeight: 4,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                '${points.isEmpty ? 0 : _index + 1}/${points.length}',
                style: TextStyle(fontSize: 12, color: context.nasTextSecondary),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            tr('photo.journey.speed', {'seconds': '$_speedSeconds'}),
            style: TextStyle(fontSize: 11, color: context.nasTextSecondary),
          ),
          const SizedBox(height: 4),
          Text(
            tr('photo.journey.noMap'),
            style: TextStyle(fontSize: 11, color: context.nasTextSecondary),
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: () {
              _stop();
              setState(() => _index = 0);
            },
            icon: const Icon(Icons.replay, size: 16),
            label: Text(tr('photo.journey.replay')),
          ),
        ],
      ),
    );
  }
}
