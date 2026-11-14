import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nas_ui/nas_ui.dart' show NasStyleContext;
import 'package:url_launcher/url_launcher.dart';

import '../../compat/cola_api_controller.dart';
import '../../compat/getx.dart';
import '../../compat/host.dart';
import '../../detail/models/music_detail_models.dart';
import '../controller/music_lastfm_settings_controller.dart';

/// 「在线数据源（Last.fm）」设置页。
///
/// 取代原来的 `_MusicPlaybackSettingsPlaceholder` —— 音乐壳本来没有这一页，
/// 但 Last.fm 的凭证与账号绑定需要一个正式入口。
///
/// 分三段：凭证（API Key / Secret）→ 账号绑定（Scrobble 的 session key）→ 缓存。
class MusicLastfmSettingsView extends StatefulWidget {
  const MusicLastfmSettingsView({super.key});

  @override
  State<MusicLastfmSettingsView> createState() =>
      _MusicLastfmSettingsViewState();
}

class _MusicLastfmSettingsViewState extends State<MusicLastfmSettingsView> {
  late final MusicLastfmSettingsController _ctrl;
  final TextEditingController _keyEditing = TextEditingController();
  final TextEditingController _secretEditing = TextEditingController();

  @override
  void initState() {
    super.initState();
    _ctrl = Get.put(MusicLastfmSettingsController());
  }

  /// 回调地址：按**浏览器当前访问地址**拼，不用用户手抄。
  ///
  /// 为什么不能直接用 `ApiController.baseUrl`：它可能是客户端写死的
  /// `http://127.0.0.1:7888`。当用户从外网（例如 lucky 反代到
  /// `https://home.gexuan.net:23788`）打开页面时，Last.fm 会把这个回调
  /// 交给浏览器跳转 —— 跳 `127.0.0.1` 等于跳用户自己那台机器，
  /// 服务端永远收不到，于是「授权成功但一直显示未绑定」（2026-11-10 反馈）。
  ///
  /// 规则：baseUrl 是回环地址、而页面本身不是回环地址 → 用页面同源。
  String get _callbackUrl {
    final origin = Uri.base.origin;
    final raw = ApiController.instance.baseUrl.trim();
    final base = _pickBase(raw, origin).replaceAll(RegExp(r'/+$'), '');
    return '$base/api/v1/music/compat/lastfm/link/callback';
  }

  static bool _isLoopback(String url) {
    final host = Uri.tryParse(url)?.host ?? '';
    return host == '127.0.0.1' ||
        host == 'localhost' ||
        host == '::1' ||
        host.isEmpty;
  }

  static String _pickBase(String baseUrl, String origin) {
    if (baseUrl.isEmpty) return origin;
    if (_isLoopback(baseUrl) && !_isLoopback(origin)) return origin;
    return baseUrl;
  }

  Future<void> _openApplyPage() async {
    const url = 'https://www.last.fm/api/account/create';
    final opened = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
    if (opened) return;
    await Clipboard.setData(const ClipboardData(text: url));
    ToastUtil.show('music_lastfm_copied'.tr);
  }

  Widget _callbackBlock(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'music_lastfm_callback_title'.tr,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: <Widget>[
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 9,
                ),
                decoration: BoxDecoration(
                  color: context.nasStyle.panelColor,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: context.nasStyle.panelBorderColor),
                ),
                child: SelectableText(
                  _callbackUrl,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: _callbackUrl));
                ToastUtil.show('music_lastfm_copied'.tr);
              },
              icon: const Icon(Icons.copy, size: 16),
              label: Text('music_lastfm_copy'.tr),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          'music_lastfm_callback_auto'.tr,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _keyEditing.dispose();
    _secretEditing.dispose();
    if (Get.isRegistered<MusicLastfmSettingsController>()) {
      Get.delete<MusicLastfmSettingsController>(force: true);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 全屏铺满：以前 Align + ConstrainedBox(720) 把整页挤在中间一条，
    // 两边大片留白（用户 2026-11-09 明确要求「要全屏」）。
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 120),
      child: Obx(() {
        final cfg = _ctrl.config.value;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'music_lastfm_title'.tr,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 10),
            _card(child: _introBlock(context)),
            const SizedBox(height: 16),
            _card(child: _credentialBlock(context, cfg)),
            const SizedBox(height: 16),
            _card(child: _accountBlock(context, cfg)),
            const SizedBox(height: 16),
            Text(
              'music_lastfm_cache_hint'.tr,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        );
      }),
    );
  }

  Widget _introBlock(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'music_lastfm_desc'.tr,
          style: theme.textTheme.bodySmall?.copyWith(
            height: 1.7,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.75),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'music_lastfm_apply_prefix'.tr,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 2),
        // 超链接：点了直接开外部浏览器
        InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: _openApplyPage,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  Icons.open_in_new,
                  size: 14,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 6),
                Text(
                  'music_lastfm_apply_link'.tr,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.primary,
                    decoration: TextDecoration.underline,
                    decorationColor: theme.colorScheme.primary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _credentialBlock(BuildContext context, LastfmConfig cfg) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text(
              'music_lastfm_key_label'.tr,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 10),
            _badge(
              context,
              cfg.configured,
              cfg.configured
                  ? 'music_lastfm_key_masked'.tr.replaceFirst(
                      '{key}',
                      cfg.apiKeyMasked,
                    )
                  : 'music_lastfm_not_configured'.tr,
            ),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _keyEditing,
          autocorrect: false,
          onChanged: (v) => _ctrl.draftKey.value = v,
          decoration: InputDecoration(
            isDense: true,
            hintText: 'music_lastfm_key_placeholder'.tr,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
        const SizedBox(height: 14),
        Row(
          children: <Widget>[
            Text(
              'music_lastfm_secret_label'.tr,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 10),
            if (cfg.secretConfigured)
              _badge(context, true, 'music_lastfm_secret_configured'.tr),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _secretEditing,
          autocorrect: false,
          obscureText: true,
          onChanged: (v) => _ctrl.draftSecret.value = v,
          onSubmitted: (_) => _ctrl.save(),
          decoration: InputDecoration(
            isDense: true,
            hintText: 'music_lastfm_secret_placeholder'.tr,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: <Widget>[
            FilledButton.icon(
              onPressed: _ctrl.saving.value ? null : _ctrl.save,
              icon: const Icon(Icons.save_outlined, size: 18),
              label: Text('music_lastfm_save'.tr),
            ),
            OutlinedButton.icon(
              onPressed: _ctrl.testing.value ? null : _ctrl.test,
              icon: const Icon(Icons.wifi_tethering, size: 18),
              label: Text(
                _ctrl.testing.value
                    ? 'music_lastfm_testing'.tr
                    : 'music_lastfm_test'.tr,
              ),
            ),
            OutlinedButton.icon(
              onPressed: _ctrl.saving.value ? null : _ctrl.clearCredentials,
              icon: const Icon(Icons.cancel_outlined, size: 18),
              label: Text('music_lastfm_clear_credentials'.tr),
            ),
            OutlinedButton.icon(
              onPressed: _ctrl.clearCache,
              icon: const Icon(Icons.delete_sweep_outlined, size: 18),
              label: Text('music_lastfm_clear_cache'.tr),
            ),
          ],
        ),
        if (_ctrl.lastTestMessage.value.isNotEmpty) ...<Widget>[
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Icon(
                _ctrl.lastTestOk.value
                    ? Icons.check_circle_outline
                    : Icons.error_outline,
                size: 16,
                color: _ctrl.lastTestOk.value
                    ? theme.colorScheme.primary
                    : theme.colorScheme.error,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _ctrl.lastTestMessage.value,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: _ctrl.lastTestOk.value
                        ? theme.colorScheme.primary
                        : theme.colorScheme.error,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _accountBlock(BuildContext context, LastfmConfig cfg) {
    final theme = Theme.of(context);
    final linked = cfg.linked;
    final username = cfg.username.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text(
              'music_lastfm_account_title'.tr,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 10),
            _badge(
              context,
              linked,
              linked
                  ? 'music_lastfm_linked_as'.tr.replaceFirst(
                      '{name}',
                      username.isEmpty ? '-' : username,
                    )
                  : 'music_lastfm_not_linked'.tr,
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'music_lastfm_account_desc'.tr,
          style: theme.textTheme.bodySmall?.copyWith(
            height: 1.7,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.75),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: <Widget>[
            if (!linked)
              FilledButton.icon(
                onPressed: _ctrl.binding.value ? null : _ctrl.link,
                icon: const Icon(Icons.link, size: 18),
                label: Text(
                  _ctrl.binding.value
                      ? 'music_lastfm_binding'.tr
                      : 'music_lastfm_bind'.tr,
                ),
              ),
            // 兜底：授权页没自动跳回时，用本次 token 直接完成绑定
            if (!linked && _ctrl.pendingToken.value.isNotEmpty)
              OutlinedButton.icon(
                onPressed: _ctrl.binding.value ? null : _ctrl.completeLink,
                icon: const Icon(Icons.task_alt, size: 18),
                label: Text('music_lastfm_complete_link'.tr),
              ),
            if (linked)
              OutlinedButton.icon(
                onPressed: _ctrl.unlink,
                icon: const Icon(Icons.link_off, size: 18),
                label: Text('music_lastfm_unlink'.tr),
              ),
            TextButton.icon(
              onPressed: _ctrl.reload,
              icon: const Icon(Icons.refresh, size: 18),
              label: Text('music_lastfm_refresh'.tr),
            ),
          ],
        ),
        if (!linked && _ctrl.pendingToken.value.isNotEmpty) ...<Widget>[
          const SizedBox(height: 8),
          Text(
            'music_lastfm_complete_hint'.tr,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        const SizedBox(height: 14),
        _callbackBlock(context),
      ],
    );
  }

  Widget _badge(BuildContext context, bool on, String text) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: on
            ? theme.colorScheme.primary.withValues(alpha: 0.12)
            : theme.colorScheme.onSurface.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(
          color: on
              ? theme.colorScheme.primary
              : theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _card({required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: context.nasStyle.panelColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: context.nasStyle.panelBorderColor),
      ),
      child: child,
    );
  }
}
