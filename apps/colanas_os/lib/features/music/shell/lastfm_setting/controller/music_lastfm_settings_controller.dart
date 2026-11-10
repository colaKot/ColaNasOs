import 'dart:async';

import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../compat/getx.dart';
import '../../compat/host.dart';
import '../../detail/models/music_detail_models.dart';
import '../../detail/service/music_detail_api_service.dart';

/// 「在线数据源（Last.fm）」设置页状态。
///
/// 两件事分开看：
/// - **读公开数据**（歌手热门 / 专辑播放量）只要 API Key，不需要用户登录；
/// - **写播放记录**（Scrobble）需要用户授权，走
///   `auth.getToken → 浏览器同意 → 回调换 session key` 那一套。
///   Key / Secret 存服务端，session key 按用户单独存。
class MusicLastfmSettingsController extends GetxController {
  final RxBool loading = true.obs;
  final RxBool saving = false.obs;
  final RxBool testing = false.obs;
  final RxBool binding = false.obs;
  final Rx<LastfmConfig> config = const LastfmConfig(
    configured: false,
    apiKeyMasked: '',
  ).obs;
  final RxString draftKey = ''.obs;

  /// 本次绑定的临时 token。Last.fm 授权页没跳回时靠它兜底换 session
  final RxString pendingToken = ''.obs;
  final RxString draftSecret = ''.obs;
  final RxString lastTestMessage = ''.obs;
  final RxBool lastTestOk = false.obs;

  final MusicDetailApiService _api = MusicDetailApiService.instance;

  @override
  void onInit() {
    super.onInit();
    unawaited(reload());
  }

  Future<void> reload() async {
    loading.value = true;
    try {
      config.value = await _api.lastfmConfig();
      // 未绑定但服务端还有「授权过、没换 session」的 pending token：补完成。
      // 这一步是必需的：token 只存在客户端内存里，页面刷新（换网络 / 换域名 /
      // 重启 App）就丢了，否则用户永远是「我明明绑过，怎么又说没绑」。
      if (!config.value.linked && await _api.lastfmResume()) {
        config.value = await _api.lastfmConfig();
        // 补绑定成功要说一声，否则用户只会看到「未绑定」悄悄变成「已绑定」
        ToastUtil.show(
          'music_lastfm_linked_as'.tr.replaceFirst(
            '{name}',
            config.value.username.isEmpty ? '-' : config.value.username,
          ),
        );
      }
    } finally {
      loading.value = false;
    }
  }

  /// 只提交填了的字段：留空 = 不修改（避免「只想改 Secret」时把 Key 清掉）
  Future<void> save() async {
    if (saving.value) return;
    final key = draftKey.value.trim();
    final secret = draftSecret.value.trim();
    if (key.isEmpty && secret.isEmpty) {
      ToastUtil.show('music_lastfm_input_required'.tr);
      return;
    }
    saving.value = true;
    try {
      config.value = await _api.saveLastfmCreds(
        apiKey: key.isEmpty ? null : key,
        apiSecret: secret.isEmpty ? null : secret,
      );
      draftKey.value = '';
      draftSecret.value = '';
      ToastUtil.show(
        config.value.configured
            ? 'music_lastfm_saved'.tr
            : 'music_lastfm_cleared'.tr,
      );
    } finally {
      saving.value = false;
    }
  }

  /// 清除凭证（Key + Secret；已绑定的账号也会随之失效，需要重新绑）
  Future<void> clearCredentials() async {
    if (saving.value) return;
    saving.value = true;
    try {
      config.value = await _api.saveLastfmCreds(apiKey: '', apiSecret: '');
      ToastUtil.show('music_lastfm_cleared'.tr);
    } finally {
      saving.value = false;
    }
  }

  /// 发起绑定：拿授权页地址 → 外部浏览器打开。
  ///
  /// 授权完成后 Last.fm 重定向到服务端 `/compat/lastfm/link/callback`，
  /// 那边换 session key 并写库；回到 App 点「刷新状态」就能看到用户名。
  Future<void> link() async {
    if (binding.value) return;
    binding.value = true;
    try {
      final start = await _api.lastfmLinkStart();
      if (start.url.isEmpty) {
        ToastUtil.show('music_lastfm_bind_failed'.tr);
        return;
      }
      // 记下 token：授权完不一定会自动跳回（Last.fm 没配 Callback URL 时只显示
      // 「可以关闭浏览器了」），那时点「我已完成授权」用它换 session。
      pendingToken.value = start.token;
      final opened = await launchUrl(
        Uri.parse(start.url),
        mode: LaunchMode.externalApplication,
      );
      if (!opened) {
        // 桌面端没有默认浏览器 / 被拦截时，至少让用户能自己粘出去
        await Clipboard.setData(ClipboardData(text: start.url));
        ToastUtil.show('music_lastfm_link_copied'.tr);
      }
    } catch (_) {
      ToastUtil.show('music_lastfm_bind_failed'.tr);
    } finally {
      binding.value = false;
    }
  }

  /// 兜底：授权页没自动跳回来时，用本次 token 直接换 session
  Future<void> completeLink() async {
    final token = pendingToken.value.trim();
    if (token.isEmpty) {
      ToastUtil.show('music_lastfm_complete_no_token'.tr);
      return;
    }
    if (binding.value) return;
    binding.value = true;
    try {
      final result = await _api.lastfmComplete(token);
      if (!result.ok) {
        ToastUtil.show('music_lastfm_complete_failed'.tr);
        return;
      }
      pendingToken.value = '';
      await reload();
      ToastUtil.show(
        'music_lastfm_linked_as'.tr.replaceFirst(
          '{name}',
          result.username.isEmpty ? '-' : result.username,
        ),
      );
    } finally {
      binding.value = false;
    }
  }

  Future<void> unlink() async {
    final ok = await _api.lastfmUnlink();
    if (!ok) {
      ToastUtil.show('operation_failed'.tr);
      return;
    }
    await reload();
    ToastUtil.show('music_lastfm_unlinked'.tr);
  }

  Future<void> test() async {
    if (testing.value) return;
    testing.value = true;
    lastTestMessage.value = '';
    try {
      final result = await _api.testLastfm();
      lastTestOk.value = result.ok;
      lastTestMessage.value = result.ok
          ? 'music_lastfm_test_ok'.tr
          : (result.message.isEmpty
                ? 'music_lastfm_test_failed'.tr
                : result.message);
    } finally {
      testing.value = false;
    }
  }

  Future<void> clearCache() async {
    final removed = await _api.clearCache();
    ToastUtil.show(
      removed > 0
          ? '${'music_lastfm_cache_cleared'.tr}（$removed）'
          : 'music_lastfm_cache_cleared'.tr,
    );
  }
}
