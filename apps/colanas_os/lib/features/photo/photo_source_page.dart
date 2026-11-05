import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import '../../shell/app_widgets.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/photo_upload.dart';
import '../../core/session.dart';
import 'folder_picker.dart';

/// 相册来源：一个用户一个相册库，但**可以有多个来源目录**。
///
/// 每个来源就是 `photo_libraries` 里的一行（同 owner），时间轴/统计天然按 owner 聚合。
/// 「设置 → 来源」的卡片式布局：一张卡一个目录 + 刷新/删除，
/// 末尾一张「添加来源目录」卡片，点开是文件夹选择窗。
class PhotoSourcePage extends StatefulWidget {
  const PhotoSourcePage({super.key});

  @override
  State<PhotoSourcePage> createState() => _PhotoSourcePageState();
}

class _PhotoSourcePageState extends State<PhotoSourcePage> {
  bool _loading = true;
  bool _busy = false;
  String? _error;
  List<PhotoLibraryItem> _sources = const [];

  /// 扫描策略（自动监视 / 周期校验 / 跳过隐藏文件）
  PhotoScanPolicy? _policy;

  @override
  void initState() {
    super.initState();
    _load();
    _loadPolicy();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ApiSession.instance.client.photoLibraryList();
      if (!mounted) return;
      setState(() {
        _sources = res.items;
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

  Future<void> _scan({String? libraryId}) async {
    if (_busy) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      // 用户主动点重扫 = 重建：忽略 size/mtime，重读 EXIF（修正坏拍摄时间）
      final res = await ApiSession.instance.client.photoScan(
        body: PhotoScanBody(libraryId: libraryId, force: true),
      );
      NasSnack.showOn(messenger, 
            '${tr('common.scanAll')}: +${res.added} / ${res.skipped}',
          );
      await _load();
    } catch (e) {
      NasSnack.showOn(messenger, e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _add() async {
    final picked = await showDialog<String>(
      context: context,
      builder: (_) => const FolderPickerDialog(),
    );
    if (picked == null || picked.isEmpty) return;
    final name = picked.split('/').last;
    try {
      final created = await ApiSession.instance.client.photoLibraryCreate(
        body: PhotoLibraryCreateBody(name: name.isEmpty ? picked : name, path: picked),
      );
      if (!mounted) return;
      NasSnack.show(context, tr('photo.source.added'));
      await _load();
      await _scan(libraryId: created.id);
    } catch (e) {
      if (!mounted) return;
      final text = e.toString();
      NasSnack.show(context, 
            text.contains('409') || text.contains('UNIQUE')
                ? tr('photo.source.exists')
                : text,
          );
    }
  }

  Future<void> _remove(PhotoLibraryItem item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('photo.source.remove')),
        content: Text(item.path),
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
      await ApiSession.instance.client.photoLibraryRemove(
        body: PhotoLibraryRemoveBody(id: item.id),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, e.toString());
    }
  }


  Future<void> _loadPolicy() async {
    try {
      final policy = await ApiSession.instance.client.photoScanPolicy();
      if (!mounted) return;
      setState(() => _policy = policy);
    } catch (_) {
      // 策略读取失败不影响来源列表
    }
  }

  Future<void> _savePolicy({
    bool? autoWatch,
    int? verifyHours,
    bool? skipHidden,
  }) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final policy = await ApiSession.instance.client.photoScanPolicySet(
        body: PhotoScanPolicyUpdateBody(
          autoWatch: autoWatch,
          verifyHours: verifyHours,
          skipHidden: skipHidden,
        ),
      );
      if (!mounted) return;
      setState(() => _policy = policy);
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, tr('photo.source.savePolicyFailed', {'error': '$e'}), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _policyCard() {
    final policy = _policy;
    if (policy == null) return const SizedBox.shrink();
    const hours = [0, 1, 6, 24, 168];
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        NasTokens.spaceLg,
        NasTokens.spaceSm,
        NasTokens.spaceLg,
        0,
      ),
      child: NasCard(
        padding: const EdgeInsets.symmetric(
          horizontal: NasTokens.spaceMd,
          vertical: NasTokens.spaceXs,
        ),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    tr('photo.scan.autoWatch'),
                    style: TextStyle(fontSize: NasTokens.fontCaption),
                  ),
                ),
                Switch(
                  value: policy.autoWatch,
                  onChanged: _busy ? null : (v) => _savePolicy(autoWatch: v),
                ),
              ],
            ),
            Row(
              children: [
                Expanded(
                  child: Text(
                    tr('photo.scan.verify'),
                    style: TextStyle(fontSize: NasTokens.fontCaption),
                  ),
                ),
                NasDropdown<int>(
                  value: hours.contains(policy.verifyHours)
                      ? policy.verifyHours
                      : 6,
                  items: [
                    for (final h in hours)
                      DropdownMenuItem(
                        value: h,
                        child: Text(h == 0 ? tr('photo.scan.off') : '$h'),
                      ),
                  ],
                  onChanged: _busy ? null : (v) => _savePolicy(verifyHours: v),
                ),
              ],
            ),
            Row(
              children: [
                Expanded(
                  child: Text(
                    tr('photo.scan.skipHidden'),
                    style: TextStyle(fontSize: NasTokens.fontCaption),
                  ),
                ),
                Switch(
                  value: policy.skipHidden,
                  onChanged: _busy ? null : (v) => _savePolicy(skipHidden: v),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }


  Future<void> _uploadPhotos() async {
    final lib = _sources.isEmpty ? null : _sources.first;
    if (lib == null) {
      NasSnack.show(context, tr('photo.upload.noSource'), error: true);
      return;
    }
    final files = await openFiles();
    if (files.isEmpty || !mounted) return;

    setState(() => _busy = true);
    var ok = 0;
    var failed = 0;
    for (final file in files) {
      try {
        final bytes = await file.readAsBytes();
        await PhotoUploader.upload(
          libraryId: lib.id,
          fileName: file.name,
          bytes: bytes,
        );
        ok += 1;
      } catch (_) {
        failed += 1;
      }
    }
    if (!mounted) return;
    setState(() => _busy = false);
    NasSnack.show(
      context,
      failed > 0
          ? tr('photo.upload.partial', {'ok': '$ok', 'failed': '$failed'})
          : tr('photo.upload.done', {'ok': '$ok'}),
      error: failed > 0,
    );
    await _load();
    await _loadPolicy();
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
            NasTokens.spaceSm,
            NasTokens.spaceSm,
            0,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  tr('photo.source.owner'),
                  style: TextStyle(
                    fontSize: NasTokens.fontCaption,
                    color: context.nasTextSecondary,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: _busy ? null : _uploadPhotos,
                icon: const Icon(Icons.upload_file_outlined, size: 18),
                label: Text(tr('photo.upload.button')),
              ),
              TextButton.icon(
                onPressed: _busy ? null : () => _scan(),
                icon: const Icon(Icons.sync, size: 18),
                label: Text(tr('common.scanAll')),
              ),
            ],
          ),
        ),
        _policyCard(),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(NasTokens.spaceLg),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 420,
              mainAxisExtent: 132,
              mainAxisSpacing: NasTokens.spaceMd,
              crossAxisSpacing: NasTokens.spaceMd,
            ),
            itemCount: _sources.length + 1,
            itemBuilder: (context, i) {
              if (i == _sources.length) return _AddSourceCard(onTap: _add);
              final item = _sources[i];
              final hasPath = item.path.trim().isNotEmpty;
              return NasCard(
                padding: const EdgeInsets.all(NasTokens.spaceMd),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: (hasPath ? Colors.green : Colors.orange)
                                .withValues(alpha: 0.16),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            hasPath
                                ? tr('photo.source.available')
                                : tr('photo.source.unavailable'),
                            style: TextStyle(
                              fontSize: NasTokens.fontMicro,
                              color: hasPath ? Colors.green : Colors.orange,
                            ),
                          ),
                        ),
                        const SizedBox(width: NasTokens.spaceXs),
                        Expanded(
                          child: Text(
                            hasPath ? item.path : item.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: NasTokens.fontBody,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        NasRefreshButton(
                          size: 18,
                          tooltip: tr('photo.source.refresh'),
                          onPressed: _busy
                              ? null
                              : () => _scan(libraryId: item.id),
                        ),
                        IconButton(
                          tooltip: tr('photo.source.remove'),
                          icon: const Icon(Icons.delete_outline, size: 18),
                          onPressed: () => _remove(item),
                        ),
                      ],
                    ),
                    const SizedBox(height: NasTokens.spaceXs),
                    Text(
                      tr('photo.collection.count').replaceAll(
                        '{n}',
                        '${item.items}',
                      ),
                      style: TextStyle(
                        fontSize: NasTokens.fontCaption,
                        color: context.nasTextSecondary,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _AddSourceCard extends StatelessWidget {
  const _AddSourceCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(NasTokens.radiusMd),
      child: DottedBorderBox(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.add_circle_outline, size: 30, color: scheme.primary),
              const SizedBox(height: NasTokens.spaceXs),
              Text(
                tr('photo.source.add'),
                style: TextStyle(
                  fontSize: NasTokens.fontBody,
                  color: scheme.primary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 虚线边框容器：用 CustomPaint 画，避免各平台 BorderStyle 差异
class DottedBorderBox extends StatelessWidget {
  const DottedBorderBox({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.outlineVariant;
    return CustomPaint(
      painter: _DottedPainter(color),
      child: child,
    );
  }
}

class _DottedPainter extends CustomPainter {
  _DottedPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    const r = Radius.circular(NasTokens.radiusMd);
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(0.5, 0.5, size.width - 1, size.height - 1),
          r,
        ),
      );
    for (final metric in path.computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        final next = d + 6;
        canvas.drawPath(metric.extractPath(d, next), paint);
        d = next + 4;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DottedPainter oldDelegate) =>
      oldDelegate.color != color;
}

/// 文件夹选择：从盘符开始浏览本机目录（可跨盘、可逐级上溯），返回绝对路径。
