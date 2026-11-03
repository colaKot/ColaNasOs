import 'package:nas_core/nas_core.dart';

import 'settings_store.dart';

/// 字幕语言偏好（SP3-03 二期）：
///
/// `off` = 关闭字幕，`auto` = 用第一个可用字幕，其余是语言标签（`zh` / `zh-CN` / `en`）。
/// 选择记在本地设置里，下次打开任意影片自动套用。
class VideoSubtitlePrefs {
  VideoSubtitlePrefs._();

  static final VideoSubtitlePrefs instance = VideoSubtitlePrefs._();

  static const String key = 'video.subtitleLang';
  static const String auto = 'auto';
  static const String off = 'off';

  String get preferred => SettingsStore.instance.getString(key) ?? auto;

  Future<void> set(String value) => SettingsStore.instance.setString(key, value);
}

/// 按偏好挑字幕（纯函数，便于单测）：
///
/// - `off` → null；
/// - `auto` → 第一条；
/// - 语言标签按前缀匹配（`zh` 命中 `zh-CN`），都匹配不上时回退第一条；
/// - 空列表 → null。
VideoSubtitleFile? pickSubtitle(List<VideoSubtitleFile> items, String preferred) {
  if (items.isEmpty) return null;
  if (preferred == VideoSubtitlePrefs.off) return null;
  if (preferred == VideoSubtitlePrefs.auto) return items.first;

  final want = preferred.toLowerCase();
  for (final item in items) {
    final lang = (item.lang ?? '').toLowerCase();
    if (lang.isEmpty) continue;
    if (lang == want || lang.startsWith('$want-') || lang.startsWith(want)) {
      return item;
    }
  }
  return items.first;
}