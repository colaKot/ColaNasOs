import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';
import '../../shell/app_widgets.dart';

import '../../core/session.dart';
import '../../shell/mobile_frame.dart';

/// 笔记（SP3-06 客户端）：列表 + 编辑 + 版本历史。
///
/// 宽屏为列表 / 编辑器双栏，窄屏点条目进入独立编辑页；每次保存都会在服务端
/// 留下历史版本，可在「版本」里查看并回滚（回滚本身也生成新版本）。
/// yjs 实时协同尚未接入，目前是单端编辑 + 服务端版本树。
class NotesPage extends StatefulWidget {
  const NotesPage({super.key});

  @override
  State<NotesPage> createState() => _NotesPageState();
}

class _NotesPageState extends State<NotesPage> {
  final _search = TextEditingController();
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _items = const [];
  String? _selectedId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ApiSession.instance.client.noteList(
        q: _search.text.trim().isEmpty ? null : _search.text.trim(),
      );
      if (!mounted) return;
      setState(() {
        _items = (res['items'] as List<dynamic>? ?? const [])
            .map((e) => (e as Map).cast<String, dynamic>())
            .toList();
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

  void _createDraft() {
    setState(() => _selectedId = null);
    if (useTwoPane(MediaQuery.sizeOf(context).width)) return;
    _openEditor(null);
  }

  void _openEditor(String? id) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(
            title: Text(id == null ? tr('ui.notes.001') : tr('ui.notes.002')),
          ),
          body: _NoteEditor(
            noteId: id,
            onChanged: _load,
            onClose: () => Navigator.of(context).pop(),
          ),
        ),
      ),
    );
  }

  /// 列表右键菜单（桌面 / Web）：与编辑器里同一批动作，不必先点进去。
  List<NasMenuEntry> _noteMenuEntries(Map<String, dynamic> n) {
    final id = n['id'] as String? ?? '';
    if (id.isEmpty) return const [];
    final pinned = n['pinned'] == true;
    return [
      NasMenuEntry(
        label: tr('common.open'),
        icon: Icons.open_in_new,
        onSelected: () {
          if (useTwoPane(MediaQuery.sizeOf(context).width)) {
            setState(() => _selectedId = id);
          } else {
            _openEditor(id);
          }
        },
      ),
      NasMenuEntry(
        label: tr('common.rename'),
        icon: Icons.drive_file_rename_outline,
        onSelected: () => _renameNote(id, n['title'] as String? ?? ''),
      ),
      NasMenuEntry(
        label: pinned ? tr('ui.notes.014') : tr('ui.notes.015'),
        icon: pinned ? Icons.push_pin_outlined : Icons.push_pin,
        onSelected: () => _pinNote(id, !pinned),
      ),
      const NasMenuEntry.divider(),
      NasMenuEntry(
        label: tr('common.delete'),
        icon: Icons.delete_outline,
        danger: true,
        onSelected: () => _deleteNote(id, n['title'] as String? ?? ''),
      ),
    ];
  }

  Future<void> _renameNote(String id, String current) async {
    final ctrl = TextEditingController(text: current);
    final title = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('common.rename')),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(hintText: tr('ui.notes.020')),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: Text(tr('common.confirm')),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (title == null || title.isEmpty || title == current || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      // 只带 title：服务端对未出现的字段保留原值，不会把正文清掉
      await ApiSession.instance.client.noteUpdate(body: {'id': id, 'title': title});
      await _load();
    } catch (e) {
      NasSnack.showOn(messenger, tr('common.saveFailed', {'error': '$e'}));
    }
  }

  Future<void> _pinNote(String id, bool pinned) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ApiSession.instance.client.noteUpdate(body: {'id': id, 'pinned': pinned});
      await _load();
    } catch (e) {
      NasSnack.showOn(messenger, tr('notes.pinFailed', {'error': '$e'}));
    }
  }

  Future<void> _deleteNote(String id, String title) async {
    final ok = await NasConfirmDialog.show(
      context,
      title: tr('ui.notes.008'),
      message: tr('ui.notes.h7aeae1'),
      danger: true,
      confirmText: tr('ui.notes.017'),
    );
    if (!ok || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ApiSession.instance.client.noteRemove(body: {'id': id});
      if (_selectedId == id) setState(() => _selectedId = null);
      await _load();
    } catch (e) {
      NasSnack.showOn(messenger, tr('common.deleteFailed', {'error': '$e'}));
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = useTwoPane(constraints.maxWidth);
        final list = _buildList(wide);
        if (!wide) {
          return Scaffold(
            appBar: nasPageAppBar(
              context,
              title: tr('ui.notes.003'),
              actions: [
                IconButton(
                  icon: const Icon(Icons.add),
                  tooltip: tr('ui.notes.004'),
                  onPressed: _createDraft,
                ),
              ],
            ),
            body: list,
          );
        }
        return Scaffold(
          appBar: AppBar(
            title: Text(tr('ui.notes.003')),
            actions: [
              IconButton(
                icon: const Icon(Icons.add),
                tooltip: tr('ui.notes.004'),
                onPressed: _createDraft,
              ),
              NasRefreshButton(onPressed: _load),
            ],
          ),
          body: Row(
            children: [
              SizedBox(width: 340, child: list),
              const VerticalDivider(width: 1),
              Expanded(
                child: _NoteEditor(
                  key: ValueKey(_selectedId ?? 'draft'),
                  noteId: _selectedId,
                  onChanged: _load,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildList(bool wide) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            NasTokens.spaceMd,
            NasTokens.spaceMd,
            NasTokens.spaceMd,
            0,
          ),
          child: NasSearchField(
            controller: _search,
            hintText: tr('ui.notes.005'),
            onSubmitted: (_) => _load(),
            onClear: () {
              _search.clear();
              _load();
            },
          ),
        ),
        Expanded(
          child: _loading
              ? const NasLoading()
              : _error != null
              ? NasErrorState(message: _error!, onRetry: _load)
              : _items.isEmpty
              ? NasEmptyState(
                  title: tr('ui.notes.006'),
                  message: tr('ui.notes.h13cc56'),
                  icon: Icons.sticky_note_2_outlined,
                )
              : ListView.separated(
                  itemCount: _items.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final n = _items[i];
                    final id = n['id'] as String? ?? '';
                    final tags = (n['tags'] as List<dynamic>? ?? const []).join(
                      ' · ',
                    );
                    final updatedAt = (n['updatedAt'] as num?)?.toInt() ?? 0;
                    return NasContextMenuRegion(
                      entries: _noteMenuEntries(n),
                      child: ListTile(
                        selected: wide && id == _selectedId,
                        leading: Icon(
                          n['pinned'] == true
                              ? Icons.push_pin
                              : Icons.sticky_note_2_outlined,
                          size: NasTokens.iconMd,
                        ),
                        title: Text(
                          n['title'] as String? ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          [
                            if (tags.isNotEmpty) tags,
                            n['excerpt'] as String? ?? '',
                            if (updatedAt > 0) formatDateTimeSec(updatedAt),
                          ].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () {
                          if (wide) {
                            setState(() => _selectedId = id);
                          } else {
                            _openEditor(id);
                          }
                        },
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// 单篇编辑器：保存（含版本落盘）、置顶、标签、版本历史与回滚、删除。
class _NoteEditor extends StatefulWidget {
  const _NoteEditor({
    super.key,
    required this.noteId,
    required this.onChanged,
    this.onClose,
  });

  final String? noteId;
  final VoidCallback onChanged;
  final VoidCallback? onClose;

  @override
  State<_NoteEditor> createState() => _NoteEditorState();
}

class _NoteEditorState extends State<_NoteEditor> {
  final _titleCtrl = TextEditingController();
  final _tagsCtrl = TextEditingController();
  final _bodyCtrl = TextEditingController();

  bool _loading = false;
  String? _error;
  String? _id;
  bool _pinned = false;
  bool _dirty = false;
  bool _saving = false;
  bool _preview = false;
  int _updatedAt = 0;

  /// 乐观锁版本号：保存时带回 baseVersion，服务端版本不一致会返回 409
  int _version = 1;

  @override
  void initState() {
    super.initState();
    _id = widget.noteId;
    _titleCtrl.addListener(_markDirty);
    _tagsCtrl.addListener(_markDirty);
    _bodyCtrl.addListener(_markDirty);
    if (_id != null) _load(_id!);
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _tagsCtrl.dispose();
    _bodyCtrl.dispose();
    super.dispose();
  }

  void _markDirty() {
    if (!_dirty) setState(() => _dirty = true);
  }

  Future<void> _load(String id) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final note = await ApiSession.instance.client.noteGet(id: id);
      if (!mounted) return;
      setState(() {
        _id = id;
        _titleCtrl.text = note['title'] as String? ?? '';
        _bodyCtrl.text = note['body'] as String? ?? '';
        _tagsCtrl.text = (note['tags'] as List<dynamic>? ?? const []).join(
          ', ',
        );
        _pinned = note['pinned'] == true;
        _updatedAt = (note['updatedAt'] as num?)?.toInt() ?? 0;
        _version = (note['version'] as num?)?.toInt() ?? 1;
        _dirty = false;
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

  List<String> _tags() => _tagsCtrl.text
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .take(20)
      .toList();

  Future<bool> _save({int? forceBaseVersion}) async {
    if (_saving) return false;
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    final title = _titleCtrl.text.trim().isEmpty
        ? tr('ui.notes.h355630')
        : _titleCtrl.text.trim();
    try {
      final body = <String, dynamic>{
        'title': title,
        'body': _bodyCtrl.text,
        'tags': _tags(),
      };
      Map<String, dynamic> saved;
      if (_id == null) {
        saved = await ApiSession.instance.client.noteCreate(body: body);
      } else {
        saved = await ApiSession.instance.client.noteUpdate(
          body: {
            ...body,
            'id': _id,
            'baseVersion': forceBaseVersion ?? _version,
          },
        );
      }
      if (!mounted) return false;
      setState(() {
        _id = saved['id'] as String? ?? _id;
        _updatedAt = (saved['updatedAt'] as num?)?.toInt() ?? _updatedAt;
        _version = (saved['version'] as num?)?.toInt() ?? _version;
        _dirty = false;
      });
      NasSnack.showOn(messenger, tr('ui.notes.007'));
      widget.onChanged();
      return true;
    } on ApiError catch (e) {
      if (e.statusCode != 409) {
        NasSnack.showOn(messenger, tr('common.saveFailed', {'error': e.message}));
        return false;
      }
      // 服务端版本已前进：让用户决定用最新版本还是覆盖
      final details = e.details is Map
          ? Map<String, dynamic>.from(e.details as Map)
          : <String, dynamic>{};
      final latest = (details['version'] as num?)?.toInt() ?? _version;
      if (!mounted) return false;
      setState(() => _saving = false);
      final choice = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(tr('ui.notes.h_conflictTitle')),
          content: Text(tr('ui.notes.h_conflictBody')),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr('common.cancel')),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'reload'),
              child: Text(tr('ui.notes.h_conflictReload')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, 'overwrite'),
              child: Text(tr('ui.notes.h_conflictOverwrite')),
            ),
          ],
        ),
      );
      if (choice == 'reload') {
        if (!mounted) return false;
        setState(() {
          _titleCtrl.text = details['title']?.toString() ?? _titleCtrl.text;
          _bodyCtrl.text = details['body']?.toString() ?? _bodyCtrl.text;
          _tagsCtrl.text =
              (details['tags'] as List?)?.join(', ') ?? _tagsCtrl.text;
          _pinned = details['pinned'] == true;
          _version = latest;
          _updatedAt = (details['updatedAt'] as num?)?.toInt() ?? _updatedAt;
          _dirty = false;
        });
        NasSnack.showOn(messenger, tr('ui.notes.h_conflictReloaded'));
        return true;
      }
      if (choice == 'overwrite') {
        return _save(forceBaseVersion: latest);
      }
      return false;
    } catch (e) {
      NasSnack.showOn(messenger, tr('common.saveFailed', {'error': '$e'}));
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _togglePin() async {
    if (_id == null) return;
    final next = !_pinned;
    try {
      final saved = await ApiSession.instance.client.noteUpdate(
        body: {'id': _id, 'pinned': next, 'baseVersion': _version},
      );
      if (!mounted) return;
      setState(() {
        _pinned = next;
        _version = (saved['version'] as num?)?.toInt() ?? _version;
      });
      widget.onChanged();
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, tr('notes.pinFailed', {'error': '$e'}), error: true);
    }
  }

  Future<void> _delete() async {
    final id = _id;
    if (id == null) return;
    final ok = await NasConfirmDialog.show(
      context,
      title: tr('ui.notes.008'),
      message: tr('ui.notes.h7aeae1'),
      danger: true,
      confirmText: tr('ui.notes.017'),
    );
    if (!ok || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ApiSession.instance.client.noteRemove(body: {'id': id});
      NasSnack.showOn(messenger, tr('ui.notes.009'));
      widget.onChanged();
      widget.onClose?.call();
    } catch (e) {
      NasSnack.showOn(messenger, tr('common.deleteFailed', {'error': '$e'}));
    }
  }

  Future<void> _showVersions() async {
    final id = _id;
    if (id == null) {
      NasSnack.show(context, tr('ui.notes.h3bebd0'), error: true);
      return;
    }
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    List<Map<String, dynamic>> versions;
    try {
      final res = await ApiSession.instance.client.noteVersions(id: id);
      versions = (res['items'] as List<dynamic>? ?? const [])
          .map((e) => (e as Map).cast<String, dynamic>())
          .toList();
    } catch (e) {
      NasSnack.showOn(messenger, tr('notes.versionLoadFailed', {'error': '$e'}));
      return;
    }
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('notes.versionTitle', {'count': '${versions.length}'})),
        content: SizedBox(
          width: 520,
          height: 360,
          child: versions.isEmpty
              ? Align(
                  alignment: Alignment.topLeft,
                  child: Text(tr('ui.notes.010')),
                )
              : ListView.separated(
                  itemCount: versions.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (c, i) {
                    final v = versions[i];
                    final at = (v['createdAt'] as num?)?.toInt() ?? 0;
                    return ListTile(
                      dense: true,
                      title: Text(
                        v['title'] as String? ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        [
                          if (at > 0) formatDateTimeSec(at),
                          tr('notes.versionAuthor', {'author': '${v['author'] ?? '-'}'}),
                        ].join(' · '),
                        style: const TextStyle(fontSize: NasTokens.fontCaption),
                      ),
                      trailing: TextButton(
                        onPressed: () async {
                          Navigator.pop(ctx);
                          await _restore(v['id'] as String? ?? '');
                        },
                        child: Text(tr('ui.notes.011')),
                      ),
                      onTap: () => _previewVersion(v),
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
  }

  void _previewVersion(Map<String, dynamic> version) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(version['title'] as String? ?? ''),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: MarkdownBody(
              data: version['body'] as String? ?? '',
              selectable: true,
            ),
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('common.close')),
          ),
        ],
      ),
    );
  }

  Future<void> _restore(String versionId) async {
    final id = _id;
    if (id == null || versionId.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final restored = await ApiSession.instance.client.noteRestore(
        body: {'id': id, 'versionId': versionId},
      );
      NasSnack.showOn(messenger, tr('ui.notes.012'));
      if (!mounted) return;
      setState(() {
        _titleCtrl.text = restored['title'] as String? ?? '';
        _bodyCtrl.text = restored['body'] as String? ?? '';
        _tagsCtrl.text = (restored['tags'] as List<dynamic>? ?? const []).join(
          ', ',
        );
        _updatedAt = (restored['updatedAt'] as num?)?.toInt() ?? _updatedAt;
        _dirty = false;
      });
      widget.onChanged();
    } catch (e) {
      NasSnack.showOn(messenger, tr('notes.restoreFailed', {'error': '$e'}));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const NasLoading();
    if (_error != null) {
      return NasErrorState(message: _error!, onRetry: () => _load(_id ?? ''));
    }

    if (_id == null &&
        _titleCtrl.text.isEmpty &&
        _bodyCtrl.text.isEmpty &&
        !_dirty) {
      return NasEmptyState(
        title: tr('ui.notes.001'),
        message: tr('ui.notes.h78f683'),
        icon: Icons.edit_note,
        action: FilledButton.icon(
          onPressed: () => setState(() => _dirty = true),
          icon: const Icon(Icons.edit),
          label: Text(tr('ui.notes.013')),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.all(NasTokens.spaceMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _dirty
                      ? tr('ui.notes.h6a5c4d')
                      : (_updatedAt > 0
                            ? tr('notes.savedAt', {'time': formatDateTimeSec(_updatedAt)})
                            : tr('ui.notes.h5174c5')),
                  style: TextStyle(
                    fontSize: NasTokens.fontCaption,
                    color: _dirty
                        ? Color(NasTokens.colorWarning)
                        : context.nasTextSecondary,
                  ),
                ),
              ),
              IconButton(
                tooltip: _pinned ? tr('ui.notes.014') : tr('ui.notes.015'),
                icon: Icon(_pinned ? Icons.push_pin : Icons.push_pin_outlined),
                onPressed: _id == null ? null : _togglePin,
              ),
              IconButton(
                tooltip: _preview
                    ? tr('notes.edit')
                    : tr('notes.preview'),
                icon: Icon(
                  _preview ? Icons.edit_outlined : Icons.visibility_outlined,
                ),
                onPressed: () => setState(() => _preview = !_preview),
              ),
              IconButton(
                tooltip: tr('ui.notes.016'),
                icon: const Icon(Icons.history),
                onPressed: _showVersions,
              ),
              if (_id != null)
                IconButton(
                  tooltip: tr('ui.notes.017'),
                  icon: const Icon(Icons.delete_outline),
                  onPressed: _delete,
                ),
              const SizedBox(width: NasTokens.spaceXs),
              FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: NasTokens.iconSm,
                        height: NasTokens.iconSm,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_outlined),
                label: Text(_saving ? tr('ui.notes.018') : tr('ui.notes.019')),
              ),
            ],
          ),
          const SizedBox(height: NasTokens.spaceSm),
          TextField(
            controller: _titleCtrl,
            style: const TextStyle(fontSize: NasTokens.fontHeadline),
            decoration: InputDecoration(
              hintText: tr('ui.notes.020'),
              border: InputBorder.none,
              contentPadding: EdgeInsets.zero,
            ),
          ),
          const Divider(height: 1),
          const SizedBox(height: NasTokens.spaceSm),
          TextField(
            controller: _tagsCtrl,
            decoration: InputDecoration(
              labelText: tr('ui.notes.021'),
              isDense: true,
            ),
          ),
          const SizedBox(height: NasTokens.spaceSm),
          Expanded(
            child: _preview
                ? SizedBox(
                    width: double.infinity,
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(
                        vertical: NasTokens.spaceSm,
                      ),
                      child: MarkdownBody(
                        data: _bodyCtrl.text.trim().isEmpty
                            ? tr('notes.previewEmpty')
                            : _bodyCtrl.text,
                        selectable: true,
                        styleSheet:
                            MarkdownStyleSheet.fromTheme(Theme.of(context))
                                .copyWith(
                                  p: const TextStyle(
                                    fontSize: NasTokens.fontBody,
                                    height: 1.55,
                                  ),
                                ),
                      ),
                    ),
                  )
                : TextField(
                    controller: _bodyCtrl,
                    expands: true,
                    maxLines: null,
                    textAlignVertical: TextAlignVertical.top,
                    style: const TextStyle(
                      fontSize: NasTokens.fontBody,
                      fontFamily: 'monospace',
                    ),
                    decoration: InputDecoration(
                      hintText: tr('ui.notes.022'),
                      border: InputBorder.none,
                      alignLabelWithHint: true,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
