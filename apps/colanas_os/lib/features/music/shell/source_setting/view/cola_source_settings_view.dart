import '../../compat/ui_kit.dart';
import '../../compat/cola_custom_colors.dart';
import '../../compat/cola_device_utils.dart';

import 'package:flutter/material.dart';

import '../../compat/getx.dart';
import '../../compat/base_components.dart';
import '../../compat/host.dart';
import '../controller/cola_source_settings_controller.dart';
import '../models/cola_music_source.dart';

/// 桌面网格中卡片高度固定，列数只随内容区宽度变化。
const double _kCardHeight = 320;

/// 单张卡片的宽度基准：可用宽度能塞下几块就排几列。
const double _kBaseCardWidth = 400;

/// 按可用宽度算列数：扣掉左右各 16 的内边距，再按「卡片 + 12 间距」切块。
int _gridColumns(double maxWidth) {
  const double sideInset = 32;
  const double gap = 12;
  final usable = (maxWidth - sideInset).clamp(0.0, 99999.0);
  final slots = ((usable + gap) / (_kBaseCardWidth + gap)).floor();
  return slots.clamp(1, 99);
}

/// 删除来源：二次确认后走乐观删除。
Future<void> _confirmDelete(
  ColaMusicSourceSettingsController store,
  ColaMusicSource source,
) async {
  final accepted = await DialogUtil.showConfirmDialog(
    title: 'need_confirm'.tr,
    content: 'music_source_delete_confirm'.trParams(<String, String>{
      'path': source.path,
    }),
    confirmText: 'delete'.tr,
    cancelText: 'cancel'.tr,
  );
  if (accepted != true) return;
  await store.deleteSourceOptimistic(source);
}

/// 重定位：二次确认后重新挑一个目录，再交给控制器处理。
Future<void> _confirmRelocate(
  BuildContext context,
  ColaMusicSourceSettingsController store,
  ColaMusicSource source,
) async {
  final accepted = await DialogUtil.showConfirmDialog(
    title: 'need_confirm'.tr,
    content: 'photo_source_relocate_confirm'.tr,
    confirmText: 'confirm'.tr,
    cancelText: 'cancel'.tr,
  );
  if (accepted != true) return;
  if (!context.mounted) return;

  final picked = await showFolderPickerBottomSheet(
    context,
    multiSelect: false,
    allowFileSelect: false,
  );
  if (picked == null || picked.isEmpty) return;
  await store.relocateSource(source, picked.first);
}

/// 音乐来源目录设置页：手机窄屏走单列卡片，桌面走自适应网格。
class ColaMusicSourceSettingsView extends StatelessWidget {
  const ColaMusicSourceSettingsView({super.key});

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<CustomColors>();
    final isCompact = DeviceUtils.isMobile;

    return GetBuilder<ColaMusicSourceSettingsController>(
      init: ColaMusicSourceSettingsController(),
      builder: (store) {
        void addAction() => _addFolders(context, store);
        return ColoredBox(
          color: palette?.mainContentBgColor ?? Colors.transparent,
          child: isCompact
              ? _CompactSourceLayout(store: store, onAdd: addAction)
              : _WideSourceLayout(store: store, onAdd: addAction),
        );
      },
    );
  }

  /// 添加来源：多选目录后批量提交，控制器内部已做去重。
  Future<void> _addFolders(
    BuildContext context,
    ColaMusicSourceSettingsController store,
  ) async {
    final picked = await showFolderPickerBottomSheet(
      context,
      multiSelect: true,
      allowFileSelect: false,
    );
    if (picked == null || picked.isEmpty) return;
    await store.addSources(picked);
  }
}

/// 手机端：整页一个纵向列表，来源卡片依次排下来。
class _CompactSourceLayout extends StatelessWidget {
  const _CompactSourceLayout({required this.store, required this.onAdd});

  final ColaMusicSourceSettingsController store;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final entries = store.sources.toList();
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        children: <Widget>[
          _SourceToolbar(
            asWrap: true,
            onScanAll: () => store.scanSource('all'),
            onReload: () => store.fetchSources(showLoading: true),
          ),
          const SizedBox(height: 12.0),
          for (final entry in entries) ...<Widget>[
            _CompactSourceCard(source: entry),
            const SizedBox(height: 12.0),
          ],
          _CompactAddSourceCard(onTap: onAdd),
        ],
      );
    });
  }
}

/// 桌面端：顶部工具栏固定，下面按宽度铺网格，末尾跟一张「添加」卡片。
class _WideSourceLayout extends StatelessWidget {
  const _WideSourceLayout({required this.store, required this.onAdd});

  final ColaMusicSourceSettingsController store;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
          child: _SourceToolbar(
            onScanAll: () => store.scanSource('all'),
            onReload: () => store.fetchSources(showLoading: true),
          ),
        ),
        Expanded(
          child: Obx(() {
            final entries = store.sources.toList();
            return LayoutBuilder(
              builder: (context, limits) {
                return GridView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  itemCount: entries.length + 1,
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: _gridColumns(limits.maxWidth),
                    mainAxisExtent: _kCardHeight,
                    crossAxisSpacing: 12.0,
                    mainAxisSpacing: 12.0,
                  ),
                  itemBuilder: (context, slot) {
                    if (slot == entries.length) {
                      return _WideAddSourceCard(onTap: onAdd);
                    }
                    return _WideSourceCard(source: entries[slot]);
                  },
                );
              },
            );
          }),
        ),
      ],
    );
  }
}

/// 顶部工具栏：标题 + 扫全部 + 刷新。窄屏允许换行，宽屏单行排。
class _SourceToolbar extends StatelessWidget {
  const _SourceToolbar({
    required this.onScanAll,
    required this.onReload,
    this.asWrap = false,
  });

  final VoidCallback onScanAll;
  final VoidCallback onReload;

  /// 窄屏用 Wrap，允许按钮随换行落到第二行。
  final bool asWrap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = Text(
      'settings_source'.tr,
      style: theme.textTheme.titleMedium,
    );
    final scanAll = TextButton(
      onPressed: onScanAll,
      child: Text('music_source_scan_all'.tr),
    );
    final reload = IconButton(
      tooltip: 'refresh'.tr,
      onPressed: onReload,
      icon: const Icon(Icons.refresh),
    );

    if (asWrap) {
      return Wrap(
        spacing: 10,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[title, scanAll, reload],
      );
    }
    return Row(
      children: <Widget>[title, const SizedBox(width: 10.0), scanAll, reload],
    );
  }
}

/// 帮助图标：点了弹说明。窄屏卡片把点击区收到 32×32，桌面沿用默认尺寸。
class _ColaHelpIcon extends StatelessWidget {
  const _ColaHelpIcon({
    required this.message,
    required this.color,
    this.tooltip,
    this.compact = false,
  });

  /// 弹窗正文。
  final String message;

  /// 悬停提示，缺省与正文一致。
  final String? tooltip;

  final Color color;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip ?? message,
      padding: compact ? EdgeInsets.zero : null,
      constraints: compact
          ? const BoxConstraints(minWidth: 32, minHeight: 32)
          : null,
      onPressed: () {
        DialogUtil.showInfoDialog(
          title: 'tip'.tr,
          content: message,
          buttonText: 'ok'.tr,
        );
      },
      icon: Icon(Icons.help_outline, size: 18.0, color: color),
    );
  }
}

/// 来源是否可用的小标签。
class _ColaAvailabilityTag extends StatelessWidget {
  const _ColaAvailabilityTag({required this.online});

  final bool online;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = online
        ? 'music_source_available'
        : 'music_source_unavailable';
    return Text(
      '[${label.tr}]',
      style: theme.textTheme.labelMedium?.copyWith(
        color: online ? Colors.green : Colors.red,
      ),
    );
  }
}

/// 一行「标题 + 帮助 + 开关」。手机卡片带上下 4 的内边距，桌面卡片由外部间距控制。
class _ColaSwitchLine extends StatelessWidget {
  const _ColaSwitchLine({
    required this.label,
    required this.value,
    required this.helpMessage,
    required this.onChanged,
    this.compact = false,
  });

  final String label;
  final bool value;
  final String helpMessage;
  final ValueChanged<bool> onChanged;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final caption = Text(label);
    final line = Row(
      children: <Widget>[
        Expanded(
          child: Row(
            children: <Widget>[
              if (compact) Flexible(child: caption) else caption,
              _ColaHelpIcon(
                message: helpMessage,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                compact: compact,
              ),
            ],
          ),
        ),
        CustomSwitch(value: value, onChanged: onChanged),
      ],
    );
    if (!compact) return line;
    return Padding(padding: const EdgeInsets.fromLTRB(0, 4, 0, 4), child: line);
  }
}

/// 间隔扫描的小时下拉，取值 1~24。
class _ColaIntervalHoursRow extends StatelessWidget {
  const _ColaIntervalHoursRow({
    super.key,
    required this.hours,
    required this.onPick,
  });

  final int hours;
  final ValueChanged<int> onPick;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Text('music_source_scan_interval_hours'.tr),
        const Spacer(),
        DropdownButton<int>(
          value: hours,
          onChanged: (picked) {
            if (picked == null) return;
            onPick(picked);
          },
          items: List<DropdownMenuItem<int>>.generate(
            24,
            (index) => DropdownMenuItem<int>(
              value: index + 1,
              child: Text('${index + 1}'),
            ),
          ),
        ),
      ],
    );
  }
}

/// 展示类型：按文件或按目录，切换会让服务端重建索引，所以先弹确认。
class _ColaShowTypeRow extends StatelessWidget {
  const _ColaShowTypeRow({
    required this.source,
    required this.store,
    this.compact = false,
  });

  final ColaMusicSource source;
  final ColaMusicSourceSettingsController store;
  final bool compact;

  Future<void> _switchTo(String? picked) async {
    if (picked == null || picked == source.showType) return;
    final accepted = await DialogUtil.showConfirmDialog(
      title: 'need_confirm'.tr,
      content: 'music_source_show_type_switch_confirm'.tr,
      confirmText: 'ok'.tr,
      cancelText: 'cancel'.tr,
    );
    if (accepted != true) return;
    await store.updateSourceOptimistic(source, showType: picked);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: <Widget>[
        Expanded(
          child: Row(
            children: <Widget>[
              Flexible(child: Text('music_source_show_type'.tr)),
              _ColaHelpIcon(
                message: 'music_source_show_type_switch_confirm'.tr,
                tooltip: 'music_show_type_alert'.tr,
                color: theme.colorScheme.onSurfaceVariant,
                compact: compact,
              ),
            ],
          ),
        ),
        DropdownButton<String>(
          value: source.showType.isNotEmpty ? source.showType : 'music',
          onChanged: _switchTo,
          items: <DropdownMenuItem<String>>[
            DropdownMenuItem(value: 'music', child: Text('file'.tr)),
            DropdownMenuItem(value: 'series', child: Text('dir'.tr)),
          ],
        ),
      ],
    );
  }
}

/// 手机卡片的状态与操作行。
class _CompactCardActions extends StatelessWidget {
  const _CompactCardActions({required this.source, required this.store});

  final ColaMusicSource source;
  final ColaMusicSourceSettingsController store;

  @override
  Widget build(BuildContext context) {
    final dangerColor = Theme.of(context).colorScheme.error;
    return Row(
      children: <Widget>[
        _ColaAvailabilityTag(online: source.exists),
        const Spacer(),
        Wrap(
          spacing: 6,
          children: <Widget>[
            if (!source.exists)
              TextButton(
                onPressed: () => _confirmRelocate(context, store, source),
                child: Text('photo_source_relocate'.tr),
              )
            else
              TextButton(
                onPressed: () => store.scanSource(source.path),
                child: Text('music_source_scan_now'.tr),
              ),
            TextButton(
              onPressed: () => _confirmDelete(store, source),
              child: Text('delete'.tr, style: TextStyle(color: dangerColor)),
            ),
          ],
        ),
      ],
    );
  }
}

/// 手机端来源卡片。
class _CompactSourceCard extends StatelessWidget {
  const _CompactSourceCard({required this.source});

  final ColaMusicSource source;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final store = Get.find<ColaMusicSourceSettingsController>();
    final intervalOn = store.getIntervalEnabled(source);
    final intervalHours = store.getIntervalHours(source);

    return CustomGlassCard(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              source.path,
              style: theme.textTheme.titleMedium,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 8.0),
            _CompactCardActions(source: source, store: store),
            const SizedBox(height: 6.0),
            _ColaSwitchLine(
              label: 'music_source_scan_when_start'.tr,
              value: source.scanWhenStart == 1,
              helpMessage: 'music_source_help_scan_when_start'.tr,
              compact: true,
              onChanged: (enabled) => store.updateSourceOptimistic(
                source,
                scanWhenStart: enabled ? 1 : 0,
              ),
            ),
            _ColaSwitchLine(
              label: 'music_source_scan_when_change'.tr,
              value: source.scanWhenChange == 1,
              helpMessage: 'music_source_help_scan_when_change'.tr,
              compact: true,
              onChanged: (enabled) => store.updateSourceOptimistic(
                source,
                scanWhenChange: enabled ? 1 : 0,
              ),
            ),
            _ColaSwitchLine(
              label: 'music_source_scan_interval'.tr,
              value: intervalOn,
              helpMessage: 'music_source_help_scan_interval'.tr,
              compact: true,
              onChanged: (enabled) {
                final millis = enabled ? intervalHours * 3600 * 1000 : 0;
                store.updateSourceOptimistic(
                  source,
                  scanInterval: enabled ? 1 : 0,
                  scanIntervalMs: millis,
                );
              },
            ),
            if (intervalOn)
              Padding(
                padding: const EdgeInsets.fromLTRB(0, 2, 0, 0),
                child: _ColaIntervalHoursRow(
                  hours: intervalHours,
                  onPick: (picked) => store.updateSourceOptimistic(
                    source,
                    scanInterval: 1,
                    scanIntervalMs: picked * 3600 * 1000,
                  ),
                ),
              ),
            const SizedBox(height: 6.0),
            _ColaShowTypeRow(source: source, store: store, compact: true),
          ],
        ),
      ),
    );
  }
}

/// 手机端的「添加来源」条。
class _CompactAddSourceCard extends StatelessWidget {
  const _CompactAddSourceCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return CustomGlassCard(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14.0),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(
              Icons.add_circle_outline,
              size: 20.0,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 8.0),
            Text('music_source_add_card'.tr, style: theme.textTheme.titleSmall),
          ],
        ),
      ),
    );
  }
}

/// 桌面端来源卡片。
class _WideSourceCard extends StatelessWidget {
  const _WideSourceCard({required this.source});

  final ColaMusicSource source;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final store = Get.find<ColaMusicSourceSettingsController>();
    final intervalOn = store.getIntervalEnabled(source);
    final intervalHours = store.getIntervalHours(source);

    return CustomGlassCard(
      child: SizedBox.expand(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                if (!source.exists) ...<Widget>[
                  TextButton(
                    onPressed: () => _confirmRelocate(context, store, source),
                    child: Text('photo_source_relocate'.tr),
                  ),
                  const SizedBox(width: 8.0),
                ],
                Expanded(
                  child: Row(
                    children: <Widget>[
                      _ColaAvailabilityTag(online: source.exists),
                      const SizedBox(width: 8.0),
                      Expanded(
                        child: Text(
                          source.path,
                          style: theme.textTheme.titleMedium,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
                if (source.exists)
                  MusicSquareButton(
                    tooltip: 'music_source_scan_now'.tr,
                    icon: Icons.refresh,
                    onTap: () => store.scanSource(source.path),
                  ),
                const SizedBox(width: 6.0),
                MusicSquareButton(
                  tooltip: 'delete'.tr,
                  icon: Icons.delete_outline,
                  onTap: () => _confirmDelete(store, source),
                ),
              ],
            ),
            const SizedBox(height: 12.0),
            _ColaSwitchLine(
              label: 'music_source_scan_when_start'.tr,
              value: source.scanWhenStart == 1,
              helpMessage: 'music_source_help_scan_when_start'.tr,
              onChanged: (enabled) => store.updateSourceOptimistic(
                source,
                scanWhenStart: enabled ? 1 : 0,
              ),
            ),
            const SizedBox(height: 6.0),
            _ColaSwitchLine(
              label: 'music_source_scan_when_change'.tr,
              value: source.scanWhenChange == 1,
              helpMessage: 'music_source_help_scan_when_change'.tr,
              onChanged: (enabled) => store.updateSourceOptimistic(
                source,
                scanWhenChange: enabled ? 1 : 0,
              ),
            ),
            const SizedBox(height: 6.0),
            _ColaSwitchLine(
              label: 'music_source_scan_interval'.tr,
              value: intervalOn,
              helpMessage: 'music_source_help_scan_interval'.tr,
              onChanged: (enabled) {
                final millis = enabled ? intervalHours * 3600 * 1000 : 0;
                store.updateSourceOptimistic(
                  source,
                  scanInterval: enabled ? 1 : 0,
                  scanIntervalMs: millis,
                );
              },
            ),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: intervalOn
                  ? _ColaIntervalHoursRow(
                      key: const ValueKey('interval'),
                      hours: intervalHours,
                      onPick: (picked) => store.updateSourceOptimistic(
                        source,
                        scanInterval: 1,
                        scanIntervalMs: picked * 3600 * 1000,
                      ),
                    )
                  : const SizedBox.shrink(key: ValueKey('empty')),
            ),
            const SizedBox(height: 6.0),
            _ColaShowTypeRow(source: source, store: store),
          ],
        ),
      ),
    );
  }
}

/// 桌面端的「添加来源」卡片。
class _WideAddSourceCard extends StatelessWidget {
  const _WideAddSourceCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final glyph = Icon(
      Icons.add_circle_outline,
      size: 38.0,
      color: theme.colorScheme.primary,
    );
    final prompt = Text(
      'music_source_add_card'.tr,
      style: theme.textTheme.titleSmall,
      textAlign: TextAlign.center,
    );

    return CustomGlassCard(
      onTap: onTap,
      child: SizedBox.expand(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            glyph,
            const SizedBox(height: 10.0),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                prompt,
                _ColaHelpIcon(
                  message: 'music_source_help_add_source'.tr,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
