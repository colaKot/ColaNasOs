import 'play_quality.dart';
import 'settings_store.dart';

/// 播放偏好的唯一落盘入口（改进 6.4）。
///
/// 画质 / 编码统一写在 `player.preset` / `player.codec` 两个键上，
/// Web、桌面、后续安卓 / TV 端读同一份；旧版 `video.preset` / `video.codec`
/// 作为回退值读取，升级后首次保存即迁移到新键。
///
/// 音频两项（`player.audioNormalize` / `player.audioDownmix`）是**客户端覆盖**：
/// 只有用户显式打开才随转码会话传下去；关闭 = 不传 = 跟随库级 `audio_normalize` 开关，
/// 所以默认值与加这两个开关之前的行为完全一致。
class PlayPreferences {
  static const _presetKey = 'player.preset';
  static const _codecKey = 'player.codec';
  static const _normalizeKey = 'player.audioNormalize';
  static const _downmixKey = 'player.audioDownmix';
  static const _leadKey = 'player.leadMinutes';

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

  static bool get audioNormalize => SettingsStore.instance.getBool(_normalizeKey) == true;

  static bool get audioDownmix => SettingsStore.instance.getBool(_downmixKey) == true;

  /// 默认提前转码时长（分钟）。0 = 整片一次转完（老行为，也是默认值）。
  /// 只转播放位置前面的一小段，看到哪儿转到哪儿，不浪费 CPU。
  static int get leadMinutes {
    final v = int.tryParse(SettingsStore.instance.getString(_leadKey) ?? '') ?? 0;
    return v <= 0 ? 0 : (v > 60 ? 60 : v);
  }

  static Future<void> saveLeadMinutes(int minutes) =>
      SettingsStore.instance.setString(_leadKey, '${minutes <= 0 ? 0 : minutes}');

  static Future<void> save({required String preset, required String codec}) async {
    await SettingsStore.instance.setString(_presetKey, preset);
    await SettingsStore.instance.setString(_codecKey, codec);
  }

  static Future<void> savePreset(String preset) =>
      SettingsStore.instance.setString(_presetKey, preset);

  static Future<void> saveCodec(String codec) =>
      SettingsStore.instance.setString(_codecKey, codec);

  static Future<void> saveAudio({bool? normalize, bool? downmix}) async {
    if (normalize != null) await SettingsStore.instance.setBool(_normalizeKey, normalize);
    if (downmix != null) await SettingsStore.instance.setBool(_downmixKey, downmix);
  }
}
