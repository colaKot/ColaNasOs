import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import '../photo/folder_picker.dart';

/// 影视库管理。
///
/// 以前这里是**两页**：库管理 + 来源设置。但一个库本来就可以有多个来源目录，
/// 分两页只会让人以为「新建来源 = 新建一个库」，于是同一类片子散在几个盘上时，
/// 首页冒出好几个同名库。现在合成一页：库是主体，来源是它的一组目录，
/// 在创建 / 修改对话框里可以增删来源行。
class VideoLibrarySettingsPage extends StatefulWidget {
  const VideoLibrarySettingsPage({super.key, this.onLibrariesChanged});

  final VoidCallback? onLibrariesChanged;

  @override
  State<VideoLibrarySettingsPage> createState() => _VideoLibrarySettingsPageState();
}

class _VideoLibrarySettingsPageState extends State<VideoLibrarySettingsPage> {
  bool _loading = true;
  bool _busy = false;
  String? _error;
  List<VideoLibraryItem> _libs = const [];

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
      final res = await ApiSession.instance.client.videoLibraryList();
      if (!mounted) return;
      setState(() {
        _libs = res.items;
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

  void _toast(String text) {
    if (!mounted) return;
    NasSnack.show(context, text);
  }

  Future<void> _add() async {
    final form = await showVideoLibraryDialog(context);
    if (form == null) return;
    await _save(form);
  }

  Future<void> _edit(VideoLibraryItem lib) async {
    final form = await showVideoLibraryDialog(context, library: lib);
    if (form == null) return;
    await _save(form, lib);
  }

  Future<void> _save(VideoLibraryForm form, [VideoLibraryItem? lib]) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final client = ApiSession.instance.client;
      if (lib == null) {
        await client.videoLibraryCreate(body: form.toCreate());
        // 服务端建完库会立刻入队扫描；这一步可能几十秒，先说清楚，
        // 免得用户看到「库是空的」以为没生效。
        _toast(tr('video.library.savedScanning'));
      } else {
        await client.videoLibraryUpdate(body: form.toUpdate(lib.id));
        _toast(tr('video.library.saved'));
      }
      await _load();
      widget.onLibrariesChanged?.call();
    } catch (e) {
      _toast(tr('common.saveFailed', {'error': '$e'}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 库级开关：这些列早就在库里（082/085 迁移），但一直没有写入口，
  /// 用户没法让某个库"不上首页"、也没法打开「入库即刮」。
  Future<void> _flags(VideoLibraryItem lib) async {
    var showInHome = (lib.showInHome ?? 1) == 1;
    var scrapeEnabled = (lib.scrapeEnabled ?? 1) == 1;
    var autoScrape = (lib.autoScrape ?? 0) == 1;
    var autoSubtitle = (lib.autoSubtitle ?? 0) == 1;
    var audioNormalize = (lib.audioNormalize ?? 0) == 1;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(tr('video.library.flagsTitle', {'name': lib.name})),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(tr('video.library.showInHome')),
                  subtitle: Text(tr('video.library.showInHomeHint')),
                  value: showInHome,
                  onChanged: (v) => setLocal(() => showInHome = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(tr('video.library.scrapeEnabled')),
                  subtitle: Text(tr('video.library.scrapeEnabledHint')),
                  value: scrapeEnabled,
                  onChanged: (v) => setLocal(() {
                    scrapeEnabled = v;
                    // 关了刮削，自动刮削跟着失效，避免"开着但永远不跑"的迷惑状态
                    if (!v) autoScrape = false;
                  }),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(tr('video.library.autoScrape')),
                  subtitle: Text(tr('video.library.autoScrapeHint')),
                  value: autoScrape,
                  onChanged: scrapeEnabled ? (v) => setLocal(() => autoScrape = v) : null,
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(tr('video.library.autoSubtitle')),
                  subtitle: Text(tr('video.library.autoSubtitleHint')),
                  value: autoSubtitle,
                  onChanged: (v) => setLocal(() => autoSubtitle = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(tr('video.library.audioNormalize')),
                  subtitle: Text(tr('video.library.audioNormalizeHint')),
                  value: audioNormalize,
                  onChanged: (v) => setLocal(() => audioNormalize = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('common.cancel'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('common.save'))),
          ],
        ),
      ),
    );
    if (ok != true || _busy) return;
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      await ApiSession.instance.client.videoLibraryFlags(
        body: VideoLibraryFlagsBody(
          id: lib.id,
          showInHome: showInHome,
          scrapeEnabled: scrapeEnabled,
          autoScrape: autoScrape,
          autoSubtitle: autoSubtitle,
          audioNormalize: audioNormalize,
        ),
      );
      _toast(tr('video.library.flagsSaved'));
      await _load();
      widget.onLibrariesChanged?.call();
    } catch (e) {
      _toast(tr('common.saveFailed', {'error': '$e'}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 逐个探测该库的 SMB 来源（一个库可能连几台机器，不能只探第一台）
  Future<void> _probe(VideoLibraryItem lib) async {
    if (_busy) return;
    final smb = (lib.sources ?? const <VideoSourceItem>[])
        .where((s) => s.connType == 'smb')
        .toList();
    if (smb.isEmpty) {
      _toast(tr('video.source.localOnly'));
      return;
    }
    setState(() => _busy = true);
    try {
      for (final s in smb) {
        await ApiSession.instance.client.videoSourceProbe(
          body: VideoSourceProbeBody(id: lib.id, sourceId: s.id),
        );
      }
      _toast(tr('video.source.probed'));
      await _load();
    } catch (e) {
      _toast(tr('common.getFailed', {'error': '$e'}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _scan(VideoLibraryItem lib) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      // 走任务队列而不是同步扫描：几万文件时同步接口会卡几分钟，页面只能转圈。
      // 进度与失败记录统一去「影视设置 → 搜刮任务」看。
      final r = await ApiSession.instance.client.videoScanEnqueue(body: {'libraryId': lib.id});
      final tasks = (r['tasks'] as List?) ?? const [];
      final reused = tasks.isNotEmpty && (tasks.first as Map)['reused'] == true;
      _toast(tr(reused ? 'video.scan.alreadyRunning' : 'video.scan.queued'));
      await _load();
    } catch (e) {
      _toast(tr('common.scanFailed', {'error': '$e'}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove(VideoLibraryItem lib) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('video.library.delete')),
        content: Text(tr('video.library.deleteBody', {'name': lib.name})),
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
    if (ok != true) return;
    try {
      await ApiSession.instance.client.videoLibraryRemove(
        body: VideoLibraryRemoveBody(id: lib.id),
      );
      await _load();
      widget.onLibrariesChanged?.call();
    } catch (e) {
      _toast(tr('common.deleteFailed', {'error': '$e'}));
    }
  }

  /// 拖拽排序：拖动结束后按新顺序写 sort_order（索引 × 10，留出手插空位）。
  /// 用 `onReorderItem`：newIndex 已经由框架按"先移除后插入"校正过，不需要自己减一。
  Future<void> _reorder(int oldIndex, int newIndex) async {
    if (_busy) return;
    final next = <VideoLibraryItem>[..._libs];
    final moved = next.removeAt(oldIndex);
    next.insert(newIndex, moved);
    setState(() => _libs = next);
    setState(() => _busy = true);
    try {
      final client = ApiSession.instance.client;
      for (var i = 0; i < next.length; i += 1) {
        await client.videoLibraryFlags(
          body: VideoLibraryFlagsBody(id: next[i].id, sortOrder: (i + 1) * 10),
        );
      }
      widget.onLibrariesChanged?.call();
    } catch (e) {
      _toast(tr('common.saveFailed', {'error': '$e'}));
      await _load();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _libCard(VideoLibraryItem lib) {
    final sources = lib.sources ?? const <VideoSourceItem>[];
    final smbCount = sources.where((s) => s.connType == 'smb').length;
    final paths = sources.isEmpty ? lib.path : sources.map((s) => s.path).join('\n');
    return Padding(
      padding: const EdgeInsets.only(bottom: NasTokens.spaceSm),
      child: NasCard(
        padding: const EdgeInsets.all(NasTokens.spaceSm),
        child: Row(
          children: [
            ReorderableDragStartListener(
              index: _libs.indexWhere((x) => x.id == lib.id),
              child: const Padding(
                padding: EdgeInsets.only(right: NasTokens.spaceXs),
                child: Icon(Icons.drag_indicator, size: 18),
              ),
            ),
            Icon(_libIcon(lib.libType)),
            const SizedBox(width: NasTokens.spaceSm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    lib.name,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    tr('video.library.meta', {
                      'type': _libTypeLabel(lib.libType),
                      'sources': '${sources.isEmpty ? 1 : sources.length}',
                      'count': '${lib.items}',
                    }),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: NasTokens.fontCaption,
                      color: context.nasTextSecondary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    paths,
                    maxLines: sources.length > 1 ? 3 : 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: NasTokens.fontMicro,
                      color: context.nasTextSecondary,
                    ),
                  ),
                ],
              ),
            ),
            if (smbCount > 0)
              IconButton(
                tooltip: tr('video.source.probe'),
                icon: const Icon(Icons.network_check),
                onPressed: _busy ? null : () => _probe(lib),
              ),
            IconButton(
              tooltip: tr('video.library.flags'),
              icon: const Icon(Icons.tune),
              onPressed: _busy ? null : () => _flags(lib),
            ),
            IconButton(
              tooltip: tr('video.library.edit'),
              icon: const Icon(Icons.edit_outlined),
              onPressed: _busy ? null : () => _edit(lib),
            ),
            IconButton(
              tooltip: tr('common.scanAll'),
              icon: const Icon(Icons.sync),
              onPressed: _busy ? null : () => _scan(lib),
            ),
            IconButton(
              tooltip: tr('video.library.delete'),
              icon: const Icon(Icons.delete_outline),
              onPressed: _busy ? null : () => _remove(lib),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const NasLoading();
    if (_error != null) return NasErrorState(message: _error!, onRetry: _load);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            NasTokens.spaceLg,
            NasTokens.spaceLg,
            NasTokens.spaceLg,
            0,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  tr('video.library.hint'),
                  style: TextStyle(
                    fontSize: NasTokens.fontCaption,
                    color: context.nasTextSecondary,
                  ),
                ),
              ),
              const SizedBox(width: NasTokens.spaceSm),
              FilledButton.icon(
                onPressed: _busy ? null : _add,
                icon: const Icon(Icons.add),
                label: Text(tr('video.library.add')),
              ),
            ],
          ),
        ),
        Expanded(
          child: _libs.isEmpty
              ? Padding(
                  padding: const EdgeInsets.only(top: NasTokens.spaceLg),
                  child: NasEmptyState(
                    title: tr('video.library.empty'),
                    message: tr('video.library.emptyHint'),
                    icon: Icons.video_library_outlined,
                  ),
                )
              : ReorderableListView.builder(
                  padding: const EdgeInsets.all(NasTokens.spaceLg),
                  itemCount: _libs.length,
                  onReorderItem: _reorder,
                  buildDefaultDragHandles: false,
                  itemBuilder: (context, i) => KeyedSubtree(
                    key: ValueKey(_libs[i].id),
                    child: _libCard(_libs[i]),
                  ),
                ),
        ),
      ],
    );
  }
}

IconData _libIcon(String type) => switch (type) {
  'tv' => Icons.live_tv_outlined,
  'jp_movie' => Icons.local_movies_outlined,
  'image' => Icons.image_outlined,
  'mixed' => Icons.perm_media_outlined,
  _ => Icons.movie_outlined,
};

String _libTypeLabel(String type) => switch (type) {
  'tv' => tr('video.library.type.tv'),
  'jp_movie' => tr('video.library.type.jp'),
  'image' => tr('video.library.type.image'),
  'mixed' => tr('video.library.type.mixed'),
  _ => tr('video.library.type.movie'),
};

/// 表单里的一个来源（与 API 的 VideoSourceInput 同构）
class VideoSourceSpec {
  const VideoSourceSpec({
    required this.connType,
    this.path = '',
    this.host = '',
    this.share = '',
    this.subPath = '',
    this.username = '',
    this.password = '',
  });

  final String connType;
  final String path;
  final String host;
  final String share;
  final String subPath;
  final String username;
  final String password;

  VideoSourceInput toInput() => VideoSourceInput(
    connType: connType,
    path: connType == 'local' ? path : null,
    host: connType == 'smb' ? host : null,
    share: connType == 'smb' ? share : null,
    subPath: connType == 'smb' ? subPath : null,
    username: connType == 'smb' && username.isNotEmpty ? username : null,
    // 空 = 沿用旧密码（服务端就是这么理解的）
    password: connType == 'smb' && password.isNotEmpty ? password : null,
  );
}

/// 表单结果：名称 / 类型 / 一组来源
class VideoLibraryForm {
  const VideoLibraryForm({
    required this.name,
    required this.libType,
    required this.sources,
  });

  final String name;
  final String libType;
  final List<VideoSourceSpec> sources;

  VideoLibraryCreateBody toCreate() => VideoLibraryCreateBody(
    name: name,
    libType: libType,
    sources: sources.map((s) => s.toInput()).toList(),
  );

  VideoLibraryUpdateBody toUpdate(String id) => VideoLibraryUpdateBody(
    id: id,
    name: name,
    libType: libType,
    sources: sources.map((s) => s.toInput()).toList(),
  );
}

({String host, String share, String subPath}) _parseUnc(String unc) {
  final parts = unc
      .replaceAll('/', r'\')
      .split(r'\')
      .where((p) => p.isNotEmpty)
      .toList();
  if (parts.length < 2) {
    return (host: '', share: '', subPath: '');
  }
  return (
    host: parts[0],
    share: parts[1],
    subPath: parts.skip(2).join('/'),
  );
}

/// 对话框里一行来源的可编辑状态
class _SourceDraft {
  _SourceDraft({
    required this.connType,
    String path = '',
    String host = '',
    String share = '',
    String subPath = '',
    String username = '',
  }) : pathCtrl = TextEditingController(text: path),
       hostCtrl = TextEditingController(text: host),
       shareCtrl = TextEditingController(text: share),
       subPathCtrl = TextEditingController(text: subPath),
       userCtrl = TextEditingController(text: username),
       passCtrl = TextEditingController();

  factory _SourceDraft.empty() => _SourceDraft(connType: 'local');

  factory _SourceDraft.fromItem(VideoSourceItem s) => _SourceDraft(
    connType: s.connType,
    path: s.connType == 'smb' ? '' : s.path,
    host: s.host ?? '',
    share: s.share ?? '',
    subPath: s.subPath ?? '',
    username: s.username ?? '',
  );

  String connType;
  final TextEditingController pathCtrl;
  final TextEditingController hostCtrl;
  final TextEditingController shareCtrl;
  final TextEditingController subPathCtrl;
  final TextEditingController userCtrl;
  final TextEditingController passCtrl;

  VideoSourceSpec toSpec() {
    // 用户常把完整 UNC 直接粘进「主机」：\\192.168.2.188\unity\Movies
    // 这里拆成 host / share / subPath，避免服务端把它当成空共享名。
    var host = hostCtrl.text.trim().replaceFirst(RegExp(r'^[\\/]+'), '');
    var share = shareCtrl.text.trim().replaceFirst(RegExp(r'^[\\/]+'), '');
    var sub = subPathCtrl.text.trim();
    final parts = host.split(RegExp(r'[\\/]+')).where((e) => e.isNotEmpty).toList();
    if (parts.length > 1) {
      host = parts[0];
      if (share.isEmpty && parts.length > 1) share = parts[1];
      if (parts.length > 2) {
        sub = [...parts.sublist(2), if (sub.isNotEmpty) sub].join('/');
      }
    }
    return VideoSourceSpec(
      connType: connType,
      path: pathCtrl.text.trim(),
      host: host,
      share: share,
      subPath: sub,
      username: userCtrl.text.trim(),
      password: passCtrl.text,
    );
  }

  void dispose() {
    pathCtrl.dispose();
    hostCtrl.dispose();
    shareCtrl.dispose();
    subPathCtrl.dispose();
    userCtrl.dispose();
    passCtrl.dispose();
  }
}

/// 新建 / 修改影视库共用对话框；返回 null 表示取消。
///
/// 「添加来源」按钮就在目录选择下面：同一个库可以挂多个目录 / 多台 SMB，
/// 片源在列表里合并展示（这就是把「库管理」和「来源设置」合成一页的原因）。
Future<VideoLibraryForm?> showVideoLibraryDialog(
  BuildContext context, {
  VideoLibraryItem? library,
}) async {
  final isEdit = library != null;
  final nameCtrl = TextEditingController(text: library?.name ?? '');
  var libType = library?.libType ?? 'movie';

  final existing = library?.sources ?? const <VideoSourceItem>[];
  final drafts = <_SourceDraft>[];
  if (existing.isNotEmpty) {
    for (final s in existing) {
      drafts.add(_SourceDraft.fromItem(s));
    }
  } else if (library != null) {
    // 老数据没有 sources（或刚好是空）：用库上的单来源字段铺一行
    final isSmb = library.connType == 'smb';
    final unc = isSmb ? _parseUnc(library.path) : (host: '', share: '', subPath: '');
    drafts.add(
      _SourceDraft(
        connType: library.connType ?? 'local',
        path: isSmb ? '' : library.path,
        host: unc.host,
        share: unc.share,
        subPath: unc.subPath,
      ),
    );
  } else {
    drafts.add(_SourceDraft.empty());
  }

  final result = await showDialog<VideoLibraryForm>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) => AlertDialog(
        backgroundColor: Theme.of(ctx).colorScheme.surface,
        title: Text(isEdit ? tr('video.library.edit') : tr('video.library.add')),
        content: Theme(
          data: Theme.of(ctx).copyWith(
            inputDecorationTheme: InputDecorationTheme(
              filled: true,
              fillColor: Theme.of(ctx).colorScheme.surfaceContainerHigh,
            ),
          ),
          child: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: nameCtrl,
                    decoration: InputDecoration(labelText: tr('ui.book.004')),
                  ),
                  const SizedBox(height: NasTokens.spaceSm),
                  NasDropdown<String>(
                    initialValue: libType,
                    dropdownColor: Theme.of(ctx).colorScheme.surface,
                    decoration: InputDecoration(labelText: tr('video.library.type')),
                    items: [
                      DropdownMenuItem(
                        value: 'movie',
                        child: Text(tr('video.library.type.movie')),
                      ),
                      DropdownMenuItem(
                        value: 'tv',
                        child: Text(tr('video.library.type.tv')),
                      ),
                      DropdownMenuItem(
                        value: 'jp_movie',
                        child: Text(tr('video.library.type.jp')),
                      ),
                      DropdownMenuItem(
                        value: 'image',
                        child: Text(tr('video.library.type.image')),
                      ),
                      DropdownMenuItem(
                        value: 'mixed',
                        child: Text(tr('video.library.type.mixed')),
                      ),
                    ],
                    // 库类型决定扫描 / 列表 / 删除的全部行为，创建后不可改
                    onChanged: isEdit ? null : (v) => setLocal(() => libType = v ?? 'movie'),
                  ),
                  const SizedBox(height: NasTokens.spaceSm),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          tr('video.library.sourcesHint'),
                          style: TextStyle(
                            fontSize: NasTokens.fontMicro,
                            color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      const SizedBox(width: NasTokens.spaceXs),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.add, size: 16),
                        label: Text(tr('video.library.addSource')),
                        onPressed: () =>
                            setLocal(() => drafts.add(_SourceDraft.empty())),
                      ),
                    ],
                  ),
                  const SizedBox(height: NasTokens.spaceXs),
                  for (var i = 0; i < drafts.length; i += 1)
                    _sourceRow(ctx, setLocal, drafts, i),
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('common.cancel')),
          ),
          FilledButton(
            onPressed: () {
              final name = nameCtrl.text.trim();
              if (name.isEmpty) {
                _dialogToast(ctx, tr('video.library.needName'));
                return;
              }
              if (drafts.isEmpty) {
                _dialogToast(ctx, tr('video.library.needSource'));
                return;
              }
              for (var i = 0; i < drafts.length; i += 1) {
                final d = drafts[i];
                final no = '${i + 1}';
                if (d.connType == 'local' && d.pathCtrl.text.trim().isEmpty) {
                  _dialogToast(ctx, tr('video.library.needSourcePath', {'n': no}));
                  return;
                }
                if (d.connType == 'smb') {
                  final hostText = d.hostCtrl.text.trim().replaceFirst(RegExp(r'^[\\/]+'), '');
                  final shareText = d.shareCtrl.text.trim();
                  final hasShare =
                      shareText.isNotEmpty ||
                      hostText.split(RegExp(r'[\\/]+')).where((e) => e.isNotEmpty).length > 1;
                  if (hostText.isEmpty || !hasShare) {
                    _dialogToast(ctx, tr('video.library.needSourceSmb', {'n': no}));
                    return;
                  }
                }
              }
              Navigator.pop(
                ctx,
                VideoLibraryForm(
                  name: name,
                  libType: libType,
                  sources: drafts.map((d) => d.toSpec()).toList(),
                ),
              );
            },
            child: Text(tr('common.save')),
          ),
        ],
      ),
    ),
  );

  for (final d in drafts) {
    d.dispose();
  }
  nameCtrl.dispose();
  return result;
}

Widget _sourceRow(
  BuildContext ctx,
  void Function(VoidCallback) setLocal,
  List<_SourceDraft> drafts,
  int i,
) {
  final d = drafts[i];
  return Padding(
    padding: const EdgeInsets.only(bottom: NasTokens.spaceSm),
    child: Container(
      padding: const EdgeInsets.all(NasTokens.spaceSm),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(ctx).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(NasTokens.radiusSm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                tr('video.library.sourceN', {'n': '${i + 1}'}),
                style: TextStyle(
                  fontSize: NasTokens.fontCaption,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: NasTokens.spaceSm),
              NasDropdown<String>(
                value: d.connType,
                isDense: true,
                underline: const SizedBox.shrink(),
                dropdownColor: Theme.of(ctx).colorScheme.surface,
                items: [
                  DropdownMenuItem(
                    value: 'local',
                    child: Text(tr('video.source.local')),
                  ),
                  DropdownMenuItem(
                    value: 'smb',
                    child: Text(tr('video.source.smb')),
                  ),
                ],
                onChanged: (v) => setLocal(() => d.connType = v ?? 'local'),
              ),
              const Spacer(),
              if (drafts.length > 1)
                IconButton(
                  tooltip: tr('video.library.removeSource'),
                  icon: const Icon(Icons.remove_circle_outline, size: 18),
                  onPressed: () => setLocal(() {
                    drafts.removeAt(i).dispose();
                  }),
                ),
            ],
          ),
          if (d.connType == 'local')
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: d.pathCtrl,
                    readOnly: true,
                    decoration: InputDecoration(
                      labelText: tr('ui.book.005'),
                      hintText: tr('video.library.pathHint'),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: NasTokens.spaceSm),
                OutlinedButton.icon(
                  icon: const Icon(Icons.folder_open, size: 18),
                  label: Text(tr('video.library.chooseDir')),
                  onPressed: () async {
                    final picked = await showFolderPicker(ctx);
                    if (picked != null && picked.isNotEmpty) {
                      setLocal(() => d.pathCtrl.text = picked);
                    }
                  },
                ),
              ],
            )
          else ...[
            TextField(
              controller: d.hostCtrl,
              decoration: InputDecoration(
                labelText: tr('video.smb.host'),
                hintText: '192.168.1.10',
                isDense: true,
              ),
            ),
            const SizedBox(height: NasTokens.spaceXs),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: d.shareCtrl,
                    decoration: InputDecoration(
                      labelText: tr('video.smb.share'),
                      hintText: 'media',
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: NasTokens.spaceXs),
                Expanded(
                  child: TextField(
                    controller: d.subPathCtrl,
                    decoration: InputDecoration(
                      labelText: tr('video.smb.subPath'),
                      hintText: 'Movies',
                      isDense: true,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: NasTokens.spaceXs),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: d.userCtrl,
                    decoration: InputDecoration(
                      labelText: tr('video.smb.user'),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: NasTokens.spaceXs),
                Expanded(
                  child: TextField(
                    controller: d.passCtrl,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: tr('video.smb.password'),
                      hintText: tr('video.library.passwordKeep'),
                      isDense: true,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    ),
  );
}

void _dialogToast(BuildContext context, String text) {
  NasSnack.show(context, text);
}
