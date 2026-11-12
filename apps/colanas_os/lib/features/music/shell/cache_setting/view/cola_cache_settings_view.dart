import '../../compat/cola_custom_colors.dart';
import '../../compat/base_components.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../compat/getx.dart';

import '../../compat/cola_device_utils.dart';
import '../../compat/host.dart';
import '../controller/cola_cache_settings_controller.dart';

class ColaMusicCacheSettingsView extends StatefulWidget {
  const ColaMusicCacheSettingsView({super.key});

  @override
  State<ColaMusicCacheSettingsView> createState() =>
      _ColaMusicCacheSettingsViewState();
}

class _ColaMusicCacheSettingsViewState
    extends State<ColaMusicCacheSettingsView> {
  final TextEditingController _maxItemsCtrl = TextEditingController();

  @override
  void dispose() {
    _maxItemsCtrl.dispose();
    super.dispose();
  }

  int? _readMaxItemsInput() {
    final text = _maxItemsCtrl.text.trim();
    return text.isEmpty ? null : int.tryParse(text);
  }

  Future<void> _applyMaxItems(MusicCacheSettingsController ctrl) async {
    final value = _readMaxItemsInput();
    if (value == null || value < 0) {
      ToastUtil.show('music_cache_settings_invalid_max_items'.tr);
      return;
    }
    await ctrl.setMaxItems(value);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<CustomColors>();

    return GetBuilder<MusicCacheSettingsController>(
      init: MusicCacheSettingsController(),
      builder: (ctrl) {
        return Container(
          color: palette?.mainContentBgColor,
          child: Column(
            children: <Widget>[
              _buildHeader(theme, ctrl),
              Expanded(child: _buildBody(theme, ctrl)),
            ],
          ),
        );
      },
    );
  }

  Widget _buildHeader(ThemeData theme, MusicCacheSettingsController ctrl) {
    final compact = DeviceUtils.isMobile;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, compact ? 0 : 12, 16, compact ? 0 : 10),
      child: Row(
        children: <Widget>[
          Text(
            'music_cache_settings_title'.tr,
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(width: 10.0),
          IconButton(
            tooltip: 'refresh'.tr,
            onPressed: () => ctrl.refreshStats(showLoading: true),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(ThemeData theme, MusicCacheSettingsController ctrl) {
    return Obx(() {
      final maxItems = ctrl.maxItems.value;
      final enabled = ctrl.enabled.value;
      if (_maxItemsCtrl.text.trim() != maxItems.toString()) {
        _maxItemsCtrl.text = maxItems.toString();
      }

      final cachedBytes = ctrl.cachedBytes.value;
      final cachedCount = ctrl.cachedCount.value;
      final clearing = ctrl.clearing.value;
      final loading = ctrl.loading.value;

      return Stack(
        children: <Widget>[
          ListView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            children: <Widget>[
              _buildOptionsCard(theme, ctrl, enabled: enabled),
              const SizedBox(height: 12.0),
              _buildStatsCard(
                theme,
                ctrl,
                cachedCount: cachedCount,
                cachedBytes: cachedBytes,
                clearing: clearing,
              ),
            ],
          ),
          if (loading)
            const Positioned.fill(
              child: IgnorePointer(
                child: Center(child: CircularProgressIndicator()),
              ),
            ),
        ],
      );
    });
  }

  Widget _buildOptionsCard(
    ThemeData theme,
    MusicCacheSettingsController ctrl, {
    required bool enabled,
  }) {
    return CustomGlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _SectionTitle(
            icon: Icons.tune_rounded,
            text: 'music_cache_settings_section_options'.tr,
            style: theme.textTheme.titleSmall,
          ),
          const SizedBox(height: 12.0),
          SwitchListTile(
            value: enabled,
            title: Text(
              'music_cache_settings_enabled'.tr,
              style: theme.textTheme.titleSmall,
            ),
            subtitle: Text('music_cache_settings_enabled_tip'.tr),
            onChanged: (v) => ctrl.toggleEnabled(v),
            contentPadding: EdgeInsets.fromLTRB(0, 0, 0, 0),
            activeThumbColor: theme.colorScheme.onPrimary,
          ),
          const SizedBox(height: 8.0),
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  onSubmitted: (_) => _applyMaxItems(ctrl),
                  keyboardType: const TextInputType.numberWithOptions(
                    signed: false,
                    decimal: false,
                  ),
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  enabled: enabled,
                  decoration: InputDecoration(
                    labelText: 'music_cache_settings_max_items'.tr,
                    border: const OutlineInputBorder(),
                  ),
                  controller: _maxItemsCtrl,
                ),
              ),
              const SizedBox(width: 10.0),
              SizedBox(
                height: 45.0,
                child: CustomButton(
                  onPressed: enabled ? () => _applyMaxItems(ctrl) : null,
                  text: 'music_cache_settings_apply'.tr,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatsCard(
    ThemeData theme,
    MusicCacheSettingsController ctrl, {
    required int cachedCount,
    required int cachedBytes,
    required bool clearing,
  }) {
    return CustomGlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _SectionTitle(
            icon: Icons.storage_rounded,
            text: 'music_cache_settings_section_stats'.tr,
            style: theme.textTheme.titleSmall,
          ),
          const SizedBox(height: 12.0),
          Row(
            children: <Widget>[
              Expanded(
                child: _StatTile(
                  label: 'music_cache_settings_cached_count'.tr,
                  value: cachedCount.toString(),
                ),
              ),
              const SizedBox(width: 12.0),
              Expanded(
                child: _StatTile(
                  label: 'music_cache_settings_cached_size'.tr,
                  value: FileUtil.formatSize(cachedBytes),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12.0),
          SizedBox(
            width: double.infinity,
            child: FilledButton.tonal(
              onPressed: clearing
                  ? null
                  : () async {
                      await ctrl.clearCache();
                      ToastUtil.show('operation_success'.tr);
                    },
              child: Text(
                clearing
                    ? 'music_cache_settings_clearing'.tr
                    : 'music_cache_settings_clear'.tr,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 小节标题：图标 + 文案，两个卡片共用。
class _SectionTitle extends StatelessWidget {
  const _SectionTitle({
    required this.icon,
    required this.text,
    this.style,
  });

  final IconData icon;
  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Icon(icon, size: 18.0),
        const SizedBox(width: 8.0),
        Text(text, style: style),
      ],
    );
  }
}

class _StatTile extends StatelessWidget {
  final String label;
  final String value;

  const _StatTile({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return CustomGlassCard(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(height: 6.0),
          Text(
            value,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
