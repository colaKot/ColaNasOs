import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_media/nas_media.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/gcj02.dart';
import '../../core/map_tiles.dart';

import '../../core/session.dart';
import 'photo_viewer_page.dart';

/// 足迹地图。
///
/// 分工：
///   - 服务端只给「这一屏的 geohash 格代表点」；
///   - **客户端**按世界像素距离聚簇：marker 互相压盖 = 两个点在 zoom 下的像素距离
///     小于 1.15 × marker 直径。落点取种子（本格照片最多那个）的真实坐标，
///     所以聚合后在数学上不可能重叠；
///   - 平移不重算（聚簇只跟 zoom / 数据有关），缩放跨档才重算；
///   - 点开一个簇：把它覆盖的 geohash 格集合原样下发，服务端 `WHERE IN` 一次取回，
///     角标数字与列表张数同源。
class FootprintMapPage extends StatefulWidget {
  const FootprintMapPage({super.key, this.embedded = false});

  /// 嵌入相册二级导航内容区时去掉自带 AppBar
  final bool embedded;

  @override
  State<FootprintMapPage> createState() => _FootprintMapPageState();
}

class _FootprintMapPageState extends State<FootprintMapPage> {
  final MapController _map = MapController();

  bool _loading = true;
  bool _firstBounds = true;
  String? _error;
  List<PhotoMapTileServer> _servers = const [];
  PhotoMapTileServer? _server;

  List<PhotoMapMarker> _markers = const [];
  List<_Cluster> _clusters = const [];

  /// 行程连线：服务端按「间隔 > 12h 另起一段」切好的有序点
  PhotoMapJourneyResponse? _journey;
  bool _showJourney = false;
  bool _loadingJourney = false;

  double _zoom = 5;
  int _tier = 0;
  Timer? _debounce;
  int _requestSeq = 0;
  String _lastKey = '';

  static const double _clusterGapK = 1.15;


  MediaUrls get _media => MediaUrls(ApiSession.instance.baseUrl);
  String _thumbUrl(String path, {int size = 320}) =>
      _media.thumbnail(path, size: size);

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final servers = await ApiSession.instance.client.photoMapTileServers();
      PhotoMapTileServer? current;
      for (final s in servers.items) {
        if (s.isCurrent) current = s;
      }
      if (!mounted) return;
      setState(() {
        _servers = servers.items;
        _server =
            current ?? (servers.items.isEmpty ? null : servers.items.first);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  static double _markerDiameterForTier(int tier) {
    switch (tier) {
      case 0:
        return 40;
      case 1:
        return 60;
      case 2:
        return 70;
      default:
        return 85;
    }
  }

  static int _tierOf(double zoom) {
    if (zoom < 5) return 0;
    if (zoom < 7) return 1;
    if (zoom < 8) return 2;
    return 3;
  }

  /// Web Mercator 世界像素：zoom z 下全世界 256·2^z 像素。
  /// 只跟 zoom 有关 ⇒ 窗口尺寸、地图中心都不影响聚合结果。
  static void _worldPx(double lat, double lng, double zoom, List<double> out) {
    final scale = 256.0 * math.pow(2.0, zoom).toDouble();
    out[0] = (lng + 180.0) / 360.0 * scale;
    final sinLat = math.sin(lat * math.pi / 180.0).clamp(-0.9999999, 0.9999999);
    out[1] =
        (0.5 - math.log((1 + sinLat) / (1 - sinLat)) / (4 * math.pi)) * scale;
  }

  void _onMapChanged(MapCamera camera, bool hasGesture) {
    final zoom = camera.zoom;
    final tier = _tierOf(zoom);
    final bounds = camera.visibleBounds;

    if (zoom != _zoom) {
      _zoom = zoom;
    }
    if (tier != _tier) {
      _tier = tier;
      _recluster();
    }

    _debounce?.cancel();
    // 首次进入立刻取一次；拖动/缩放才用 500ms 防抖
    final delay = _firstBounds ? 80 : 500;
    _firstBounds = false;
    _debounce = Timer(Duration(milliseconds: delay), () {
      _fetchBounds(bounds, zoom);
    });
  }

  Future<void> _fetchBounds(LatLngBounds bounds, double zoom) async {
    final key =
        '${bounds.southWest.latitude.toStringAsFixed(4)},${bounds.southWest.longitude.toStringAsFixed(4)},'
        '${bounds.northEast.latitude.toStringAsFixed(4)},${bounds.northEast.longitude.toStringAsFixed(4)},${zoom.round()}';
    if (key == _lastKey) return;
    _lastKey = key;

    final seq = ++_requestSeq;
    try {
      final res = await ApiSession.instance.client.photoMapBounds(
        minLat: bounds.southWest.latitude,
        minLng: bounds.southWest.longitude,
        maxLat: bounds.northEast.latitude,
        maxLng: bounds.northEast.longitude,
        zoom: zoom,
        // 全球视野只取前 60 格，避免首屏一次拉 150 个 marker 缩略图
        limit: zoom < 6 ? 60 : 150,
      );
      if (!mounted || seq != _requestSeq) return;
      setState(() {
        _markers = res.items;
        _error = null;
      });
      _recluster();
    } catch (e) {
      if (!mounted || seq != _requestSeq) return;
      setState(() => _error = e.toString());
    }
  }

  /// 贪心合并：种子按「本格照片数」降序，落点永远是真实照片坐标。
  void _recluster() {
    final src = _markers;
    if (src.isEmpty) {
      if (_clusters.isNotEmpty) setState(() => _clusters = const []);
      return;
    }

    final threshold = _markerDiameterForTier(_tier) * _clusterGapK;
    final threshold2 = threshold * threshold;
    final n = src.length;
    final px = List<double>.filled(n, 0);
    final py = List<double>.filled(n, 0);
    final probe = List<double>.filled(2, 0);
    for (var i = 0; i < n; i++) {
      _worldPx(src[i].latitude, src[i].longitude, _zoom, probe);
      px[i] = probe[0];
      py[i] = probe[1];
    }

    final order = List<int>.generate(n, (i) => i);
    order.sort((a, b) {
      final ca = src[a].photoCount;
      final cb = src[b].photoCount;
      if (ca != cb) return cb - ca;
      return src[b].id.compareTo(src[a].id);
    });

    final used = List<bool>.filled(n, false);
    final out = <_Cluster>[];
    for (var oi = 0; oi < n; oi++) {
      final i = order[oi];
      if (used[i]) continue;
      used[i] = true;
      var total = src[i].photoCount;
      final cells = <String>{};
      if (src[i].cellKey.isNotEmpty) cells.add(src[i].cellKey);
      for (var oj = oi + 1; oj < n; oj++) {
        final j = order[oj];
        if (used[j]) continue;
        final dx = px[j] - px[i];
        final dy = py[j] - py[i];
        if (dx * dx + dy * dy < threshold2) {
          total += src[j].photoCount;
          if (src[j].cellKey.isNotEmpty) cells.add(src[j].cellKey);
          used[j] = true;
        }
      }
      out.add(
        _Cluster(
          seed: src[i],
          photoCount: total,
          cells: cells.toList()..sort(),
          precision: src[i].cellPrecision,
        ),
      );
    }

    setState(() => _clusters = out);
  }

  Future<void> _openCluster(_Cluster cluster) async {
    String place = '';
    try {
      final res = await ApiSession.instance.client.photoMapPlace(
        geohash: cluster.seed.geohash,
        lat: cluster.seed.latitude,
        lng: cluster.seed.longitude,
        locale: 'zh-CN',
      );
      place = res.name;
    } catch (_) {
      // 地名缺失不影响看图
    }
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _ClusterSheet(
        keys: cluster.cells,
        precision: cluster.precision,
        total: cluster.photoCount,
        place: place,
        thumbUrl: _thumbUrl,
        headers: ApiSession.instance.authHeaders,
      ),
    );
  }

  Future<void> _switchServer(PhotoMapTileServer server) async {
    try {
      await ApiSession.instance.client.photoMapTileServerSet(
        body: PhotoMapTileServerBody(
          id: server.id,
          name: server.name,
          url: server.url,
          coordinate: server.coordinate,
          maxLevel: server.maxLevel,
        ),
      );
      _lastKey = '';
      if (!mounted) return;
      setState(() => _server = server);
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, tr('photo.mapSwitchFailed', {'error': '$e'}));
    }
  }

  /// 国内底图（高德）使用 GCJ-02，照片是 WGS-84：marker 需要跟着偏移，
  /// 否则会落在隔壁街道。
  bool get _isGcj => (_server?.coordinate ?? 'WGS-84') == 'GCJ-02';

  /// 行程连线开关：首次打开才请求，避免每次进地图都多一次全库扫描
  Future<void> _toggleJourney() async {
    if (_showJourney) {
      setState(() => _showJourney = false);
      return;
    }
    setState(() {
      _showJourney = true;
      _loadingJourney = true;
    });
    try {
      final res = await ApiSession.instance.client.photoMapJourney(
        gapHours: 12,
        maxPoints: 600,
      );
      if (!mounted) return;
      setState(() {
        _journey = res;
        _loadingJourney = false;
      });
      if (res.points == 0) {
        NasSnack.show(context, tr('photo.map.journeyEmpty'));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingJourney = false);
      NasSnack.show(context, tr('photo.map.journeyFailed', {'error': '$e'}));
    }
  }

  /// 行程折线：每段一条（段与段之间是"回家/换城市"，不能连成一条线）
  List<Polyline> _journeyLines() {
    final color = Theme.of(context).colorScheme.primary;
    final out = <Polyline>[];
    for (final seg in _journey?.segments ?? const <PhotoMapJourneySegment>[]) {
      if (seg.points.length < 2) continue;
      out.add(
        Polyline(
          points: [
            for (final p in seg.points) _mapPoint(p.latitude, p.longitude),
          ],
          strokeWidth: 2.5,
          color: color.withValues(alpha: 0.75),
          borderStrokeWidth: 1,
          borderColor: Colors.black26,
        ),
      );
    }
    return out;
  }


  LatLng _mapPoint(double lat, double lng) {
    if (!_isGcj) return LatLng(lat, lng);
    final (gLat, gLng) = wgsToGcj(lat, lng);
    return LatLng(gLat, gLng);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: widget.embedded ? null : AppBar(
        title: Text(tr('ui.photo.021')),
        actions: [
          IconButton(
            tooltip: tr('photo.map.journey'),
            icon: Icon(
              _showJourney ? Icons.timeline : Icons.timeline_outlined,
              color: _showJourney ? Theme.of(context).colorScheme.primary : null,
            ),
            onPressed: _toggleJourney,
          ),
          IconButton(
            tooltip: tr('ui.photo.022'),
            icon: const Icon(Icons.layers_outlined),
            onPressed: _servers.isEmpty
                ? null
                : () async {
                    final picked =
                        await showModalBottomSheet<PhotoMapTileServer>(
                          context: context,
                          showDragHandle: true,
                          builder: (ctx) => SafeArea(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                for (final s in _servers)
                                  ListTile(
                                    leading: Icon(
                                      s.isCurrent
                                          ? Icons.radio_button_checked
                                          : Icons.radio_button_off,
                                    ),
                                    title: Text(s.name),
                                    subtitle: Text(
                                      s.url,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    onTap: () => Navigator.pop(ctx, s),
                                  ),
                              ],
                            ),
                          ),
                        );
                    if (picked != null) await _switchServer(picked);
                  },
          ),
          IconButton(
            tooltip: tr('ui.photo.023'),
            icon: const Icon(Icons.public),
            onPressed: () {
              _map.move(const LatLng(34.0, 108.0), 5);
            },
          ),
        ],
      ),
      body: _loading
          ? const NasLoading()
          : Stack(
              children: [
                FlutterMap(
                  mapController: _map,
                  options: MapOptions(
                    initialCenter: const LatLng(34.0, 108.0),
                    initialZoom: 5,
                    minZoom: 2,
                    maxZoom: 18,
                    // 首屏必须自己取一次：`onPositionChanged` 只在位置**真的变了**
                    // 时回调，刚进页面不动鼠标就永远没有数据（2026-11-04 反馈）。
                    onMapReady: () => _onMapChanged(_map.camera, false),
                    onPositionChanged: _onMapChanged,
                  ),
                  children: [
                    TileLayer(
                      // 换底图后必须重建 TileLayer，否则旧源的瓦片会留在缓存里
                      key: ValueKey(_server?.id ?? 'default'),
                      urlTemplate: tileProxyTemplate(serverId: _server?.id),
                      tileProvider: NetworkTileProvider(
                        headers: tileProxyHeaders(),
                      ),
                      userAgentPackageName: 'com.colanas.os',
                      maxNativeZoom: _server?.maxLevel ?? 19,
                    ),
                    if (_showJourney)
                      PolylineLayer(polylines: _journeyLines()),
                    MarkerLayer(
                      markers: [
                        for (final cluster in _clusters)
                          Marker(
                            point: _mapPoint(
                              cluster.seed.latitude,
                              cluster.seed.longitude,
                            ),
                            width: _markerDiameterForTier(_tier),
                            height: _markerDiameterForTier(_tier),
                            child: _ClusterMarker(
                              count: cluster.photoCount,
                              // 之前 zoom<6 一律不给图，而初始 zoom 正好是 5 ——
                              // 只平移不缩放时整页都是灰色占位（2026-11-04 反馈）。
                              // 小倍率用更小的缩略图控制流量。
                              photoUrl: cluster.seed.path.isEmpty
                                  ? null
                                  : _thumbUrl(
                                      cluster.seed.path,
                                      size: _zoom < 6 ? 120 : 200,
                                    ),
                              takenAt: cluster.seed.takenAt,
                              size: _markerDiameterForTier(_tier),
                              headers: ApiSession.instance.authHeaders,
                              onTap: () => _openCluster(cluster),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
                if (widget.embedded)
                  Positioned(
                    right: NasTokens.spaceMd,
                    top: NasTokens.spaceMd,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Material(
                          elevation: 2,
                          borderRadius: BorderRadius.circular(99),
                          child: IconButton(
                            tooltip: tr('photo.map.journey'),
                            icon: Icon(
                              _showJourney ? Icons.timeline : Icons.timeline_outlined,
                              color: _showJourney
                                  ? Theme.of(context).colorScheme.primary
                                  : null,
                            ),
                            onPressed: _toggleJourney,
                          ),
                        ),
                        if (_loadingJourney)
                          const Padding(
                            padding: EdgeInsets.only(top: NasTokens.spaceSm),
                            child: SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                      ],
                    ),
                  ),
                if (_showJourney && _journey != null && _journey!.points > 0)
                  Positioned(
                    right: NasTokens.spaceMd,
                    bottom: NasTokens.spaceMd,
                    child: IgnorePointer(
                      child: Material(
                        color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.9),
                        borderRadius: BorderRadius.circular(NasTokens.radiusSm),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          child: Text(
                            tr('photo.map.journeySummary', {
                              'points': '${_journey!.points}',
                              'days': '${_journey!.days}',
                              'km': '${_journey!.distanceKm}',
                            }),
                            style: TextStyle(
                              fontSize: NasTokens.fontCaption,
                              color: context.nasTextSecondary,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                if (_error != null)
                  Positioned(
                    left: NasTokens.spaceMd,
                    right: NasTokens.spaceMd,
                    bottom: NasTokens.spaceMd,
                    child: Material(
                      color: Theme.of(context).colorScheme.errorContainer,
                      borderRadius: BorderRadius.circular(NasTokens.radiusSm),
                      child: Padding(
                        padding: const EdgeInsets.all(NasTokens.spaceSm),
                        child: Text(
                          tr('photo.mapLoadFailed', {'error': '$_error'}),
                          style: TextStyle(
                            color: Theme.of(context)
                                .colorScheme
                                .onErrorContainer,
                          ),
                        ),
                      ),
                    ),
                  ),
                Positioned(
                  left: NasTokens.spaceMd,
                  top: NasTokens.spaceMd,
                  child: IgnorePointer(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(NasTokens.radiusSm),
                      ),
                      child: Text(
                        tr('photo.footprintSummary', {'places': '${_clusters.length}', 'cells': '${_markers.length}'}),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: NasTokens.fontCaption,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

class _ClusterMarker extends StatelessWidget {
  const _ClusterMarker({
    required this.count,
    required this.size,
    required this.photoUrl,
    required this.takenAt,
    required this.headers,
    required this.onTap,
  });

  final int count;
  final double size;
  final String? photoUrl;
  final int takenAt;
  final Map<String, String> headers;
  final VoidCallback onTap;

  static String _countText(int n) {
    if (n <= 0) return '';
    if (n < 100000) return '$n';
    final k = n / 1000;
    return '${k.toStringAsFixed(k >= 100 ? 0 : 1)}k';
  }

  String get _dateText {
    final d = DateTime.fromMillisecondsSinceEpoch(takenAt * 1000);
    return '${d.year}/${d.month}';
  }

  @override
  Widget build(BuildContext context) {
    final radius = (size * 0.2).clamp(6.0, 14.0);
    final badgeHeight = (size * 0.42).clamp(16.0, 30.0);
    return GestureDetector(
      onTap: onTap,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(radius),
                border: Border.all(color: Colors.white, width: 2),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black26,
                    blurRadius: 6,
                    offset: Offset(0, 2),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(radius - 2),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (photoUrl != null)
                      NasCoverImage(
                        url: photoUrl,
                        headers: headers,
                        fit: BoxFit.cover,
                      )
                    else
                      ColoredBox(
                        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.12),
                        child: const Icon(Icons.photo_outlined, size: 18),
                      ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                        color: Colors.black54,
                        child: Text(
                          _dateText,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: (size * 0.14).clamp(8.0, 11.0),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (count > 1)
            Positioned(
              top: -6,
              right: -6,
              child: Container(
                height: badgeHeight,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary,
                  borderRadius: BorderRadius.circular(badgeHeight / 2),
                  border: Border.all(color: Colors.white, width: 1.5),
                  boxShadow: const [
                    BoxShadow(color: Colors.black26, blurRadius: 4, offset: Offset(0, 1)),
                  ],
                ),
                child: Text(
                  _countText(count),
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: (badgeHeight * 0.46).clamp(9.0, 13.0),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 点开簇之后的范围 = 簇覆盖的 geohash 格集合；`total` 由服务端 COUNT(*) 给出。
class _ClusterSheet extends StatefulWidget {
  const _ClusterSheet({
    required this.keys,
    required this.precision,
    required this.total,
    required this.place,
    required this.thumbUrl,
    required this.headers,
  });

  final List<String> keys;
  final int precision;
  final int total;
  final String place;
  final String Function(String path, {int size}) thumbUrl;
  final Map<String, String> headers;

  @override
  State<_ClusterSheet> createState() => _ClusterSheetState();
}

class _ClusterSheetState extends State<_ClusterSheet> {
  final _items = <PhotoMapPhoto>[];
  String? _cursor;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool more = false}) async {
    if (more && _cursor == null) return;
    setState(() => _loading = true);
    try {
      final res = await ApiSession.instance.client.photoMapCells(
        keys: widget.keys.join(','),
        precision: widget.precision,
        limit: 120,
        cursor: more ? _cursor : null,
      );
      if (!mounted) return;
      setState(() {
        if (more) {
          _items.addAll(res.items);
        } else {
          _items
            ..clear()
            ..addAll(res.items);
        }
        _items.sort((a, b) => b.takenAt.compareTo(a.takenAt));
        _cursor = res.nextCursor;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  String _dayText(int epochSec) {
    final d = DateTime.fromMillisecondsSinceEpoch(epochSec * 1000);
    return '${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  String _rangeText() {
    String y(int t) => '${DateTime.fromMillisecondsSinceEpoch(t * 1000).year}';
    final first = _items.first.takenAt;
    final last = _items.last.takenAt;
    return y(first) == y(last) ? y(first) : '${y(last)} - ${y(first)}';
  }

  /// 地图上的照片也要能点开看 —— 只能看缩略图是「附近」这个功能最大的浪费
  void _openViewer(int index) {
    final items = _items
        .map(
          (e) => PhotoItem(
            id: e.id,
            libraryId: '',
            path: e.path,
            takenAt: e.takenAt,
            size: 0,
            width: null,
            height: null,
            mime: '',
            favorite: false,
          ),
        )
        .toList();
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PhotoViewerPage(
          items: items,
          initialIndex: index,
          title: widget.place.isEmpty ? null : widget.place,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.72,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: NasTokens.spaceMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    widget.place.isEmpty
                        ? tr('ui.photo.hed257c')
                        : widget.place,
                    style: Theme.of(context).textTheme.titleMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      tr('photo.count', {'count': '${widget.total}'}),
                      style: TextStyle(
                        color: context.nasTextSecondary,
                        fontSize: NasTokens.fontCaption,
                      ),
                    ),
                    if (_items.isNotEmpty)
                      Text(
                        _rangeText(),
                        style: TextStyle(
                          color: context.nasTextSecondary,
                          fontSize: NasTokens.fontMicro,
                        ),
                      ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: NasTokens.spaceSm),
            Expanded(
              child: _error != null
                  ? NasErrorState(message: _error!, onRetry: _load)
                  : _loading && _items.isEmpty
                  ? const Center(child: CircularProgressIndicator())
                  : GridView.builder(
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 120,
                            crossAxisSpacing: NasTokens.spaceXs,
                            mainAxisSpacing: NasTokens.spaceXs,
                          ),
                      itemCount: _items.length,
                      itemBuilder: (context, i) {
                        final item = _items[i];
                        return InkWell(
                          borderRadius: BorderRadius.circular(NasTokens.radiusSm),
                          onTap: () => _openViewer(i),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(
                                  NasTokens.radiusSm,
                                ),
                                child: NasCoverImage(
                                  url: widget.thumbUrl(item.path),
                                  headers: widget.headers,
                                  cacheWidth: 240,
                                  icon: Icons.broken_image_outlined,
                                ),
                              ),
                              // 日期角标：让"这一带"有时间感（附近时间轴的要点）
                              Positioned(
                                left: 4,
                                bottom: 4,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 4,
                                    vertical: 1,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.black.withValues(alpha: 0.55),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    _dayText(item.takenAt),
                                    style: const TextStyle(
                                      fontSize: 9,
                                      color: Colors.white,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
            if (_cursor != null)
              SizedBox(
                width: double.infinity,
                child: TextButton(
                  onPressed: _loading ? null : () => _load(more: true),
                  child: Text(
                    _loading ? tr('ui.photo.024') : tr('ui.photo.025'),
                  ),
                ),
              ),
            const SizedBox(height: NasTokens.spaceSm),
          ],
        ),
      ),
    );
  }
}

class _Cluster {
  const _Cluster({
    required this.seed,
    required this.photoCount,
    required this.cells,
    required this.precision,
  });

  final PhotoMapMarker seed;
  final int photoCount;
  final List<String> cells;
  final int precision;
}
