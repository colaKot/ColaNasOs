import 'dart:math' as math;

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
    // 写死 640×460 在手机上是「整行被裁掉」的根源：390 宽的屏装不下。
    // 按屏幕尺寸收一档，桌面仍保持原来的大对话框。
    final screen = MediaQuery.sizeOf(context);
    final width = math.min(640.0, screen.width - 48).clamp(240.0, 640.0);
    final height = math.min(460.0, screen.height - 200).clamp(260.0, 460.0);
    return AlertDialog(
      title: Text(tr('photo.placePicker.title')),
      content: SizedBox(
        width: width,
        height: height,
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
                    // 双指缩放时顺带旋转是 flutter_map 默认行为；选点页只要
                    // 平移 + 缩放，旋转会让「点在哪里」失去方向感，直接关掉。
                    interactionOptions: const InteractionOptions(
                      flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
                    ),
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
            // 半径 chip 用 Wrap：窄屏自动换行，不再靠 Spacer 硬挤导致溢出。
            Wrap(
              spacing: 6,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  tr('photo.placePicker.radius'),
                  style: TextStyle(
                    fontSize: NasTokens.fontCaption,
                    color: context.nasTextSecondary,
                  ),
                ),
                for (final r in _radii)
                  NasChip(
                    visualDensity: VisualDensity.compact,
                    label: Text('${r.toInt()}km'),
                    selected: _radiusKm == r,
                    onSelected: (_) => setState(() => _radiusKm = r),
                  ),
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
