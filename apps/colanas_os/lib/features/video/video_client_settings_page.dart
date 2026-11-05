import 'package:flutter/material.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/play_quality.dart';
import '../../core/play_preferences.dart';

/// 客户端设置：**只影响当前这台机器 / 这个浏览器**。
///
/// 与「影视设置」的分界：
///   - 影视设置 = 服务端级（TMDB、字幕抓取、所有客户端共享）
///   - 客户端设置 = 播放偏好（画质 / 编码 / 音频），存本地，不写库
///
/// 音频两项是「覆盖」语义：关 = 不传参数 = 跟随库级 `audio_normalize` 开关，
/// 打开才在本次会话强制生效。默认值与改动前完全一致。
class VideoClientSettingsPage extends StatefulWidget {
  const VideoClientSettingsPage({super.key});

  @override
  State<VideoClientSettingsPage> createState() => _VideoClientSettingsPageState();
}

class _VideoClientSettingsPageState extends State<VideoClientSettingsPage> {
  late String _preset = PlayPreferences.preset;
  late String _codec = PlayPreferences.codec;
  late bool _normalize = PlayPreferences.audioNormalize;
  late bool _downmix = PlayPreferences.audioDownmix;

  /// 当前档位规格（height / 各编码码率 / 是否原画）
  PlayQualityPreset get _presetSpec =>
      playQualityPresetOf(_preset) ?? playQualityPresets.first;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        NasTokens.spaceLg,
        NasTokens.spaceMd,
        NasTokens.spaceLg,
        NasTokens.spaceXl,
      ),
      children: [
        Row(
          children: [
            Icon(Icons.devices, size: 16, color: context.nasTextSecondary),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                tr('video.client.localOnly'),
                style: TextStyle(fontSize: NasTokens.fontCaption, color: context.nasTextSecondary),
              ),
            ),
          ],
        ),

        _section(tr('video.client.group.play')),
        _setting(
          title: tr('video.client.playQuality'),
          hint: tr('video.client.playQualityHint'),
          trailing: NasDropdown<String>(
            value: _preset,
            isDense: true,
            underline: const SizedBox.shrink(),
            items: [
              for (final p in playQualityPresets)
                DropdownMenuItem<String>(
                  value: p.key,
                  // 同一档位在不同编码下流量不同，所以码率跟着「当前编码」显示
                  child: Text('${p.label} · ${p.bitrateLabelFor(_codec)}'),
                ),
            ],
            onChanged: (v) async {
              if (v == null) return;
              setState(() => _preset = v);
              await PlayPreferences.savePreset(v);
            },
          ),
        ),
        _setting(
          title: tr('video.client.codec'),
          hint: tr('video.client.codecHint'),
          trailing: NasDropdown<String>(
            value: _codec,
            isDense: true,
            underline: const SizedBox.shrink(),
            items: [
              for (final c in playCodecs)
                DropdownMenuItem<String>(value: c.key, child: Text(c.label)),
            ],
            onChanged: (v) async {
              if (v == null) return;
              setState(() => _codec = v);
              await PlayPreferences.saveCodec(v);
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 2),
          child: Text(
            _presetSpec.copy
                ? tr('video.client.copyNoTranscode')
                : tr('video.client.bitrateNow', {
                    'rate': _presetSpec.bitrateLabelFor(_codec),
                  }),
            style: TextStyle(fontSize: NasTokens.fontCaption, color: context.nasTextSecondary),
          ),
        ),

        _section(tr('video.client.group.audio')),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: _normalize,
          title: Text(tr('video.client.audioNormalize')),
          subtitle: Text(
            tr('video.client.audioNormalizeHint'),
            style: TextStyle(fontSize: NasTokens.fontCaption, color: context.nasTextSecondary),
          ),
          onChanged: (v) async {
            setState(() => _normalize = v);
            await PlayPreferences.saveAudio(normalize: v);
          },
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: _downmix,
          title: Text(tr('video.client.downmix')),
          subtitle: Text(
            tr('video.client.downmixHint'),
            style: TextStyle(fontSize: NasTokens.fontCaption, color: context.nasTextSecondary),
          ),
          onChanged: (v) async {
            setState(() => _downmix = v);
            await PlayPreferences.saveAudio(downmix: v);
          },
        ),
      ],
    );
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.only(top: NasTokens.spaceLg, bottom: NasTokens.spaceXs),
        child: Text(
          title,
          style: TextStyle(
            fontSize: NasTokens.fontCaption,
            fontWeight: FontWeight.w600,
            color: context.nasTextSecondary,
          ),
        ),
      );

  /// 一行设置：左标题 + 提示，右控件（下拉 / 开关）。窄屏也不挤，提示可换行。
  Widget _setting({required String title, required String hint, required Widget trailing}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w500)),
                const SizedBox(height: 2),
                Text(
                  hint,
                  style: TextStyle(fontSize: NasTokens.fontCaption, color: context.nasTextSecondary),
                ),
              ],
            ),
          ),
          const SizedBox(width: NasTokens.spaceSm),
          trailing,
        ],
      ),
    );
  }
}
