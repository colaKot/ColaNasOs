import 'play_quality.dart';
import 'settings_store.dart';

/// 播放偏好的唯一落盘入口（改进 6.4）。
///
/// 画质 / 编码统一写在 `player.preset` / `player.codec` 两个键上，
/// Web、桌面、后续安卓 / TV 端读同一份；旧版 `video.preset` / `video.codec`
/// 作为回退值读取，升级后首次保存即迁移到新键。
class PlayPreferences {
  static const _presetKey = 'player.preset';
  static const _codecKey = 'player.codec';

  static String get preset {
    final saved =
        SettingsStore.instance.getString(_presetKey) ??
        SettingsStore.instance.getString('video.preset');
    return playQualityPresetOf(saved ?? '')?.key ?? defaultPlayPreset;
  }

  static String get codec {
    final saved =
        SettingsStore.instance.getString(_codecKey) ??
        SettingsStore.instance.getString('video.codec');
    return playCodecOf(saved ?? '')?.key ?? defaultPlayCodec;
  }

  static Future<void> save({required String preset, required String codec}) async {
    await SettingsStore.instance.setString(_presetKey, preset);
    await SettingsStore.instance.setString(_codecKey, codec);
  }
}
