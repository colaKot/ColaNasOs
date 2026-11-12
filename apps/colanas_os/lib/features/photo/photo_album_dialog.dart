import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_media/nas_media.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import 'photo_album_pickers.dart';

/// 新建 / 编辑相册的返回值。`rules` 为空就是普通手工相册。
class AlbumDraft {
  const AlbumDraft({
    required this.name,
    this.description = '',
    this.coverItemId,
    this.rules = const [],
  });

  final String name;
  final String description;
  final String? coverItemId;
  final List<PhotoAlbumRule> rules;
}

/// 新建 / 编辑相册对话框。
///
/// 比原来的「一个输入框 + 确定」多了两件事：
///
///   · **封面**：从候选照片里挑一张当封面，不挑就用最早的成员（服务端回落逻辑）。
///     候选只传 `coverCandidates`（多选进来时就是那几张，编辑时是相册成员），
///     没有候选就整块隐藏 —— 相册还是空的，这时候让人挑封面没有意义。
///
///   · **规则**：头像 / 场景 / 活动 / 日期四类条件，命中任意一条就自动收进相册，
///     **以后新入库的照片也按同一套规则自动进来**。这块是「集合」被删掉之后
///     真正需要的那个能力：以前想给「我家猫」建个持续更新的组，只能手工一张张挑。
Future<AlbumDraft?> showAlbumDialog(
  BuildContext context, {
  PhotoAlbum? album,
  List<PhotoItem> coverCandidates = const [],
}) {
  return showDialog<AlbumDraft>(
    context: context,
    builder: (_) => _AlbumDialog(album: album, coverCandidates: coverCandidates),
  );
}

class _AlbumDialog extends StatefulWidget {
  const _AlbumDialog({this.album, this.coverCandidates = const []});

  final PhotoAlbum? album;
  final List<PhotoItem> coverCandidates;

  @override
  State<_AlbumDialog> createState() => _AlbumDialogState();
}

class _AlbumDialogState extends State<_AlbumDialog> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _descCtrl;
  String? _coverItemId;
  late List<PhotoAlbumRule> _rules;

  // 规则候选：进入对话框时拉一次，之后复用（同一个对话框里可以连着加好几条）
  List<PhotoFaceClusterItem> _faces = const [];
  List<PhotoSceneTagSummaryItem> _scenes = const [];
  List<PhotoSceneSummaryItem> _activities = const [];
  bool _loadingFacets = true;
  String? _facetsError;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.album?.name ?? '');
    _descCtrl = TextEditingController(text: widget.album?.description ?? '');
    _coverItemId = widget.album?.coverItemId;
    _rules = List<PhotoAlbumRule>.from(widget.album?.rules ?? const []);
    _loadFacets();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadFacets() async {
    try {
      final c = ApiSession.instance.client;
      // 三个接口互不依赖，一起发；任何一个失败都不该让另一个白跑
      final results = await Future.wait<Object?>([
        c.photoFaceClusters(limit: 500).catchError((_) => const PhotoFaceClusterList(items: [])),
        c.photoSceneTagSummary().catchError((_) => const PhotoSceneTagSummary(items: [])),
        c.photoActivitySummary().catchError((_) => const PhotoSceneSummary(items: [])),
      ]);
      if (!mounted) return;
      setState(() {
        _faces = (results[0] as PhotoFaceClusterList).items;
        _scenes = (results[1] as PhotoSceneTagSummary).items;
        _activities = (results[2] as PhotoSceneSummary).items;
        _loadingFacets = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingFacets = false;
        _facetsError = '$e';
      });
    }
  }

  String _faceName(String? id) {
    if (id == null || id.isEmpty) return tr('photo.album.unnamedFace');
    final hit = _faces.where((f) => f.id == id).toList();
    if (hit.isEmpty) return tr('photo.album.unnamedFace');
    final n = hit.first.name?.trim() ?? '';
    return n.isEmpty ? tr('photo.album.unnamedFace') : n;
  }

  /// 规则 → 一行可读文案。三类分别用各自的措辞，日期带具体区间。
  String _ruleLabel(PhotoAlbumRule r) {
    final kind = '${r.kind}';
    switch (kind) {
      case 'face':
        return '${tr('photo.album.face')} · ${_faceName(r.value)}';
      case 'scene':
        return '${tr('photo.album.scene')} · ${r.value ?? ''}';
      case 'activity':
        return '${tr('photo.album.activity')} · ${r.value ?? ''}';
      case 'date':
        String fmt(int? sec) {
          if (sec == null) return '—';
          final d = DateTime.fromMillisecondsSinceEpoch(sec * 1000);
          return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
        }
        final from = r.from != null ? tr('photo.album.dateFrom', {'d': fmt(r.from)}) : '';
        final to = r.to != null ? tr('photo.album.dateTo', {'d': fmt(r.to)}) : '';
        return '${tr('photo.album.date')} · $from$to';
      default:
        return kind;
    }
  }

  bool _has(PhotoAlbumRule r) => _rules.any(
    (e) =>
        '${e.kind}' == '${r.kind}' &&
        e.value == r.value &&
        e.from == r.from &&
        e.to == r.to,
  );

  Future<void> _addFace() async {
    if (_faces.isEmpty) {
      NasSnack.show(context, tr('photo.album.noFace'));
      return;
    }
    // 只列已命名的人脸（见 showFacePickDialog 的说明），封面与人脸页同一套 URL
    final picked = await showFacePickDialog(context, items: _faces);
    if (picked == null || !mounted) return;
    final rule = PhotoAlbumRule(kind: 'face', value: picked.id);
    if (_has(rule)) return;
    setState(() => _rules = [..._rules, rule]);
  }

  Future<void> _addScene() async {
    if (_scenes.isEmpty) {
      NasSnack.show(context, tr('photo.album.noScene'));
      return;
    }
    // 网格 + 封面，按张数倒序取前 30
    final label = await showScenePickDialog(context, items: _scenes);
    if (label == null || !mounted) return;
    final rule = PhotoAlbumRule(kind: 'scene', value: label);
    if (_has(rule)) return;
    setState(() => _rules = [..._rules, rule]);
  }

  Future<void> _addActivity() async {
    if (_activities.isEmpty) {
      NasSnack.show(context, tr('photo.album.noActivity'));
      return;
    }
    // 与场景同一套选择方式：网格 + 封面，按张数倒序取前 30
    final label = await showActivityPickDialog(context, items: _activities);
    if (label == null || !mounted) return;
    final rule = PhotoAlbumRule(kind: 'activity', value: label);
    if (_has(rule)) return;
    setState(() => _rules = [..._rules, rule]);
  }

  Future<void> _addDate() async {
    final range = await showPhotoDateRangeDialog(context);
    if (range == null || !mounted) return;
    // 结束日当天整天都算：用 23:59:59，否则「到 10 月 5 日」会漏掉 5 号拍的照片
    final from = DateTime(range.start.year, range.start.month, range.start.day)
            .millisecondsSinceEpoch ~/
        1000;
    final to = DateTime(range.end.year, range.end.month, range.end.day, 23, 59, 59)
            .millisecondsSinceEpoch ~/
        1000;
    final rule = PhotoAlbumRule(kind: 'date', from: from, to: to);
    if (_has(rule)) return;
    setState(() => _rules = [..._rules, rule]);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(
        widget.album == null ? tr('ui.photo.050') : tr('photo.album.editTitle'),
      ),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _nameCtrl,
                autofocus: true,
                decoration: InputDecoration(labelText: tr('ui.photo.051')),
              ),
              const SizedBox(height: NasTokens.spaceSm),
              TextField(
                controller: _descCtrl,
                maxLength: 200,
                maxLines: 2,
                minLines: 1,
                decoration: InputDecoration(
                  labelText: tr('photo.album.description'),
                  hintText: tr('photo.album.descriptionHint'),
                ),
              ),

              // ------------------------------------------------------ 封面
              if (widget.coverCandidates.isNotEmpty) ...[
                const SizedBox(height: NasTokens.spaceMd),
                Text(tr('photo.album.cover'), style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: NasTokens.spaceXs),
                SizedBox(
                  height: 72,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: widget.coverCandidates.length + 1,
                    separatorBuilder: (_, _) => const SizedBox(width: NasTokens.spaceXs),
                    itemBuilder: (context, i) {
                      // 第 0 个是「不设封面」
                      if (i == 0) {
                        final on = _coverItemId == null;
                        return InkWell(
                          onTap: () => setState(() => _coverItemId = null),
                          child: Container(
                            width: 72,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: on ? scheme.primary : scheme.outlineVariant,
                                width: on ? 2 : 1,
                              ),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              tr('photo.album.autoCover'),
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: NasTokens.fontMicro,
                                color: context.nasTextSecondary,
                              ),
                            ),
                          ),
                        );
                      }
                      final item = widget.coverCandidates[i - 1];
                      final id = item.id;
                      final on = _coverItemId == id;
                      return InkWell(
                        onTap: () => setState(() => _coverItemId = id),
                        child: Container(
                          width: 72,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: on ? scheme.primary : Colors.transparent,
                              width: on ? 2 : 1,
                            ),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: Image.network(
                            MediaUrls(ApiSession.instance.baseUrl).thumbnail(item.path, size: 144),
                            fit: BoxFit.cover,
                            headers: ApiSession.instance.authHeaders,
                            errorBuilder: (_, _, _) => const ColoredBox(
                              color: Colors.black12,
                              child: Icon(Icons.broken_image_outlined, size: 18),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],

              // ------------------------------------------------------ 规则
              const SizedBox(height: NasTokens.spaceMd),
              Text(tr('photo.album.rules'), style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: NasTokens.spaceXs),
              Text(
                tr('photo.album.rulesHint'),
                style: TextStyle(
                  fontSize: NasTokens.fontMicro,
                  color: context.nasTextSecondary,
                ),
              ),
              const SizedBox(height: NasTokens.spaceXs),
              if (_rules.isNotEmpty)
                Wrap(
                  spacing: NasTokens.spaceXs,
                  runSpacing: NasTokens.spaceXs,
                  children: [
                    for (var i = 0; i < _rules.length; i += 1)
                      InputChip(
                        label: Text(_ruleLabel(_rules[i])),
                        onDeleted: () => setState(() {
                          _rules = [..._rules]..removeAt(i);
                        }),
                      ),
                  ],
                ),
              const SizedBox(height: NasTokens.spaceXs),
              Wrap(
                spacing: NasTokens.spaceXs,
                children: [
                  OutlinedButton.icon(
                    onPressed: _loadingFacets ? null : _addFace,
                    icon: const Icon(Icons.face_retouching_natural, size: 18),
                    label: Text(tr('photo.album.addFace')),
                  ),
                  OutlinedButton.icon(
                    onPressed: _loadingFacets ? null : _addScene,
                    icon: const Icon(Icons.landscape_outlined, size: 18),
                    label: Text(tr('photo.album.addScene')),
                  ),
                  OutlinedButton.icon(
                    onPressed: _loadingFacets ? null : _addActivity,
                    icon: const Icon(Icons.sports_handball_outlined, size: 18),
                    label: Text(tr('photo.album.addActivity')),
                  ),
                  OutlinedButton.icon(
                    onPressed: _addDate,
                    icon: const Icon(Icons.date_range, size: 18),
                    label: Text(tr('photo.album.addDate')),
                  ),
                ],
              ),
              if (_facetsError != null)
                Padding(
                  padding: const EdgeInsets.only(top: NasTokens.spaceXs),
                  child: Text(
                    tr('photo.album.facetsFailed', {'error': _facetsError!}),
                    style: TextStyle(fontSize: NasTokens.fontMicro, color: context.nasDanger),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr('common.cancel')),
        ),
        FilledButton(
          onPressed: () {
            final name = _nameCtrl.text.trim();
            if (name.isEmpty) return;
            Navigator.pop(
              context,
              AlbumDraft(
                name: name,
                description: _descCtrl.text.trim(),
                coverItemId: _coverItemId,
                rules: _rules,
              ),
            );
          },
          child: Text(widget.album == null ? tr('common.create') : tr('common.save')),
        ),
      ],
    );
  }
}

/// 「加入相册」选择器：列出我的相册，末尾带一个新建入口。
///
/// 以前多选照片后只能加进「集合」，而集合和相册是两套东西；现在只有相册，
/// 所以这个选择器必须自己承担「没有相册时也能现场建一个」的职责。
Future<String?> showAlbumPicker(BuildContext context, {required List<PhotoAlbum> albums}) {
  const createSentinel = kAlbumPickerCreate;
  return showDialog<String>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: Text(tr('photo.album.addTo')),
      children: [
        for (final a in albums)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, a.id),
            child: Row(
              children: [
                Expanded(child: Text(a.name)),
                if (a.ruleCount > 0)
                  Padding(
                    padding: const EdgeInsets.only(right: NasTokens.spaceXs),
                    child: Icon(
                      Icons.auto_awesome,
                      size: 14,
                      color: Theme.of(ctx).colorScheme.primary,
                    ),
                  ),
                Text(
                  tr('photo.album.photoCount', {'n': '${a.items}'}),
                  style: TextStyle(
                    fontSize: NasTokens.fontCaption,
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        if (albums.isNotEmpty) const Divider(height: 1),
        SimpleDialogOption(
          onPressed: () => Navigator.pop(ctx, createSentinel),
          child: Row(
            children: [
              const Icon(Icons.add, size: 18),
              const SizedBox(width: NasTokens.spaceXs),
              Text(tr('photo.album.createNew')),
            ],
          ),
        ),
      ],
    ),
  );
}

/// `showAlbumPicker` 里「新建」分支的哨兵值
const String kAlbumPickerCreate = '__create__';
