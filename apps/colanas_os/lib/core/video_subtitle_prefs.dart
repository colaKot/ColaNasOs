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

/// 按播放位置取当前应显示的字幕文本（纯函数，便于单测）。
///
/// 服务端 `/video/subtitle` 已经把 srt/ass/vtt 解析成结构化 `cues`，播放器
/// 直接按位置自绘，不再走 media_kit 的 `SubtitleTrack.data`：Web 内核挂的是
/// blob `<track>`，`open()` 会用 `element.innerHTML = ''` 把它清掉，切换字幕时
/// 又固定读 `textTracks[0]`。多条 cue 重叠时按文件顺序换行合并；ASS 的
/// Dialogue 未必按时间排序，所以线性扫而不假设有序。
String activeSubtitleText(List<VideoSubtitleCue> cues, int positionMs) {
  if (cues.isEmpty) return '';
  final lines = <String>[];
  for (final cue in cues) {
    if (cue.startMs <= positionMs && cue.endMs > positionMs) {
      final text = cue.text.trim();
      if (text.isNotEmpty) lines.add(text);
    }
  }
  return lines.join('\n');
}