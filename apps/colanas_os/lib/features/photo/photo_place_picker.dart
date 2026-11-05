import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/gcj02.dart';
import '../../core/map_tiles.dart';
import '../../core/session.dart';

/// 地点选点：在地图上点一个圆心 + 选半径，回填成筛选条件里的 `place`。
///
/// 为什么需要它：`/photo/filter` 的 `place` 条件早就支持，但界面没有入口，
/// 用户没法表达"这一带拍的照片"。地图与照片坐标系不同（照片是 WGS-84，
/// 国内底图是 GCJ-02），选点时按当前底图的坐标系反解，否则整体偏几百米。
Future<PhotoSmartRulePlace?> showPhotoPlacePicker(
  BuildContext context, {
  PhotoSmartRulePlace? initial,
}) {
  return showDialog<PhotoSmartRulePlace>(
    context: context,
    builder: (_) => _PlacePickerDialog(initial: initial),
  );
}

class _PlacePickerDialog extends StatefulWidget {
  const _PlacePickerDialog({this.initial});

  final PhotoSmartRulePlace? initial;

  @override
  State<_PlacePickerDialog> createState() => _PlacePickerDialogState();
}

class _PlacePickerDialogState extends State<_PlacePickerDialog> {
  static const _radii = <double>[1, 5, 10, 50, 200];

  final MapController _map = MapController();
  LatLng? _point;
  double _radiusKm = 10;

  /// 当前底图坐标系：GCJ-02 时要把点击点反解回 WGS-84
  bool _gcj = false;

  @override
  void initState() {
    super.initState();
    final init = widget.initial;
    if (init != null) {
      _radiusKm = init.radiusKm ?? 10;
    }
    _loadServer();
  }

  Future<void> _loadServer() async {
    try {
      final res = await ApiSession.instance.client.photoMapTileServers();
      final current = res.items.where((s) => s.isCurrent);
      if (!mounted || current.isEmpty) return;
      setState(() => _gcj = current.first.coordinate == 'GCJ-02');
    } catch (_) {
      // 拿不到底图源：按 WGS-84 处理（默认源就是 WGS-84）
    }
  }

  /// 点击点 → 照片坐标系（WGS-84）
  LatLng _toPhotoCrs(LatLng p) {
    if (!_gcj) return p;
    final (lat, lng) = gcjToWgs(p.latitude, p.longitude);
    return LatLng(lat, lng);
  }

  /// 初始视野：已有条件就居中到该点，否则给一个能看清中国的视野
  LatLng get _center {
    final init = widget.initial;
    if (init == null) return const LatLng(34.0, 108.0);
    return _gcj
        ? () {
            final (lat, lng) = wgsToGcj(init.latitude, init.longitude);
            return LatLng(lat, lng);
          }()
        : LatLng(init.latitude, init.longitude);
  }

  @override
  Widget build(BuildContext context) {
    final picked = _point ?? (widget.initial == null ? null : _center);
    return AlertDialog(
      title: Text(tr('photo.placePicker.title')),
      content: SizedBox(
        width: 640,
        height: 460,
        child: Column(
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(NasTokens.radiusSm),
                child: FlutterMap(
                  mapController: _map,
                  options: MapOptions(
                    initialCenter: _center,
                    initialZoom: widget.initial == null ? 4 : 9,
                    minZoom: 2,
                    maxZoom: 18,
                    onTap: (_, point) => setState(() => _point = point),
                  ),
                  children: [
                    TileLayer(
                      urlTemplate: tileProxyTemplate(),
                      tileProvider: NetworkTileProvider(headers: tileProxyHeaders()),
                      userAgentPackageName: 'com.colanas.os',
                      maxNativeZoom: 19,
                    ),
                    if (picked != null)
                      MarkerLayer(
                        markers: [
                          Marker(
                            point: picked,
                            width: 36,
                            height: 36,
                            child: Icon(
                              Icons.place,
                              size: 36,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: NasTokens.spaceSm),
            Row(
              children: [
                Text(
                  tr('photo.placePicker.radius'),
                  style: TextStyle(
                    fontSize: NasTokens.fontCaption,
                    color: context.nasTextSecondary,
                  ),
                ),
                const SizedBox(width: NasTokens.spaceXs),
                for (final r in _radii)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: NasChip(
                      visualDensity: VisualDensity.compact,
                      label: Text('${r.toInt()}km'),
                      selected: _radiusKm == r,
                      onSelected: (_) => setState(() => _radiusKm = r),
                    ),
                  ),
                const Spacer(),
                if (picked != null)
                  Text(
                    '${_toPhotoCrs(picked).latitude.toStringAsFixed(4)}, '
                    '${_toPhotoCrs(picked).longitude.toStringAsFixed(4)}',
                    style: TextStyle(
                      fontSize: NasTokens.fontMicro,
                      color: context.nasTextSecondary,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: NasTokens.spaceXs),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                tr('photo.placePicker.hint'),
                style: TextStyle(
                  fontSize: NasTokens.fontMicro,
                  color: context.nasTextSecondary,
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('common.cancel'))),
        FilledButton(
          onPressed: picked == null
              ? null
              : () {
                  final wgs = _toPhotoCrs(picked);
                  Navigator.pop(
                    context,
                    PhotoSmartRulePlace(
                      latitude: wgs.latitude,
                      longitude: wgs.longitude,
                      radiusKm: _radiusKm,
                    ),
                  );
                },
          child: Text(tr('photo.placePicker.confirm')),
        ),
      ],
    );
  }
}
