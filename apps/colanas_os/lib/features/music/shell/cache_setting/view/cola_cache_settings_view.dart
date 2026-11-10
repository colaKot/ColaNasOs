import '../../compat/cola_custom_colors.dart';
import '../../compat/base_components.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../compat/getx.dart';

import '../../compat/cola_device_utils.dart';
import '../../compat/host.dart';
import '../controller/cola_cache_settings_controller.dart';

class MusicCacheSettingsView extends StatefulWidget {
  const MusicCacheSettingsView({super.key});

  @override
  State<MusicCacheSettingsView> createState() => _MusicCacheSettingsViewState();
}

class _MusicCacheSettingsViewState extends State<MusicCacheSettingsView> {
  final TextEditingController _maxItemsCtrl = TextEditingController();

  @override
  void dispose() {
    _maxItemsCtrl.dispose();
    super.dispose();
  }

  int? _parseMaxItems() {
    final localRaw = _maxItemsCtrl.text.trim();
    if (localRaw.isEmpty) return null;
    return int.tryParse(localRaw);
  }

  @override
  Widget build(BuildContext context) {
    final localTheme = Theme.of(context);

    final localExtendedPalette = Theme.of(context).extension<CustomColors>();

    return GetBuilder<MusicCacheSettingsController>(
      init: MusicCacheSettingsController(),
      builder: (ctrl) {
        return Container(
          color: localExtendedPalette?.mainContentBgColor,
          child: Column(
            children: <Widget>[
              Padding(
                padding: EdgeInsets.fromLTRB(
                  16,
                  DeviceUtils.isMobile ? 0 : 12,
                  16,
                  DeviceUtils.isMobile ? 0 : 10,
                ),
                child: Row(
                  children: <Widget>[
                    Text(
                      'music_cache_settings_title'.tr,
                      style: localTheme.textTheme.titleMedium,
                    ),
                    const SizedBox(width: 10.0),
                    IconButton(
                      tooltip: 'refresh'.tr,
                      onPressed: () => ctrl.refreshStats(showLoading: true),
                      icon: const Icon(Icons.refresh),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Obx(() {
                  final localMaxItems = ctrl.maxItems.value;
                  final localEnabled = ctrl.enabled.value;
                  if (_maxItemsCtrl.text.trim() != localMaxItems.toString()) {
                    _maxItemsCtrl.text = localMaxItems.toString();
                  }

                  final localCachedBytes = ctrl.cachedBytes.value;
                  final localCachedCount = ctrl.cachedCount.value;
                  final localClearing = ctrl.clearing.value;
                  final localLoading = ctrl.loading.value;

                  return Stack(
                    children: <Widget>[
                      ListView(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                        children: <Widget>[
                          CustomGlassCard(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Row(
                                  children: <Widget>[
                                    const Icon(Icons.tune_rounded, size: 18.0),
                                    const SizedBox(width: 8.0),
                                    Text(
                                      'music_cache_settings_section_options'.tr,
                                      style: localTheme.textTheme.titleSmall,
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 12.0),
                                SwitchListTile(
                                  value: localEnabled,
                                  title: Text(
                                    'music_cache_settings_enabled'.tr,
                                    style: localTheme.textTheme.titleSmall,
                                  ),
                                  subtitle: Text(
                                    'music_cache_settings_enabled_tip'.tr,
                                  ),
                                  onChanged: (v) => ctrl.toggleEnabled(v),
                                  contentPadding: EdgeInsets.fromLTRB(
                                    0,
                                    0,
                                    0,
                                    0,
                                  ),
                                  activeThumbColor:
                                      localTheme.colorScheme.onPrimary,
                                ),
                                const SizedBox(height: 8.0),
                                Row(
                                  children: <Widget>[
                                    Expanded(
                                      child: TextField(
                                        onSubmitted: (_) async {
                                          final v = _parseMaxItems();
                                          if (v == null || v < 0) {
                                            ToastUtil.show(
                                              'music_cache_settings_invalid_max_items'
                                                  .tr,
                                            );
                                            return;
                                          }
                                          await ctrl.setMaxItems(v);
                                        },
                                        keyboardType:
                                            const TextInputType.numberWithOptions(
                                              signed: false,
                                              decimal: false,
                                            ),
                                        inputFormatters: [
                                          FilteringTextInputFormatter
                                              .digitsOnly,
                                        ],
                                        enabled: localEnabled,
                                        decoration: InputDecoration(
                                          labelText:
                                              'music_cache_settings_max_items'
                                                  .tr,
                                          border: const OutlineInputBorder(),
                                        ),
                                        controller: _maxItemsCtrl,
                                      ),
                                    ),
                                    const SizedBox(width: 10.0),
                                    SizedBox(
                                      height: 45.0,
                                      child: CustomButton(
                                        onPressed: localEnabled
                                            ? () async {
                                                final v = _parseMaxItems();
                                                if (v == null || v < 0) {
                                                  ToastUtil.show(
                                                    'music_cache_settings_invalid_max_items'
                                                        .tr,
                                                  );
                                                  return;
                                                }
                                                await ctrl.setMaxItems(v);
                                              }
                                            : null,
                                        text: 'music_cache_settings_apply'.tr,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12.0),
                          CustomGlassCard(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Row(
                                  children: <Widget>[
                                    const Icon(
                                      Icons.storage_rounded,
                                      size: 18.0,
                                    ),
                                    const SizedBox(width: 8.0),
                                    Text(
                                      'music_cache_settings_section_stats'.tr,
                                      style: localTheme.textTheme.titleSmall,
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 12.0),
                                Row(
                                  children: <Widget>[
                                    Expanded(
                                      child: _StatTile(
                                        label:
                                            'music_cache_settings_cached_count'
                                                .tr,
                                        value: localCachedCount.toString(),
                                      ),
                                    ),
                                    const SizedBox(width: 12.0),
                                    Expanded(
                                      child: _StatTile(
                                        label:
                                            'music_cache_settings_cached_size'
                                                .tr,
                                        value: FileUtil.formatSize(
                                          localCachedBytes,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 12.0),
                                SizedBox(
                                  width: double.infinity,
                                  child: FilledButton.tonal(
                                    onPressed: localClearing
                                        ? null
                                        : () async {
                                            await ctrl.clearCache();
                                            ToastUtil.show(
                                              'operation_success'.tr,
                                            );
                                          },
                                    child: Text(
                                      localClearing
                                          ? 'music_cache_settings_clearing'.tr
                                          : 'music_cache_settings_clear'.tr,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      if (localLoading)
                        const Positioned.fill(
                          child: IgnorePointer(
                            child: Center(child: CircularProgressIndicator()),
                          ),
                        ),
                    ],
                  );
                }),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _StatTile extends StatelessWidget {
  final String label;
  final String value;

  const _StatTile({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final localTheme = Theme.of(context);
    final localValueStyle = localTheme.textTheme.titleLarge?.copyWith(
      fontWeight: FontWeight.w700,
    );
    final localLabelStyle = localTheme.textTheme.bodySmall?.copyWith(
      color: localTheme.colorScheme.onSurface.withValues(alpha: 0.6),
    );
    return CustomGlassCard(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(label, style: localLabelStyle),
          const SizedBox(height: 6.0),
          Text(value, style: localValueStyle),
        ],
      ),
    );
  }
}
