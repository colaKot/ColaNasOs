import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import '../photo/folder_picker.dart';
import 'blog_collections_page.dart';
import 'blog_player.dart';
import 'blog_player_page.dart';

/// 博客 · 本地博客：目录源列表 + 多层目录浏览。
///
/// 页内两级：默认是目录源列表；点进某个源后进入浏览视图（层级用面包屑表示）。
/// 浏览时只列**音频文件**，封面取「同目录同名图片」，没有就显示统一的博客图标。
class LocalBlogPage extends StatefulWidget {
  const LocalBlogPage({super.key});

  @override
  State<LocalBlogPage> createState() => _LocalBlogPageState();
}

class _LocalBlogPageState extends State<LocalBlogPage> {
  bool _loading = true;
  String? _error;
  List<BlogLocalSource> _sources = const [];

  /// 非空 = 正在浏览这个目录源
  BlogLocalSource? _source;
  BlogLocalBrowseResponse? _browse;
  bool _browseLoading = false;

  /// 多选模式：只有打开后才显示勾选框，避免平时误触选中
  bool _selecting = false;

  final Set<String> _selected = <String>{};

  @override
  void initState() {
    super.initState();
    _loadSources();
  }

  Future<void> _loadSources() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ApiSession.instance.client.blogLocalSources();
      if (!mounted) return;
      setState(() {
        _sources = res.items;
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

  Future<void> _addSource() async {
    final draft = await showDialog<_SourceDraft>(
      context: context,
      builder: (_) => const _AddSourceDialog(),
    );
    if (draft == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ApiSession.instance.client.blogLocalSourceAdd(
        body: BlogLocalSourceBody(
          path: draft.path,
          name: draft.name.isEmpty ? null : draft.name,
        ),
      );
      NasSnack.showOn(messenger, tr('blog.local.sourceAdded'));
      await _loadSources();
    } catch (e) {
      NasSnack.showOn(
        messenger,
        tr('blog.local.addSourceFailed', {'error': '$e'}),
        error: true,
      );
    }
  }

  Future<void> _removeSource(BlogLocalSource source) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('blog.local.removeSource')),
        content: Text(tr('blog.local.removeSourceConfirm', {'name': source.name})),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('common.delete')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ApiSession.instance.client.blogLocalSourceRemove(
        body: BlogLocalSourceRemoveBody(id: source.id),
      );
      if (_source?.id == source.id) {
        setState(() {
          _source = null;
          _browse = null;
          _selecting = false;
          _selected.clear();
        });
      }
      await _loadSources();
    } catch (e) {
      NasSnack.showOn(messenger, '$e', error: true);
    }
  }

  Future<void> _openSource(BlogLocalSource source) async {
    setState(() {
      _source = source;
      _browse = null;
      _selecting = false;
      _selected.clear();
    });
    await _browseDir(null);
  }

  Future<void> _browseDir(String? path) async {
    final source = _source;
    if (source == null) return;
    setState(() {
      _browseLoading = true;
      _selecting = false;
      _selected.clear();
    });
    try {
      final res = await ApiSession.instance.client.blogLocalBrowse(
        sourceId: source.id,
        path: path,
      );
      if (!mounted) return;
      setState(() {
        _browse = res;
        _browseLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _browseLoading = false);
      NasSnack.show(context, '$e', error: true);
    }
  }

  void _back() {
    final res = _browse;
    final source = _source;
    if (res == null || source == null) return;
    if (res.parent == null || res.path == source.path) {
      setState(() {
        _source = null;
        _browse = null;
        _selecting = false;
        _selected.clear();
      });
      return;
    }
    _browseDir(res.parent);
  }

  Future<void> _playAt(int index) async {
    final audios = _browse?.audios ?? const <BlogLocalAudio>[];
    if (index < 0 || index >= audios.length) return;
    final queue = audios.map(_toEpisode).toList(growable: false);
    await BlogPlayer.instance.play(
      queue[index],
      queue,
      kind: BlogPlaybackKind.localBlog,
    );
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const BlogPlayerPage()),
    );
    // 播放页回来时刷新当前目录：拿到「已听」标记与最新断点
    if (mounted) await _browseDir(_browse?.path);
  }

  static BlogEpisodeItem _toEpisode(BlogLocalAudio a) => BlogEpisodeItem(
        id: a.path,
        title: a.title,
        sourcePath: a.path,
        coverUrl: blogMediaUrl(a.coverUrl),
        voice: '',
        speed: 1,
        durationSec: 0,
        sizeBytes: a.size,
        itemCount: 0,
        status: 'done',
        error: null,
        parts: 0,
        doneParts: 0,
        sections: const <String>[],
        headlines: const <String>[],
        createdAt: 0,
        finishedAt: null,
      );

  Future<void> _addSelectedToCollection() async {
    if (_selected.isEmpty) return;
    final added = await showAddToBlogCollectionSheet(
      context,
      _selected.toList(growable: false),
    );
    if (added == null || !mounted) return;
    NasSnack.show(context, tr('blog.local.added', {'added': '$added'}));
  }

  Future<void> _deleteSelected() async {
    if (_selected.isEmpty) return;
    final paths = _selected.toList(growable: false);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('blog.local.delete')),
        content: Text(tr('blog.local.deleteConfirm', {'count': '${paths.length}'})),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('common.delete')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final res = await ApiSession.instance.client.blogLocalDelete(
        body: BlogLocalDeleteBody(paths: paths),
      );
      NasSnack.showOn(
        messenger,
        tr('blog.local.deleteDone', {'count': '${res.deleted}'}),
      );
      await _browseDir(_browse?.path);
    } catch (e) {
      NasSnack.showOn(
        messenger,
        tr('blog.local.deleteFailed', {'error': '$e'}),
        error: true,
      );
    }
  }

  // ---------------------------------------------------------------- 构建

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _header(context),
        Expanded(child: _body(context)),
      ],
    );
  }

  Widget _header(BuildContext context) {
    final source = _source;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        NasTokens.spaceLg,
        NasTokens.spaceLg,
        NasTokens.spaceLg,
        NasTokens.spaceSm,
      ),
      child: Row(
        children: [
          if (source != null)
            IconButton(
              tooltip: tr('common.back'),
              onPressed: _back,
              icon: const Icon(Icons.arrow_back),
            ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  source == null ? tr('blog.local.title') : source.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: NasTokens.fontTitle,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  source == null
                      ? tr('blog.local.subtitle')
                      : source.path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: NasTokens.fontCaption,
                    color: context.nasTextSecondary,
                  ),
                ),
              ],
            ),
          ),
          if (source == null)
            TextButton.icon(
              onPressed: _addSource,
              icon: const Icon(Icons.create_new_folder_outlined, size: 18),
              label: Text(tr('blog.local.addSource')),
            ),
          if (source != null)
            NasSelectionToggleButton(
              active: _selecting,
              onPressed: () => setState(() {
                _selecting = !_selecting;
                if (!_selecting) _selected.clear();
              }),
            ),
          IconButton(
            tooltip: tr('blog.refresh'),
            onPressed: source == null ? _loadSources : () => _browseDir(_browse?.path),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
    );
  }

  Widget _body(BuildContext context) {
    if (_loading) return const NasLoading();
    if (_error != null) {
      return NasErrorState(message: _error!, onRetry: _loadSources);
    }
    if (_source == null) return _sourceList(context);
    return _browseView(context);
  }

  Widget _sourceList(BuildContext context) {
    if (_sources.isEmpty) {
      return NasEmptyState(
        title: tr('blog.local.sourcesEmpty'),
        message: tr('blog.local.sourcesEmptyHint'),
        icon: Icons.folder_outlined,
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(
        NasTokens.spaceLg,
        NasTokens.spaceSm,
        NasTokens.spaceLg,
        NasTokens.spaceLg,
      ),
      itemCount: _sources.length,
      separatorBuilder: (_, _) => const SizedBox(height: NasTokens.spaceSm),
      itemBuilder: (context, i) {
        final s = _sources[i];
        return NasCard(
          padding: EdgeInsets.zero,
          child: ListTile(
            leading: const Icon(Icons.folder_outlined),
            title: Text(
              s.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              s.path,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: NasTokens.fontCaption,
                color: context.nasTextSecondary,
              ),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: tr('blog.refresh'),
                  onPressed: () => _openSource(s),
                  icon: const Icon(Icons.refresh),
                ),
                IconButton(
                  tooltip: tr('blog.local.removeSource'),
                  onPressed: () => _removeSource(s),
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
            onTap: () => _openSource(s),
          ),
        );
      },
    );
  }

  Widget _browseView(BuildContext context) {
    if (_browseLoading && _browse == null) return const NasLoading();
    final res = _browse;
    if (res == null) return const NasLoading();
    final empty = res.dirs.isEmpty && res.audios.isEmpty;
    if (empty) {
      return NasEmptyState(
        title: tr('blog.local.browseEmpty'),
        icon: Icons.podcasts_outlined,
      );
    }
    return NasSelectionOverlay(
      bar: _selecting && _selected.isNotEmpty ? _selectionBar() : null,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(
          NasTokens.spaceLg,
          NasTokens.spaceSm,
          NasTokens.spaceLg,
          96,
        ),
        children: [
          _breadcrumb(context, res),
          const SizedBox(height: NasTokens.spaceXs),
          for (final d in res.dirs) _dirTile(context, d),
          if (res.dirs.isNotEmpty && res.audios.isNotEmpty)
            const Divider(height: NasTokens.spaceLg),
          for (var i = 0; i < res.audios.length; i += 1)
            _audioTile(context, res.audios[i], i),
          if (res.audios.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: NasTokens.spaceMd),
              child: Text(
                tr('blog.local.browseEmpty'),
                style: TextStyle(
                  fontSize: NasTokens.fontCaption,
                  color: context.nasTextSecondary,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _breadcrumb(BuildContext context, BlogLocalBrowseResponse res) {
    final source = _source!;
    final sourcePath = source.path.replaceAll(RegExp(r'/+$'), '');
    final current = res.path;
    final rel = current.length > sourcePath.length
        ? current.substring(sourcePath.length)
        : '';
    final segs = rel.split('/').where((s) => s.isNotEmpty).toList();
    final crumbs = <Widget>[
      TextButton(
        onPressed: () => _browseDir(source.path),
        child: Text(source.name),
      ),
    ];
    var acc = sourcePath;
    for (final seg in segs) {
      acc = '$acc/$seg';
      final target = acc;
      crumbs.add(
        const Icon(Icons.chevron_right, size: 16),
      );
      crumbs.add(
        TextButton(
          onPressed: () => _browseDir(target),
          child: Text(seg),
        ),
      );
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: crumbs),
    );
  }

  Widget _dirTile(BuildContext context, BlogLocalDir d) {
    final checked = _selected.contains(d.path);
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.folder_outlined),
      title: Text(d.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: _selecting
          ? Checkbox(
              value: checked,
              onChanged: (v) => setState(() {
                if (v == true) {
                  _selected.add(d.path);
                } else {
                  _selected.remove(d.path);
                }
              }),
            )
          : const Icon(Icons.chevron_right),
      onTap: () {
        if (!_selecting) {
          _browseDir(d.path);
          return;
        }
        setState(() {
          if (!checked) {
            _selected.add(d.path);
          } else {
            _selected.remove(d.path);
          }
        });
      },
      onLongPress: () => setState(() {
        _selecting = true;
        if (!checked) {
          _selected.add(d.path);
        } else {
          _selected.remove(d.path);
        }
      }),
    );
  }

  Widget _audioTile(BuildContext context, BlogLocalAudio a, int index) {
    final checked = _selected.contains(a.path);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: SizedBox(
        width: 48,
        height: 48,
        child: _thumb(a.coverUrl),
      ),
      title: Text(
        a.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Row(
        children: [
          Text(
            _sizeText(a.size),
            style: TextStyle(fontSize: NasTokens.fontCaption, color: context.nasTextSecondary),
          ),
          if (a.listened) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                tr('blog.local.listened'),
                style: TextStyle(
                  fontSize: NasTokens.fontCaption - 1,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
          ],
        ],
      ),
      trailing: _selecting
          ? Checkbox(
              value: checked,
              onChanged: (v) => setState(() {
                if (v == true) {
                  _selected.add(a.path);
                } else {
                  _selected.remove(a.path);
                }
              }),
            )
          : null,
      onTap: () {
        if (!_selecting) {
          _playAt(index);
          return;
        }
        setState(() {
          if (!checked) {
            _selected.add(a.path);
          } else {
            _selected.remove(a.path);
          }
        });
      },
      onLongPress: () => setState(() {
        _selecting = true;
        if (!checked) {
          _selected.add(a.path);
        } else {
          _selected.remove(a.path);
        }
      }),
    );
  }

  Widget _thumb(String? coverUrl) {
    if (coverUrl == null || coverUrl.isEmpty) {
      return Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(NasTokens.radiusSm),
        ),
        child: const Icon(Icons.podcasts, size: 22),
      );
    }
    return NasCoverImage(
      url: blogMediaUrl(coverUrl),
      icon: Icons.podcasts,
      cacheWidth: 128,
      borderRadius: NasTokens.radiusSm,
    );
  }

  Widget _selectionBar() {
    final res = _browse;
    final all = <String>[
      for (final d in res?.dirs ?? const <BlogLocalDir>[]) d.path,
      for (final a in res?.audios ?? const <BlogLocalAudio>[]) a.path,
    ];
    return NasSelectionFloatingBar(
      title: tr('blog.local.selected', {'count': '${_selected.length}'}),
      allSelected: all.isNotEmpty && all.every(_selected.contains),
      onToggleAll: () => setState(() {
        if (all.isNotEmpty && all.every(_selected.contains)) {
          _selected.clear();
        } else {
          _selected
            ..clear()
            ..addAll(all);
        }
      }),
      onClose: () => setState(() {
        _selecting = false;
        _selected.clear();
      }),
      actions: [
        NasSelectionAction(
          label: tr('blog.local.addToCollection'),
          icon: Icons.playlist_add,
          onPressed: _addSelectedToCollection,
        ),
        NasSelectionAction(
          label: tr('blog.local.delete'),
          icon: Icons.delete_outline,
          danger: true,
          onPressed: _deleteSelected,
        ),
      ],
    );
  }

  static String _sizeText(int bytes) {
    if (bytes <= 0) return '';
    const units = ['B', 'KB', 'MB', 'GB'];
    var v = bytes.toDouble();
    var i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i += 1;
    }
    return '${v.toStringAsFixed(i == 0 ? 0 : 1)} ${units[i]}';
  }
}

class _SourceDraft {
  const _SourceDraft({required this.name, required this.path});

  final String name;
  final String path;
}

/// 添加目录源：名称可选（默认文件夹名），路径通过公共文件夹选择器挑选。
class _AddSourceDialog extends StatefulWidget {
  const _AddSourceDialog();

  @override
  State<_AddSourceDialog> createState() => _AddSourceDialogState();
}

class _AddSourceDialogState extends State<_AddSourceDialog> {
  final TextEditingController _nameCtrl = TextEditingController();
  String _path = '';

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final picked = await showFolderPicker(
      context,
      initialPath: _path.isEmpty ? null : _path,
      title: tr('blog.local.pickFolder'),
    );
    if (picked == null || !mounted) return;
    setState(() => _path = picked);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(tr('blog.local.addSourceTitle')),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _nameCtrl,
              decoration: InputDecoration(
                labelText: tr('blog.local.sourceName'),
                hintText: tr('blog.local.sourceNameHint'),
              ),
            ),
            const SizedBox(height: NasTokens.spaceMd),
            Text(
              tr('blog.local.sourcePath'),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: NasTokens.spaceXs),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _path.isEmpty ? '—' : _path,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                ),
                const SizedBox(width: NasTokens.spaceSm),
                OutlinedButton.icon(
                  onPressed: _pick,
                  icon: const Icon(Icons.folder_open, size: 18),
                  label: Text(tr('blog.local.pickFolder')),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr('common.cancel')),
        ),
        FilledButton(
          onPressed: _path.isEmpty
              ? null
              : () => Navigator.pop(
                    context,
                    _SourceDraft(name: _nameCtrl.text.trim(), path: _path),
                  ),
          child: Text(tr('common.confirm')),
        ),
      ],
    );
  }
}
