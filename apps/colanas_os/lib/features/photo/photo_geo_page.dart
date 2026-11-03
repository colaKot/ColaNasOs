import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_media/nas_media.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/map_tiles.dart';
import '../../core/session.dart';
import 'photo_viewer_page.dart';

/// GPS 补全：向导式工作台（一批一组）。
///
/// 顶部给本批进度与操作；中间是待补照片横条（默认全选、可逐张取消）；
/// 下面是参考照片 + 地图选点；最后是视觉候选（CLIP 相似锚点，需用户确认）。
class PhotoGeoPage extends StatefulWidget {
  const PhotoGeoPage({super.key});

  @override
  State<PhotoGeoPage> createState() => _PhotoGeoPageState();
}

class _PhotoGeoPageState extends State<PhotoGeoPage> {
  static const _batchSize = 20;

  bool _loading = true;
  String? _error;
  List<PhotoItem> _queue = const [];
  final Set<String> _selected = <String>{};
  List<PhotoGeoReference> _references = const [];
  PhotoGeoVisionList? _vision;
  PhotoGeoVisionStatus? _visionStatus;
  bool _visionBusy = false;
  bool _applying = false;

  double? _lat;
  double? _lng;

  final MapController _map = MapController();
  Timer? _poll;

  MediaUrls get _media => MediaUrls(ApiSession.instance.baseUrl);

  String _thumb(String path, {int size = 320}) => _media.thumbnail(path, size: size);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        ApiSession.instance.client.photoGeoMissing(limit: 120),
        ApiSession.instance.client.photoGeoReferences(limit: 20),
        ApiSession.instance.client.photoGeoVisionCandidates(limit: 30),
        ApiSession.instance.client.photoGeoVisionStatus(),
      ]);
      final missing = results[0] as PhotoTimelineResponse;
      if (!mounted) return;
      setState(() {
        _queue = missing.items;
        _selected
          ..clear()
          ..addAll(missing.items.take(_batchSize).map((e) => e.id));
        _references = (results[1] as PhotoGeoReferenceList).items;
        _vision = results[2] as PhotoGeoVisionList;
        _visionStatus = results[3] as PhotoGeoVisionStatus;
        _loading = false;
        final ref = _references.isNotEmpty ? _references.first : null;
        _lat ??= ref?.latitude;
        _lng ??= ref?.longitude;
      });
      if (_references.isNotEmpty && _lat != null && _lng != null) {
        _map.move(LatLng(_lat!, _lng!), 9);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  List<PhotoItem> get _batch => _queue.take(_batchSize).toList();

  Future<void> _apply() async {
    final lat = _lat;
    final lng = _lng;
    if (lat == null || lng == null || _selected.isEmpty || _applying) return;
    setState(() => _applying = true);
    try {
      await ApiSession.instance.client.photoGeoSet(
        body: PhotoGeoSetBody(
          ids: _selected.toList(),
          latitude: lat,
          longitude: lng,
        ),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('photo.geo.batchDone', {'count': '${_selected.length}'}))),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  Future<void> _skip() async {
    if (_queue.length <= _batchSize) {
      await _load();
      return;
    }
    setState(() {
      _queue = _queue.skip(_batchSize).toList();
      _selected
        ..clear()
        ..addAll(_queue.take(_batchSize).map((e) => e.id));
    });
  }

  void _pickReference(PhotoGeoReference ref) {
    setState(() {
      _lat = ref.latitude;
      _lng = ref.longitude;
    });
    _map.move(LatLng(ref.latitude, ref.longitude), 10);
  }

  Future<void> _scanVision() async {
    if (_visionBusy) return;
    setState(() => _visionBusy = true);
    try {
      await ApiSession.instance.client.photoGeoVisionScan();
      _poll?.cancel();
      _poll = Timer.periodic(const Duration(seconds: 2), (timer) async {
        final status = await ApiSession.instance.client.photoGeoVisionStatus();
        if (!mounted) { timer.cancel(); return; }
        setState(() => _visionStatus = status);
        if (!status.running) {
          timer.cancel();
          final list = await ApiSession.instance.client.photoGeoVisionCandidates(limit: 30);
          if (!mounted) return;
          setState(() {
            _vision = list;
            _visionBusy = false;
          });
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _visionBusy = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _confirmVision(PhotoGeoVisionCandidate item) async {
    final point = await showDialog<LatLng>(
      context: context,
      builder: (_) => _GpsPickerDialog(
        initial: LatLng(item.latitude, item.longitude),
        photoPath: item.path,
        thumbUrl: _thumb(item.path),
        headers: ApiSession.instance.authHeaders,
      ),
    );
    if (point == null) return;
    try {
      await ApiSession.instance.client.photoGeoVisionApply(
        body: PhotoGeoVisionApplyBody(
          id: item.id,
          latitude: point.latitude,
          longitude: point.longitude,
        ),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _rejectVision(PhotoGeoVisionCandidate item) async {
    try {
      await ApiSession.instance.client.photoGeoVisionReject(
        body: PhotoGeoVisionRejectBody(id: item.id),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  void _openViewer(List<PhotoItem> items, int index) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PhotoViewerPage(items: items, initialIndex: index),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const NasLoading();
    if (_error != null) return NasErrorState(message: _error!, onRetry: _load);
    final batch = _batch;
    if (batch.isEmpty && _references.isEmpty && (_vision?.items.isEmpty ?? true)) {
      return ListView(
        padding: const EdgeInsets.all(24),
        children: [
          NasEmptyState(
            title: tr('photo.geo.allDone'),
            message: tr('photo.geo.allDoneHint'),
            icon: Icons.gps_fixed,
          ),
        ],
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      children: [
        _header(batch),
        if (batch.isNotEmpty) ...[
          const SizedBox(height: 14),
          _pendingSection(batch),
          const SizedBox(height: 14),
          _referenceSection(),
          const SizedBox(height: 14),
          _mapSection(),
        ],
        const SizedBox(height: 18),
        _visionSection(),
      ],
    );
  }

  Widget _header(List<PhotoItem> batch) {
    final status = _visionStatus;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tr('photo.geo.workbench'), style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 3),
              Text(
                batch.isEmpty
                    ? tr('photo.geo.noPending')
                    : tr('photo.geo.batchHint', {
                        'count': '${batch.length}',
                        'selected': '${_selected.length}',
                      }),
                style: TextStyle(fontSize: NasTokens.fontCaption, color: context.nasTextSecondary),
              ),
              if (status != null && status.running) ...[
                const SizedBox(height: 6),
                LinearProgressIndicator(
                  value: status.total <= 0 ? null : status.done / status.total,
                  minHeight: 4,
                ),
              ],
            ],
          ),
        ),
        IconButton(
          tooltip: tr('common.refresh'),
          onPressed: _load,
          icon: const Icon(Icons.refresh),
        ),
      ],
    );
  }

  Widget _sectionTitle(String title, String hint, {Widget? trailing}) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleSmall),
              Text(hint, style: TextStyle(fontSize: 11, color: context.nasTextSecondary)),
            ],
          ),
        ),
        ?trailing,
      ],
    );
  }

  Widget _card({required Widget child}) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.25)),
      ),
      child: child,
    );
  }

  Widget _pendingSection(List<PhotoItem> batch) {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle(tr('photo.geo.pending'), tr('photo.geo.pendingHint')),
          const SizedBox(height: 10),
          SizedBox(
            height: 150,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: batch.length,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (_, i) {
                final item = batch[i];
                final picked = _selected.contains(item.id);
                return SizedBox(
                  width: 118,
                  child: GestureDetector(
                    onTap: () => setState(() {
                      if (picked) {
                        _selected.remove(item.id);
                      } else {
                        _selected.add(item.id);
                      }
                    }),
                    onDoubleTap: () => _openViewer(batch, i),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: NasCoverImage(
                                  url: _thumb(item.path),
                                  headers: ApiSession.instance.authHeaders,
                                  cacheWidth: 240,
                                ),
                              ),
                              Positioned(
                                top: 4,
                                left: 4,
                                child: Icon(
                                  picked ? Icons.check_circle : Icons.radio_button_unchecked,
                                  size: 18,
                                  color: picked ? Theme.of(context).colorScheme.primary : Colors.white,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          formatDateTimeSec(item.takenAt),
                          style: TextStyle(fontSize: 10, color: context.nasTextSecondary),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _referenceSection() {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle(tr('photo.geo.references'), tr('photo.geo.referencesHint')),
          const SizedBox(height: 10),
          if (_references.isEmpty)
            Text(tr('photo.geo.noReference'), style: TextStyle(color: context.nasTextSecondary))
          else
            SizedBox(
              height: 96,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _references.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (_, i) {
                  final ref = _references[i];
                  final active = ref.latitude == _lat && ref.longitude == _lng;
                  return GestureDetector(
                    onTap: () => _pickReference(ref),
                    child: Container(
                      width: 96,
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        border: active
                            ? Border.all(
                                color: Theme.of(context).colorScheme.primary,
                                width: 2,
                              )
                            : null,
                      ),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          NasCoverImage(
                            url: _thumb(ref.path),
                            headers: ApiSession.instance.authHeaders,
                            cacheWidth: 200,
                          ),
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            child: Container(
                              color: Colors.black54,
                              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                              child: Text(
                                ref.place.isEmpty
                                    ? '${ref.latitude.toStringAsFixed(3)}, ${ref.longitude.toStringAsFixed(3)}'
                                    : ref.place,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: Colors.white, fontSize: 10),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _mapSection() {
    final lat = _lat;
    final lng = _lng;
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle(
            tr('photo.geo.map'),
            tr('photo.geo.mapHint'),
            trailing: Text(
              lat == null || lng == null
                  ? tr('photo.geo.noPoint')
                  : '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}',
              style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
            ),
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(
              height: 320,
              child: FlutterMap(
                mapController: _map,
                options: MapOptions(
                  initialCenter: LatLng(lat ?? 34.0, lng ?? 108.0),
                  initialZoom: 9,
                  minZoom: 2,
                  maxZoom: 18,
                  onTap: (_, point) => setState(() {
                    _lat = point.latitude;
                    _lng = point.longitude;
                  }),
                ),
                children: [
                  TileLayer(
                    urlTemplate: tileProxyTemplate(),
                    tileProvider: NetworkTileProvider(headers: tileProxyHeaders()),
                    userAgentPackageName: 'com.colanas.os',
                    maxNativeZoom: 19,
                  ),
                  MarkerLayer(
                    markers: [
                      for (final ref in _references)
                        Marker(
                          point: LatLng(ref.latitude, ref.longitude),
                          width: 24,
                          height: 24,
                          child: const Icon(Icons.place, color: Colors.orange, size: 22),
                        ),
                      if (lat != null && lng != null)
                        Marker(
                          point: LatLng(lat, lng),
                          width: 34,
                          height: 34,
                          child: Icon(
                            Icons.location_on,
                            color: Theme.of(context).colorScheme.error,
                            size: 32,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              OutlinedButton(
                onPressed: _skip,
                child: Text(tr('photo.geo.skip')),
              ),
              const Spacer(),
              FilledButton.icon(
                onPressed: _applying || _selected.isEmpty || lat == null || lng == null
                    ? null
                    : _apply,
                icon: _applying
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.gps_fixed, size: 16),
                label: Text(
                  _applying
                      ? tr('photo.geo.applying')
                      : tr('photo.geo.applyBatch', {'count': '${_selected.length}'}),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _visionSection() {
    final items = _vision?.items ?? const <PhotoGeoVisionCandidate>[];
    final status = _visionStatus;
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle(
            tr('photo.geo.vision'),
            tr('photo.geo.visionHint'),
            trailing: TextButton.icon(
              onPressed: _visionBusy ? null : _scanVision,
              icon: _visionBusy
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.auto_awesome, size: 16),
              label: Text(
                status != null && status.running
                    ? tr('photo.geo.visionRunning', {'count': '${status.done}/${status.total}'})
                    : tr('photo.geo.visionScan'),
              ),
            ),
          ),
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                tr('photo.geo.visionEmpty'),
                style: TextStyle(fontSize: 12, color: context.nasTextSecondary),
              ),
            )
          else
            SizedBox(
              height: 190,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: items.length,
                separatorBuilder: (_, _) => const SizedBox(width: 10),
                itemBuilder: (_, i) {
                  final item = items[i];
                  return SizedBox(
                    width: 180,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: NasCoverImage(
                                  url: _thumb(item.path),
                                  headers: ApiSession.instance.authHeaders,
                                  cacheWidth: 320,
                                ),
                              ),
                              Positioned(
                                top: 4,
                                right: 4,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: Colors.black54,
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    '${(item.similarity * 100).toStringAsFixed(0)}%',
                                    style: const TextStyle(color: Colors.white, fontSize: 10),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          item.anchorPath.split('/').last,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 10, color: context.nasTextSecondary),
                        ),
                        Row(
                          children: [
                            TextButton(
                              onPressed: () => _rejectVision(item),
                              child: Text(tr('photo.geo.visionReject')),
                            ),
                            const Spacer(),
                            FilledButton.tonal(
                              onPressed: () => _confirmVision(item),
                              child: Text(tr('photo.geo.visionConfirm')),
                            ),
                          ],
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _GpsPickerDialog extends StatefulWidget {
  const _GpsPickerDialog({
    required this.initial,
    required this.photoPath,
    required this.thumbUrl,
    required this.headers,
  });

  final LatLng initial;
  final String photoPath;
  final String thumbUrl;
  final Map<String, String> headers;

  @override
  State<_GpsPickerDialog> createState() => _GpsPickerDialogState();
}

class _GpsPickerDialogState extends State<_GpsPickerDialog> {
  late LatLng _point;
  final MapController _map = MapController();

  @override
  void initState() {
    super.initState();
    _point = widget.initial;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(tr('photo.geo.visionConfirmTitle')),
      content: SizedBox(
        width: 560,
        height: 420,
        child: Column(
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: FlutterMap(
                  mapController: _map,
                  options: MapOptions(
                    initialCenter: _point,
                    initialZoom: 13,
                    minZoom: 2,
                    maxZoom: 18,
                    onTap: (_, p) => setState(() => _point = p),
                  ),
                  children: [
                    TileLayer(
                      urlTemplate: tileProxyTemplate(),
                      tileProvider: NetworkTileProvider(headers: tileProxyHeaders()),
                      userAgentPackageName: 'com.colanas.os',
                      maxNativeZoom: 19,
                    ),
                    MarkerLayer(
                      markers: [
                        Marker(
                          point: _point,
                          width: 34,
                          height: 34,
                          child: Icon(
                            Icons.location_on,
                            color: Theme.of(context).colorScheme.error,
                            size: 32,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '${_point.latitude.toStringAsFixed(5)}, ${_point.longitude.toStringAsFixed(5)}',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('common.cancel')),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_point),
          child: Text(tr('common.ok')),
        ),
      ],
    );
  }
}