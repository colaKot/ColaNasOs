import 'package:flutter/material.dart';
import 'package:nas_ui/nas_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/app_version.dart';
import '../../core/external_link.dart';
import '../../core/session.dart';
import '../update/update_service.dart';

/// 相册独立端「更多 → 关于」。
///
/// 只放用户真正用得上的四件事：
///   1. 这是哪一版（版本号与主客户端**同一份真源** `kAppVersion`，构建号 `kAppVersionCode`）；
///   2. 有没有新版本 / 现在就装（复用 [UpdateService]，与登录后的自动检查同一套状态机）；
///   3. 现在连的是哪台 NAS（换服务器 / 排查连不上时第一眼要看的东西）；
///   4. 从哪来的（项目主页 / 开源许可）。
class PhotoAboutPage extends StatefulWidget {
  const PhotoAboutPage({super.key});

  @override
  State<PhotoAboutPage> createState() => _PhotoAboutPageState();
}

class _PhotoAboutPageState extends State<PhotoAboutPage> {
  Future<void> _openUrl(String url) async {
    var ok = false;
    if (canOpenExternalLinks) {
      ok = openExternalLink(url);
    } else {
      try {
        ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      } catch (_) {
        // 精简系统没装浏览器：退化成下面这句「可复制的地址」
        ok = false;
      }
    }
    if (!ok && mounted) NasSnack.show(context, url);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(NasTokens.spaceLg),
      children: [
        _header(context, scheme),
        const SizedBox(height: NasTokens.spaceMd),
        _serverRow(context),
        const SizedBox(height: NasTokens.spaceMd),
        _updatePanel(context, scheme),
        const SizedBox(height: NasTokens.spaceMd),
        _linksPanel(context, scheme),
        const SizedBox(height: NasTokens.spaceLg),
        Text(
          tr('ui.settings.h4b0e3b'),
          style: TextStyle(fontSize: NasTokens.fontCaption, color: context.nasTextSecondary),
        ),
      ],
    );
  }

  Widget _header(BuildContext context, ColorScheme scheme) {
    return NasPanel(
      child: Row(
        children: [
          Icon(Icons.photo_library_outlined, size: 40, color: scheme.primary),
          const SizedBox(width: NasTokens.spaceMd),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr('app.photo'),
                  style: const TextStyle(fontSize: NasTokens.fontTitle, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: NasTokens.spaceXs),
                // 版本号等宽字体 + 主题色：用户要的就是「一眼看到」
                SelectableText(
                  'v$kAppVersion',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: scheme.primary,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(height: NasTokens.spaceXs),
                Text(
                  tr('photo.about.build', {'code': '$kAppVersionCode'}),
                  style: TextStyle(fontSize: NasTokens.fontCaption, color: context.nasTextSecondary),
                ),
                const SizedBox(height: NasTokens.spaceXs),
                Text(
                  tr('photo.about.tagline'),
                  style: TextStyle(fontSize: NasTokens.fontCaption, color: context.nasTextSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _serverRow(BuildContext context) {
    final baseUrl = ApiSession.instance.baseUrl;
    return NasPanel(
      child: Row(
        children: [
          Icon(Icons.dns_outlined, size: 18, color: context.nasTextSecondary),
          const SizedBox(width: NasTokens.spaceXs),
          Text(tr('tv.profile.server'), style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(width: NasTokens.spaceMd),
          Expanded(
            child: SelectableText(
              baseUrl.isEmpty ? '-' : baseUrl,
              textAlign: TextAlign.right,
              style: TextStyle(fontSize: NasTokens.fontCaption, color: context.nasTextSecondary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _updatePanel(BuildContext context, ColorScheme scheme) {
    return ValueListenableBuilder<ClientUpdate?>(
      valueListenable: UpdateService.instance.available,
      builder: (context, info, _) {
        return ValueListenableBuilder<UpdateStatus>(
          valueListenable: UpdateService.instance.status,
          builder: (context, status, _) {
            final busy = status.busy;
            final hasUpdate = info?.hasUpdate == true;
            final asset = info?.assetFor(UpdateService.instance.component);
            return NasPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.system_update_alt, size: 18, color: scheme.primary),
                      const SizedBox(width: NasTokens.spaceXs),
                      Text(
                        tr('update.clientTitle'),
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                  const SizedBox(height: NasTokens.spaceSm),
                  Text(_stateText(info, status), style: const TextStyle(height: 1.5)),
                  if (hasUpdate && info != null && info.notes.trim().isNotEmpty) ...[
                    const SizedBox(height: NasTokens.spaceXs),
                    Text(
                      info.notes,
                      style: TextStyle(fontSize: NasTokens.fontCaption, color: context.nasTextSecondary),
                    ),
                  ],
                  if (hasUpdate && asset != null) ...[
                    const SizedBox(height: NasTokens.spaceXs),
                    Text(
                      tr('update.size', {'size': UpdateService.formatBytes(asset.size)}),
                      style: TextStyle(fontSize: NasTokens.fontCaption, color: context.nasTextSecondary),
                    ),
                  ],
                  if (busy) ...[
                    const SizedBox(height: NasTokens.spaceSm),
                    LinearProgressIndicator(value: status.progress > 0 ? status.progress : null),
                    const SizedBox(height: NasTokens.spaceXs),
                    Text(
                      _progressText(status),
                      style: TextStyle(fontSize: NasTokens.fontCaption, color: context.nasTextSecondary),
                    ),
                  ],
                  const SizedBox(height: NasTokens.spaceMd),
                  Wrap(
                    spacing: NasTokens.spaceSm,
                    runSpacing: NasTokens.spaceXs,
                    children: [
                      if (busy)
                        OutlinedButton(
                          onPressed: UpdateService.instance.cancel,
                          child: Text(tr('update.cancel')),
                        )
                      else if (hasUpdate && asset != null)
                        FilledButton(
                          onPressed: UpdateService.instance.startInstall,
                          child: Text(tr('update.now')),
                        ),
                      if (!busy)
                        OutlinedButton(
                          onPressed: () => UpdateService.instance.check(force: true),
                          child: Text(tr('update.check')),
                        ),
                    ],
                  ),
                  if (hasUpdate && asset == null) ...[
                    const SizedBox(height: NasTokens.spaceXs),
                    Text(
                      tr('update.noAsset'),
                      style: TextStyle(fontSize: NasTokens.fontCaption, color: scheme.error),
                    ),
                  ],
                ],
              ),
            );
          },
        );
      },
    );
  }

  String _stateText(ClientUpdate? info, UpdateStatus status) {
    switch (status.phase) {
      case UpdatePhase.checking:
        return tr('update.checking');
      case UpdatePhase.available:
        final version = info?.latestSemver ?? '';
        if (version.isEmpty) return tr('update.none');
        return tr('update.clientAvailable', {'version': version});
      case UpdatePhase.downloading:
      case UpdatePhase.verifying:
      case UpdatePhase.installing:
        return tr('update.clientAvailable', {'version': info?.latestSemver ?? ''});
      case UpdatePhase.done:
        return tr('update.restartHint');
      case UpdatePhase.failed:
        return status.error.isEmpty ? tr('update.checkFailed') : tr('update.failed', {'error': status.error});
      case UpdatePhase.idle:
        if (info != null && !info.hasUpdate) {
          return tr('update.noneWithVersion', {'version': kAppVersion});
        }
        return tr('update.autoCheck');
    }
  }

  String _progressText(UpdateStatus status) {
    switch (status.phase) {
      case UpdatePhase.verifying:
        return tr('update.verifying');
      case UpdatePhase.installing:
        return tr('update.installing');
      default:
        final speed = UpdateService.formatSpeed(status.speed);
        final loaded = UpdateService.formatBytes(status.loaded);
        final total = UpdateService.formatBytes(status.total);
        return speed.isEmpty ? '$loaded / $total' : '$loaded / $total · $speed';
    }
  }

  Widget _linksPanel(BuildContext context, ColorScheme scheme) {
    return NasPanel(
      padding: const EdgeInsets.symmetric(vertical: NasTokens.spaceXs),
      child: Column(
        children: [
          ListTile(
            leading: Icon(Icons.code, size: 20, color: context.nasTextSecondary),
            title: Text(tr('settings.projectHome')),
            subtitle: Text(kProjectUrl, style: TextStyle(fontSize: NasTokens.fontCaption, color: scheme.primary)),
            trailing: Icon(Icons.open_in_new, size: 16, color: scheme.primary),
            onTap: () => _openUrl(kProjectUrl),
          ),
          ListTile(
            leading: Icon(Icons.article_outlined, size: 20, color: context.nasTextSecondary),
            title: Text(tr('photo.about.licenses')),
            trailing: const Icon(Icons.chevron_right, size: 18),
            onTap: () => showLicensePage(
              context: context,
              applicationName: tr('app.photo'),
              applicationVersion: 'v$kAppVersion+$kAppVersionCode',
            ),
          ),
        ],
      ),
    );
  }
}
