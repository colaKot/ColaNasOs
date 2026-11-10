import '../../compat/ui_kit.dart';
import '../../compat/cola_custom_colors.dart';
import '../../compat/cola_device_utils.dart';

import 'package:flutter/material.dart';

import '../../compat/getx.dart';
import '../../compat/base_components.dart';
import '../../compat/host.dart';
import '../controller/cola_source_settings_controller.dart';
import '../models/cola_music_source.dart';

const double _kCardHeight = 320;
const double _kBaseCardWidth = 400;

class MusicSourceSettingsView extends StatelessWidget {
  const MusicSourceSettingsView({super.key});

  @override
  Widget build(BuildContext context) {
    final extendedPalette = Theme.of(context).extension<CustomColors>();
    final theme = Theme.of(context);
    final isNarrow = DeviceUtils.isMobile;
    return GetBuilder<MusicSourceSettingsController>(
      init: MusicSourceSettingsController(),
      builder: (listState) {
        return Container(
          color: extendedPalette?.mainContentBgColor,
          child: isNarrow
              ? Obx(() {
                  final items = listState.sources.toList();
                  return ListView(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                    children: <Widget>[
                      Wrap(
                        spacing: 10,
                        runSpacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: <Widget>[
                          Text(
                            'settings_source'.tr,
                            style: theme.textTheme.titleMedium,
                          ),
                          TextButton(
                            onPressed: () => listState.scanSource('all'),
                            child: Text('music_source_scan_all'.tr),
                          ),
                          IconButton(
                            tooltip: 'refresh'.tr,
                            onPressed: () =>
                                listState.fetchSources(showLoading: true),
                            icon: const Icon(Icons.refresh),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12.0),
                      for (final s in items) ...[
                        _MobileSourceCard(source: s),
                        const SizedBox(height: 12.0),
                      ],
                      _MobileAddSourceCard(
                        onTap: () => _pickAndAdd(context, listState),
                      ),
                    ],
                  );
                })
              : Column(
                  children: <Widget>[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
                      child: Row(
                        children: <Widget>[
                          Text(
                            'settings_source'.tr,
                            style: theme.textTheme.titleMedium,
                          ),
                          const SizedBox(width: 10.0),
                          TextButton(
                            onPressed: () => listState.scanSource('all'),
                            child: Text('music_source_scan_all'.tr),
                          ),
                          IconButton(
                            tooltip: 'refresh'.tr,
                            onPressed: () =>
                                listState.fetchSources(showLoading: true),
                            icon: const Icon(Icons.refresh),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: Obx(() {
                        final items = listState.sources.toList();
                        return LayoutBuilder(
                          builder: (context, constraints) {
                            const spacing = 12.0;
                            const paddingX = 16.0;
                            final availableWidth =
                                (constraints.maxWidth - paddingX * 2).clamp(
                                  0,
                                  99999,
                                );
                            final count =
                                (((availableWidth + spacing) /
                                            (_kBaseCardWidth + spacing))
                                        .floor())
                                    .clamp(1, 99);

                            return GridView.builder(
                              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                              itemCount: items.length + 1,
                              itemBuilder: (context, index) {
                                if (index < items.length) {
                                  return _SourceCard(source: items[index]);
                                }
                                return _AddSourceCard(
                                  onTap: () => _pickAndAdd(context, listState),
                                );
                              },
                              gridDelegate:
                                  SliverGridDelegateWithFixedCrossAxisCount(
                                    mainAxisSpacing: spacing,
                                    mainAxisExtent: _kCardHeight,
                                    crossAxisSpacing: spacing,
                                    crossAxisCount: count,
                                  ),
                            );
                          },
                        );
                      }),
                    ),
                  ],
                ),
        );
      },
    );
  }

  Future<void> _pickAndAdd(
    BuildContext context,
    MusicSourceSettingsController listState,
  ) async {
    final selected = await showFolderPickerBottomSheet(
      context,
      multiSelect: true,
      allowFileSelect: false,
    );
    if (selected == null || selected.isEmpty) return;
    await listState.addSources(selected);
  }
}

class _MobileAddSourceCard extends StatelessWidget {
  final VoidCallback onTap;

  const _MobileAddSourceCard({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return CustomGlassCard(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(0, 14, 0, 14),
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

class _MobileSourceCard extends StatelessWidget {
  final MusicSource source;

  const _MobileSourceCard({required this.source});

  @override
  Widget build(BuildContext context) {
    final listState = Get.find<MusicSourceSettingsController>();
    final theme = Theme.of(context);

    final hours = listState.getIntervalHours(source).clamp(1, 24);
    final intervalEnabled = listState.getIntervalEnabled(source);

    Future<void> delete() async {
      final confirmed = await DialogUtil.showConfirmDialog(
        title: 'need_confirm'.tr,
        content: 'music_source_delete_confirm'.trParams({'path': source.path}),
        confirmText: 'delete'.tr,
        cancelText: 'cancel'.tr,
      );
      if (confirmed == true) {
        await listState.deleteSourceOptimistic(source);
      }
    }

    Future<void> scanNow() async {
      await listState.scanSource(source.path);
    }

    Future<void> relocate() async {
      final confirmed = await DialogUtil.showConfirmDialog(
        title: 'need_confirm'.tr,
        content: 'photo_source_relocate_confirm'.tr,
        confirmText: 'confirm'.tr,
        cancelText: 'cancel'.tr,
      );
      if (confirmed != true) return;
      if (!context.mounted) return;

      final selected = await showFolderPickerBottomSheet(
        context,
        multiSelect: false,
        allowFileSelect: false,
      );
      if (selected == null || selected.isEmpty) return;
      await listState.relocateSource(source, selected.first);
    }

    Widget switchRow({
      required String title,
      required bool value,
      required String helpMessage,
      required ValueChanged<bool> onChanged,
    }) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(0, 4, 0, 4),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Row(
                children: <Widget>[
                  Flexible(child: Text(title)),
                  IconButton(
                    tooltip: helpMessage,
                    padding: EdgeInsets.fromLTRB(0, 0, 0, 0),
                    onPressed: () {
                      DialogUtil.showInfoDialog(
                        title: 'tip'.tr,
                        content: helpMessage,
                        buttonText: 'ok'.tr,
                      );
                    },
                    icon: Icon(
                      Icons.help_outline,
                      size: 18.0,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    constraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 32,
                    ),
                  ),
                ],
              ),
            ),
            CustomSwitch(value: value, onChanged: onChanged),
          ],
        ),
      );
    }

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
            Row(
              children: <Widget>[
                Text(
                  '[${(source.exists ? 'music_source_available' : 'music_source_unavailable').tr}]',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: source.exists ? Colors.green : Colors.red,
                  ),
                ),
                const Spacer(),
                Wrap(
                  spacing: 6,
                  children: <Widget>[
                    if (!source.exists)
                      TextButton(
                        onPressed: relocate,
                        child: Text('photo_source_relocate'.tr),
                      ),
                    if (source.exists)
                      TextButton(
                        onPressed: scanNow,
                        child: Text('music_source_scan_now'.tr),
                      ),
                    TextButton(
                      onPressed: delete,
                      child: Text(
                        'delete'.tr,
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 6.0),
            switchRow(
              value: source.scanWhenStart == 1,
              title: 'music_source_scan_when_start'.tr,
              onChanged: (v) => listState.updateSourceOptimistic(
                source,
                scanWhenStart: v ? 1 : 0,
              ),
              helpMessage: 'music_source_help_scan_when_start'.tr,
            ),
            switchRow(
              value: source.scanWhenChange == 1,
              title: 'music_source_scan_when_change'.tr,
              onChanged: (v) => listState.updateSourceOptimistic(
                source,
                scanWhenChange: v ? 1 : 0,
              ),
              helpMessage: 'music_source_help_scan_when_change'.tr,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(0, 4, 0, 4),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Row(
                      children: <Widget>[
                        Flexible(child: Text('music_source_scan_interval'.tr)),
                        IconButton(
                          tooltip: 'music_source_help_scan_interval'.tr,
                          padding: EdgeInsets.fromLTRB(0, 0, 0, 0),
                          onPressed: () {
                            DialogUtil.showInfoDialog(
                              title: 'tip'.tr,
                              content: 'music_source_help_scan_interval'.tr,
                              buttonText: 'ok'.tr,
                            );
                          },
                          icon: Icon(
                            Icons.help_outline,
                            size: 18.0,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          constraints: const BoxConstraints(
                            minWidth: 32,
                            minHeight: 32,
                          ),
                        ),
                      ],
                    ),
                  ),
                  CustomSwitch(
                    value: intervalEnabled,
                    onChanged: (v) {
                      if (v) {
                        final ms = hours * 3600 * 1000;
                        listState.updateSourceOptimistic(
                          source,
                          scanInterval: 1,
                          scanIntervalMs: ms,
                        );
                      } else {
                        listState.updateSourceOptimistic(
                          source,
                          scanInterval: 0,
                          scanIntervalMs: 0,
                        );
                      }
                    },
                  ),
                ],
              ),
            ),
            if (intervalEnabled)
              Padding(
                padding: const EdgeInsets.fromLTRB(0, 2, 0, 0),
                child: Row(
                  children: <Widget>[
                    Text('music_source_scan_interval_hours'.tr),
                    const Spacer(),
                    DropdownButton<int>(
                      value: hours,
                      onChanged: (v) {
                        if (v == null) return;
                        listState.updateSourceOptimistic(
                          source,
                          scanInterval: 1,
                          scanIntervalMs: v * 3600 * 1000,
                        );
                      },
                      items: List.generate(
                        24,
                        (i) => DropdownMenuItem(
                          value: i + 1,
                          child: Text('${i + 1}'),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 6.0),
            Row(
              children: <Widget>[
                Expanded(
                  child: Row(
                    children: <Widget>[
                      Flexible(child: Text('music_source_show_type'.tr)),
                      IconButton(
                        tooltip: 'music_show_type_alert'.tr,
                        padding: EdgeInsets.fromLTRB(0, 0, 0, 0),
                        onPressed: () {
                          DialogUtil.showInfoDialog(
                            title: 'tip'.tr,
                            content: 'music_source_show_type_switch_confirm'.tr,
                            buttonText: 'ok'.tr,
                          );
                        },
                        icon: Icon(
                          Icons.help_outline,
                          size: 18.0,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        constraints: const BoxConstraints(
                          minWidth: 32,
                          minHeight: 32,
                        ),
                      ),
                    ],
                  ),
                ),
                DropdownButton<String>(
                  value: (source.showType.isNotEmpty
                      ? source.showType
                      : 'music'),
                  onChanged: (v) async {
                    if (v == null || v == source.showType) return;
                    final confirmed = await DialogUtil.showConfirmDialog(
                      title: 'need_confirm'.tr,
                      content: 'music_source_show_type_switch_confirm'.tr,
                      confirmText: 'ok'.tr,
                      cancelText: 'cancel'.tr,
                    );
                    if (confirmed == true) {
                      await listState.updateSourceOptimistic(
                        source,
                        showType: v,
                      );
                    }
                  },
                  items: [
                    DropdownMenuItem(value: 'music', child: Text('file'.tr)),
                    DropdownMenuItem(value: 'series', child: Text('dir'.tr)),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _AddSourceCard extends StatelessWidget {
  final VoidCallback onTap;

  const _AddSourceCard({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return CustomGlassCard(
      onTap: onTap,
      child: SizedBox.expand(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                Icons.add_circle_outline,
                size: 38.0,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(height: 10.0),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    'music_source_add_card'.tr,
                    style: theme.textTheme.titleSmall,
                    textAlign: TextAlign.center,
                  ),
                  IconButton(
                    tooltip: 'music_source_help_add_source'.tr,
                    onPressed: () {
                      DialogUtil.showInfoDialog(
                        title: 'tip'.tr,
                        content: 'music_source_help_add_source'.tr,
                        buttonText: 'ok'.tr,
                      );
                    },
                    icon: Icon(
                      Icons.help_outline,
                      size: 18.0,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SourceCard extends StatelessWidget {
  final MusicSource source;

  const _SourceCard({required this.source});

  @override
  Widget build(BuildContext context) {
    final listState = Get.find<MusicSourceSettingsController>();
    final theme = Theme.of(context);

    final hours = listState.getIntervalHours(source);
    final intervalEnabled = listState.getIntervalEnabled(source);

    final relocateButton = TextButton(
      onPressed: () async {
        final confirmed = await DialogUtil.showConfirmDialog(
          title: 'need_confirm'.tr,
          content: 'photo_source_relocate_confirm'.tr,
          confirmText: 'confirm'.tr,
          cancelText: 'cancel'.tr,
        );
        if (confirmed != true) return;
        if (!context.mounted) return;

        final selected = await showFolderPickerBottomSheet(
          context,
          multiSelect: false,
          allowFileSelect: false,
        );
        if (selected == null || selected.isEmpty) return;
        await listState.relocateSource(source, selected.first);
      },
      child: Text('photo_source_relocate'.tr),
    );

    return CustomGlassCard(
      child: SizedBox.expand(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                if (!source.exists) relocateButton,
                if (!source.exists) const SizedBox(width: 8.0),
                Expanded(
                  child: Row(
                    children: <Widget>[
                      Text(
                        '[${(source.exists ? 'music_source_available' : 'music_source_unavailable').tr}]',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: source.exists ? Colors.green : Colors.red,
                        ),
                      ),
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
                    onTap: () => listState.scanSource(source.path),
                    icon: Icons.refresh,
                  ),
                const SizedBox(width: 6.0),
                MusicSquareButton(
                  tooltip: 'delete'.tr,
                  onTap: () async {
                    final confirmed = await DialogUtil.showConfirmDialog(
                      title: 'need_confirm'.tr,
                      content: 'music_source_delete_confirm'.trParams({
                        'path': source.path,
                      }),
                      confirmText: 'delete'.tr,
                      cancelText: 'cancel'.tr,
                    );
                    if (confirmed == true) {
                      await listState.deleteSourceOptimistic(source);
                    }
                  },
                  icon: Icons.delete_outline,
                ),
              ],
            ),
            const SizedBox(height: 12.0),
            _switchRow(
              value: source.scanWhenStart == 1,
              title: 'music_source_scan_when_start'.tr,
              onChanged: (v) => listState.updateSourceOptimistic(
                source,
                scanWhenStart: v ? 1 : 0,
              ),
              helpMessage: 'music_source_help_scan_when_start'.tr,
              helpIconColor: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 6.0),
            _switchRow(
              value: source.scanWhenChange == 1,
              title: 'music_source_scan_when_change'.tr,
              onChanged: (v) => listState.updateSourceOptimistic(
                source,
                scanWhenChange: v ? 1 : 0,
              ),
              helpMessage: 'music_source_help_scan_when_change'.tr,
              helpIconColor: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 6.0),
            Row(
              children: <Widget>[
                Expanded(
                  child: Row(
                    children: <Widget>[
                      Text('music_source_scan_interval'.tr),
                      IconButton(
                        tooltip: 'music_source_help_scan_interval'.tr,
                        onPressed: () {
                          DialogUtil.showInfoDialog(
                            title: 'tip'.tr,
                            content: 'music_source_help_scan_interval'.tr,
                            buttonText: 'ok'.tr,
                          );
                        },
                        icon: Icon(
                          Icons.help_outline,
                          size: 18.0,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                CustomSwitch(
                  value: intervalEnabled,
                  onChanged: (v) {
                    if (v) {
                      final ms = hours.clamp(1, 24) * 3600 * 1000;
                      listState.updateSourceOptimistic(
                        source,
                        scanInterval: 1,
                        scanIntervalMs: ms,
                      );
                    } else {
                      listState.updateSourceOptimistic(
                        source,
                        scanInterval: 0,
                        scanIntervalMs: 0,
                      );
                    }
                  },
                ),
              ],
            ),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: intervalEnabled
                  ? Row(
                      key: const ValueKey('interval'),
                      children: <Widget>[
                        Text('music_source_scan_interval_hours'.tr),
                        const Spacer(),
                        DropdownButton<int>(
                          value: hours.clamp(1, 24),
                          onChanged: (v) {
                            if (v == null) return;
                            listState.updateSourceOptimistic(
                              source,
                              scanInterval: 1,
                              scanIntervalMs: v * 3600 * 1000,
                            );
                          },
                          items: List.generate(
                            24,
                            (i) => DropdownMenuItem(
                              value: i + 1,
                              child: Text('${i + 1}'),
                            ),
                          ),
                        ),
                      ],
                    )
                  : const SizedBox.shrink(key: ValueKey('empty')),
            ),
            const SizedBox(height: 6.0),
            Row(
              children: <Widget>[
                Expanded(
                  child: Row(
                    children: <Widget>[
                      Flexible(child: Text('music_source_show_type'.tr)),
                      IconButton(
                        tooltip: 'music_show_type_alert'.tr,
                        onPressed: () {
                          DialogUtil.showInfoDialog(
                            title: 'tip'.tr,
                            content: 'music_source_show_type_switch_confirm'.tr,
                            buttonText: 'ok'.tr,
                          );
                        },
                        icon: Icon(
                          Icons.help_outline,
                          size: 18.0,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                DropdownButton<String>(
                  value: (source.showType.isNotEmpty
                      ? source.showType
                      : 'music'),
                  onChanged: (v) async {
                    if (v == null || v == source.showType) return;
                    final confirmed = await DialogUtil.showConfirmDialog(
                      title: 'need_confirm'.tr,
                      content: 'music_source_show_type_switch_confirm'.tr,
                      confirmText: 'ok'.tr,
                      cancelText: 'cancel'.tr,
                    );
                    if (confirmed == true) {
                      await listState.updateSourceOptimistic(
                        source,
                        showType: v,
                      );
                    }
                  },
                  items: [
                    DropdownMenuItem(value: 'music', child: Text('file'.tr)),
                    DropdownMenuItem(value: 'series', child: Text('dir'.tr)),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _switchRow({
    required String title,
    required bool value,
    required String helpMessage,
    required Color helpIconColor,
    required ValueChanged<bool> onChanged,
  }) {
    return Row(
      children: <Widget>[
        Expanded(
          child: Row(
            children: <Widget>[
              Text(title),
              IconButton(
                tooltip: helpMessage,
                onPressed: () {
                  DialogUtil.showInfoDialog(
                    title: 'tip'.tr,
                    content: helpMessage,
                    buttonText: 'ok'.tr,
                  );
                },
                icon: Icon(
                  Icons.help_outline,
                  size: 18.0,
                  color: helpIconColor,
                ),
              ),
            ],
          ),
        ),
        CustomSwitch(value: value, onChanged: onChanged),
      ],
    );
  }
}
