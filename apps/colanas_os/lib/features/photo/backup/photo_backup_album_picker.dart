import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:nas_ui/nas_ui.dart';
import 'package:photo_manager/photo_manager.dart' as pm;

/// 备份源相册多选页（全屏）。
///
/// 与「选几个文件传一下」不同：整机只维护一份备份配置，这里是选**相册**而不是选文件。
/// - 进入默认全选（本机所有相册）；
/// - 顶部一键全选 / 全不选；
/// - 返回 null 表示取消；返回空 ids 等价于「全部相册」。
class PhotoBackupAlbumPicker extends StatefulWidget {
  const PhotoBackupAlbumPicker({
    super.key,
    required this.selectedIds,
  });

  final List<String> selectedIds;

  static Future<({List<String> ids, List<String> names})?> pick(
    BuildContext context,
    List<String> selectedIds,
  ) async {
    return Navigator.of(context).push<({List<String> ids, List<String> names})>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => PhotoBackupAlbumPicker(selectedIds: selectedIds),
      ),
    );
  }

  @override
  State<PhotoBackupAlbumPicker> createState() => _PhotoBackupAlbumPickerState();
}

class _AlbumPreview {
  const _AlbumPreview(this.count, this.thumb);

  final int count;
  final Uint8List? thumb;
}

class _PhotoBackupAlbumPickerState extends State<PhotoBackupAlbumPicker> {
  List<pm.AssetPathEntity> _paths = const <pm.AssetPathEntity>[];
  final Set<String> _selected = <String>{};
  // 每次 _load 会整体替换（数量变了要重新对齐排序），所以不是 final。
  Map<String, _AlbumPreview> _previews = <String, _AlbumPreview>{};
  bool _loading = true;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      // 没有相册权限时 getAssetPathList 只会返回空列表，用户会以为「手机里没照片」，
      // 所以先交互式要一次权限再列相册。
      final state = await pm.PhotoManager.requestPermissionExtend();
      if (!state.hasAccess) {
        if (mounted) {
          setState(() {
            _error = tr('photo.backup.permissionMissing');
            _loading = false;
          });
        }
        return;
      }
      // hasAll: true 会额外返回一个 isAll 的「全部」虚拟相册（Android 上叫
      // Recent，iOS 上叫 Recents）。它不是真实目录，选中它等于「全部照片」，
      // 和下面的 Camera / 截图 / 视频 目录内容重复，列表看着就没头没尾。
      // 备份是按真实相册挑的，所以不要这个聚合项。
      final allPaths = await pm.PhotoManager.getAssetPathList(
        type: pm.RequestType.common,
        hasAll: false,
      );
      // iOS 会把「最近删除」当真实相册返回（插件侧过滤被注释掉了），
      // Android 厂商也各有自己的回收站相册；选它当备份源会把已删照片搬进 NAS。
      final paths = allPaths
          .where(
            (p) => ![
              'recently deleted',
              '最近删除',
              '已删除',
              '回收站',
              'trash',
            ].any((w) => p.name.toLowerCase().contains(w)),
          )
          .toList();
      if (!mounted) return;

      // 先把每个相册的数量并发查出来（只查库，不解码像素）。数量决定排序，
      // 必须在首帧之前拿到；边加载边插会让列表在用户眼前乱跳。
      final counts = <String, int>{};
      await Future.wait(
        paths.map((p) async {
          try {
            counts[p.id] = await p.assetCountAsync;
          } catch (_) {
            counts[p.id] = 0;
          }
        }),
      );
      if (!mounted) return;

      // 数量多的排最上面（Camera 通常在第一位）；数量相同按名字排，
      // 保证同一份数据每次进来顺序一致，不会随机换位。
      final sorted = List<pm.AssetPathEntity>.of(paths)
        ..sort((a, b) {
          final ca = counts[a.id] ?? 0;
          final cb = counts[b.id] ?? 0;
          if (ca != cb) return cb.compareTo(ca);
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        });

      final valid = sorted.map((p) => p.id).toSet();
      final selected = <String>{};
      if (widget.selectedIds.isEmpty) {
        // 空集合 = 全部相册（与「已选 N 个」区分）
        selected.addAll(valid);
      } else {
        selected.addAll(widget.selectedIds.where(valid.contains));
      }

      setState(() {
        _paths = sorted;
        _previews = <String, _AlbumPreview>{
          for (final e in counts.entries) e.key: _AlbumPreview(e.value, null),
        };
        _selected
          ..clear()
          ..addAll(selected);
        _loading = false;
      });

      // 缩略图单独补：一张一张回填，不阻塞列表先出来。
      for (final p in sorted) {
        unawaited(_loadThumb(p));
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  /// 只补缩略图，数量在 [_load] 里已经查过，不重复取。
  Future<void> _loadThumb(pm.AssetPathEntity p) async {
    final count = _previews[p.id]?.count ?? 0;
    if (count <= 0) return;
    try {
      final assets = await p.getAssetListPaged(page: 0, size: 1);
      if (assets.isEmpty) return;
      final thumb = await assets.first.thumbnailDataWithSize(
        const pm.ThumbnailSize.square(240),
      );
      if (thumb == null || !mounted) return;
      setState(() {
        _previews[p.id] = _AlbumPreview(count, thumb);
      });
    } catch (_) {
      // 缩略图失败不影响选择
    }
  }

  void _toggleAll() {
    setState(() {
      if (_selected.length == _paths.length) {
        _selected.clear();
      } else {
        _selected.addAll(_paths.map((p) => p.id));
      }
    });
  }

  void _toggleOne(String id) {
    setState(() {
      if (!_selected.remove(id)) _selected.add(id);
    });
  }

  void _submit() {
    final all = _paths.isNotEmpty && _selected.length == _paths.length;
    final picked = _paths.where((p) => _selected.contains(p.id)).toList();
    Navigator.of(context).pop((
      ids: all ? <String>[] : picked.map((p) => p.id).toList(),
      names: all ? <String>[] : picked.map((p) => p.name).toList(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final allSelected = _paths.isNotEmpty && _selected.length == _paths.length;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('photo.backup.albumSelectMulti')),
        actions: [
          TextButton(
            onPressed: _loading || _paths.isEmpty ? null : _toggleAll,
            child: Text(
              allSelected
                  ? tr('photo.backup.unselectAll')
                  : tr('photo.backup.selectAll'),
            ),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error.isNotEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(NasTokens.spaceLg),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          tr('photo.backup.permissionMissing'),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: NasTokens.spaceMd),
                        FilledButton.tonal(
                          onPressed: () async {
                            try {
                              await pm.PhotoManager.openSetting();
                            } catch (_) {
                              // 平台不支持打开设置页时忽略
                            }
                          },
                          child: Text(tr('photo.backup.openSettings')),
                        ),
                      ],
                    ),
                  ),
                )
              : _paths.isEmpty
                  ? Center(child: Text(tr('photo.backup.albumEmpty')))
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(
                            NasTokens.spaceMd,
                            NasTokens.spaceSm,
                            NasTokens.spaceMd,
                            0,
                          ),
                          child: Text(
                            tr('photo.backup.selectedCount', {
                              'count': '${_selected.length}',
                            }),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: context.nasTextSecondary,
                            ),
                          ),
                        ),
                        Expanded(
                          child: GridView.builder(
                            padding: const EdgeInsets.all(NasTokens.spaceMd),
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 2,
                              mainAxisSpacing: 10,
                              crossAxisSpacing: 10,
                              childAspectRatio: 0.82,
                            ),
                            itemCount: _paths.length,
                            itemBuilder: (context, i) => _AlbumGridTile(
                              path: _paths[i],
                              selected: _selected.contains(_paths[i].id),
                              preview: _previews[_paths[i].id],
                              onTap: () => _toggleOne(_paths[i].id),
                            ),
                          ),
                        ),
                      ],
                    ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            NasTokens.spaceMd,
            NasTokens.spaceSm,
            NasTokens.spaceMd,
            NasTokens.spaceMd,
          ),
          child: FilledButton(
            onPressed: _loading || _paths.isEmpty ? null : _submit,
            child: Text(tr('common.confirm')),
          ),
        ),
      ),
    );
  }
}

class _AlbumGridTile extends StatelessWidget {
  const _AlbumGridTile({
    required this.path,
    required this.selected,
    required this.preview,
    required this.onTap,
  });

  final pm.AssetPathEntity path;
  final bool selected;
  final _AlbumPreview? preview;
  final VoidCallback onTap;

  /// 相册封面：有缩略图直接铺满，没有就给同色底 + 占位图标。
  Widget _albumThumb(ThemeData theme, Uint8List? bytes) {
    if (bytes != null && bytes.isNotEmpty) {
      return Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true);
    }
    return ColoredBox(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Center(
        child: Icon(
          Icons.photo_library_outlined,
          size: 36,
          color: theme.colorScheme.outlineVariant,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final thumb = preview?.thumb;    final countLabel = preview == null ? '…' : '${preview?.count ?? 0}';
    return Material(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: _albumThumb(theme, thumb)),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        path.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        tr('photo.backup.photoCount', {'count': countLabel}),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: context.nasTextSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (selected)
              IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: theme.colorScheme.primary,
                      width: 2,
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            Positioned(
              top: 6,
              right: 6,
              child: Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: selected
                      ? theme.colorScheme.primary
                      : Colors.black.withValues(alpha: 0.25),
                  border: Border.all(color: Colors.white, width: 1.5),
                ),
                child: selected
                    ? const Icon(Icons.check, size: 16, color: Colors.white)
                    : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
