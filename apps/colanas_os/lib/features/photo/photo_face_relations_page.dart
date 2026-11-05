import 'dart:math' as math;
import '../../shell/app_widgets.dart';

import 'package:flutter/material.dart';
import 'package:nas_media/nas_media.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';

/// 人物关系图：同框共现边 + 证据张数（后端 `GET /photo/faces/relations`）。
///
/// 只展示「最强的一圈人」：按边的证据张数排序，取前 N 个节点围成圆环，
/// 边按证据数着色 / 加粗；点人物弹出他/她的照片（`GET /photo/faces?id=`）。
class PhotoFaceRelationsPage extends StatefulWidget {
  const PhotoFaceRelationsPage({super.key, this.embedded = true});

  final bool embedded;

  @override
  State<PhotoFaceRelationsPage> createState() => _PhotoFaceRelationsPageState();
}

class _PhotoFaceRelationsPageState extends State<PhotoFaceRelationsPage> {
  bool _loading = true;
  String? _error;
  List<_Node> _nodes = const [];
  List<_Edge> _edges = const [];

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
      final res = await ApiSession.instance.client.photoFaceRelations(limit: '400');
      final rawNodes = ((res['nodes'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => _Node(
                id: '${e['id']}',
                name: '${e['name'] ?? ''}',
                size: (e['size'] as num?)?.toInt() ?? 0,
              ))
          .toList();
      final rawEdges = ((res['edges'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => _Edge(
                a: '${e['a']}',
                b: '${e['b']}',
                photos: (e['photos'] as num?)?.toInt() ?? 0,
              ))
          .toList();
      _edges = rawEdges;

      // 只保留证据最多的前 20 个节点，避免几百个节点挤成一团
      const maxNodes = 20;
      final degree = <String, int>{};
      for (final e in _edges) {
        degree[e.a] = (degree[e.a] ?? 0) + e.photos;
        degree[e.b] = (degree[e.b] ?? 0) + e.photos;
      }
      final byId = {for (final n in rawNodes) n.id: n};
      final keep = degree.keys.toList()
        ..sort((a, b) => (degree[b] ?? 0).compareTo(degree[a] ?? 0));
      final ids = keep.take(maxNodes).toSet();
      _nodes = [
        for (final id in keep.where(ids.contains))
          byId[id] ??
              _Node(id: id, name: '', size: 0),
      ];
      _edges = _edges.where((e) => ids.contains(e.a) && ids.contains(e.b)).toList();
      if (!mounted) return;
      setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _openPerson(_Node node) async {
    try {
      final res = await ApiSession.instance.client.photoFaces(id: node.id);
      if (!mounted) return;
      final media = MediaUrls(ApiSession.instance.baseUrl);
      final token = ApiSession.instance.token;
      final headers =
          token == null ? const <String, String>{} : {'Authorization': 'Bearer $token'};
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(node.name.isEmpty ? tr('photo.relations.unnamed') : node.name),
          content: SizedBox(
            width: 640,
            height: 420,
            child: res.items.isEmpty
                ? Center(child: Text(tr('photo.relations.noPhotos')))
                : GridView.builder(
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 140,
                      mainAxisSpacing: NasTokens.spaceXs,
                      crossAxisSpacing: NasTokens.spaceXs,
                    ),
                    itemCount: res.items.length,
                    itemBuilder: (c, i) {
                      final p = res.items[i];
                      return ClipRRect(
                        borderRadius:
                            BorderRadius.circular(NasTokens.radiusSm),
                        child: NasCoverImage(
                          url: media.thumbnail(p.path, size: 280),
                          headers: headers,
                          cacheWidth: 280,
                          icon: Icons.photo_outlined,
                        ),
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr('common.close')),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: widget.embedded
          ? null
          : AppBar(title: Text(tr('photo.relations.title'))),
      body: _loading
          ? const NasLoading()
          : _error != null
              ? NasErrorState(message: _error!, onRetry: _load)
              : _nodes.isEmpty
                  ? ListView(
                      children: [
                        NasEmptyState(
                          title: tr('photo.relations.empty'),
                          message: tr('photo.relations.emptyHint'),
                          icon: Icons.hub_outlined,
                        ),
                      ],
                    )
                  : Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(
                            NasTokens.spaceMd,
                            NasTokens.spaceSm,
                            NasTokens.spaceSm,
                            0,
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  tr('photo.relations.hint', {
                                    'nodes': _nodes.length,
                                    'edges': _edges.length,
                                  }),
                                  style: TextStyle(
                                    fontSize: NasTokens.fontCaption,
                                    color: context.nasTextSecondary,
                                  ),
                                ),
                              ),
                              NasRefreshButton(onPressed: _load),
                            ],
                          ),
                        ),
                        SizedBox(height: 360, child: _graph()),
                        const Divider(height: 1),
                        Expanded(child: _edgeList()),
                      ],
                    ),
    );
  }

  Widget _graph() {
    final scheme = Theme.of(context).colorScheme;
    final n = _nodes.length;
    final maxPhotos = _edges.isEmpty
        ? 1
        : _edges.map((e) => e.photos).reduce(math.max);
    return LayoutBuilder(
      builder: (context, c) {
        final cx = c.maxWidth / 2;
        final cy = 180.0;
        final radius = math.min(c.maxWidth, 360) * 0.38;
        final positions = <String, Offset>{};
        for (var i = 0; i < n; i += 1) {
          final angle = -math.pi / 2 + 2 * math.pi * i / n;
          positions[_nodes[i].id] =
              Offset(cx + radius * math.cos(angle), cy + radius * math.sin(angle));
        }
        return Stack(
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _EdgePainter(
                  edges: _edges,
                  positions: positions,
                  maxPhotos: maxPhotos,
                  color: scheme.primary,
                ),
              ),
            ),
            for (final node in _nodes)
              Positioned(
                left: positions[node.id]!.dx - 28,
                top: positions[node.id]!.dy - 28,
                child: GestureDetector(
                  onTap: () => _openPerson(node),
                  child: Column(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: scheme.primary.withValues(alpha: 0.16),
                          border: Border.all(
                            color: scheme.primary.withValues(alpha: 0.45),
                          ),
                        ),
                        child: Text(
                          node.name.isEmpty
                              ? tr('photo.relations.unnamed')
                              : node.name.substring(0, 1),
                          style: TextStyle(
                            fontSize: NasTokens.fontCaption,
                            color: scheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 80,
                        child: Text(
                          node.name.isEmpty
                              ? tr('photo.relations.unnamed')
                              : node.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: NasTokens.fontMicro,
                            color: context.nasTextSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _edgeList() {
    if (_edges.isEmpty) {
      return Center(child: Text(tr('photo.relations.noEdges')));
    }
    final sorted = [..._edges]..sort((a, b) => b.photos.compareTo(a.photos));
    final byId = {for (final n in _nodes) n.id: n};
    return ListView.builder(
      padding: const EdgeInsets.symmetric(
        horizontal: NasTokens.spaceMd,
        vertical: NasTokens.spaceXs,
      ),
      itemCount: sorted.length,
      itemBuilder: (context, i) {
        final e = sorted[i];
        final a = byId[e.a];
        final b = byId[e.b];
        return ListTile(
          dense: true,
          leading: const Icon(Icons.link, size: 18),
          title: Text(
            '${a?.name.isNotEmpty == true ? a!.name : tr('photo.relations.unnamed')} '
            '↔ ${b?.name.isNotEmpty == true ? b!.name : tr('photo.relations.unnamed')}',
          ),
          trailing: Text(tr('photo.relations.photos', {'count': e.photos})),
        );
      },
    );
  }
}

class _Node {
  const _Node({required this.id, required this.name, required this.size});
  final String id;
  final String name;
  final int size;
}

class _Edge {
  const _Edge({required this.a, required this.b, required this.photos});
  final String a;
  final String b;
  final int photos;
}

class _EdgePainter extends CustomPainter {
  _EdgePainter({
    required this.edges,
    required this.positions,
    required this.maxPhotos,
    required this.color,
  });

  final List<_Edge> edges;
  final Map<String, Offset> positions;
  final int maxPhotos;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..style = PaintingStyle.stroke;
    for (final e in edges) {
      final a = positions[e.a];
      final b = positions[e.b];
      if (a == null || b == null) continue;
      final ratio = maxPhotos == 0 ? 0.2 : e.photos / maxPhotos;
      paint
        ..color = color.withValues(alpha: 0.10 + 0.55 * ratio)
        ..strokeWidth = 1 + 3 * ratio;
      canvas.drawLine(a, b, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _EdgePainter old) =>
      old.edges != edges || old.positions != positions;
}
