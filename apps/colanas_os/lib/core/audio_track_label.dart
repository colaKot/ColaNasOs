/// 音轨菜单的一行文案。
///
/// 转码流的 `tracks.audio` 只有一条，用户在菜单里只看到「音轨 1 / 2 / 3」，
/// 分不出哪条是国语、哪条是英语。语言和音轨名只在源文件容器里，服务端用
/// ffprobe 读出来（`/video/audio-tracks`），这里负责拼成人能读的一行：
///
///   `1 · 上海领声国语 · AC3 5.1`
///
/// 同一份数据结构见实测（《匹诺曹》）：
///   1. eng / 英语        / truehd / 8ch / 7.1
///   2. chi / 上海领声国语 / ac3    / 6ch / 5.1(side)
///   3. chi / 台配国语     / ac3    / 6ch / 5.1(side)
library;

/// 语言代码 → 可读名字。
///
/// 用**母语名**（中文 / English / 日本語）而不是按界面语言翻译：母语名对谁都认得出，
/// 也不用为十几种语言各加一批 i18n 键。容器里可能是 ISO 639-2（chi / zho / eng）
/// 或 639-1（zh / en），两种都收。
const Map<String, String> audioLangNames = {
  'zh': '中文',
  'chi': '中文',
  'zho': '中文',
  'cmn': '中文',
  'chs': '中文',
  'cht': '中文',
  'yue': '粤语',
  'en': 'English',
  'eng': 'English',
  'ja': '日本語',
  'jpn': '日本語',
  'ko': '한국어',
  'kor': '한국어',
  'fr': 'Français',
  'fra': 'Français',
  'fre': 'Français',
  'de': 'Deutsch',
  'deu': 'Deutsch',
  'ger': 'Deutsch',
  'es': 'Español',
  'spa': 'Español',
  'it': 'Italiano',
  'ita': 'Italiano',
  'ru': 'Русский',
  'rus': 'Русский',
  'pt': 'Português',
  'por': 'Português',
  'th': 'ไทย',
  'tha': 'ไทย',
  'vi': 'Tiếng Việt',
  'vie': 'Tiếng Việt',
};

/// 编码标识 → 展示名。ffprobe 给的是小写（`truehd` / `eac3`），
/// 直接大写会得到认不出的 `TRUEHD`。
const Map<String, String> audioCodecNames = {
  'truehd': 'TrueHD',
  'eac3': 'E-AC3',
  'ac3': 'AC3',
  'dts': 'DTS',
  'aac': 'AAC',
  'flac': 'FLAC',
  'opus': 'Opus',
  'vorbis': 'Vorbis',
  'mp3': 'MP3',
};

/// 拼一行音轨文案。
///
/// - `ordinal` 是**音频轨序号**（0 起），界面上显示 1 起；
/// - 语言优先用容器标的 `title`（发布组常写「台配国语」这种具体来源），
///   没有才按 `language` 代码查表；
/// - 两样都没有时只留序号和编码，不硬编一个「未知语言」；
/// - `5.1(side)` 这类容器写法去掉括号部分，界面上只留 `5.1`。
String audioTrackLabel({
  required int ordinal,
  String? language,
  String? title,
  String? codec,
  String? channelLayout,
  int? channels,
}) {
  final langCode = (language ?? '').trim().toLowerCase();
  final rawTitle = (title ?? '').trim();
  final name = rawTitle.isNotEmpty
      ? rawTitle
      : (audioLangNames[langCode] ?? (language ?? '').trim());

  final parts = <String>['${ordinal + 1}'];
  if (name.isNotEmpty) parts.add(name);

  final codecKey = (codec ?? '').trim().toLowerCase();
  final codecName =
      audioCodecNames[codecKey] ?? (codecKey.isEmpty ? '' : codecKey.toUpperCase());
  final layout =
      (channelLayout ?? (channels != null ? '${channels}ch' : ''))
          .replaceAll(RegExp(r'\(.*?\)'), '')
          .trim();
  final tech = [codecName, layout].where((x) => x.isNotEmpty).join(' ');
  if (tech.isNotEmpty) parts.add(tech);

  return parts.join(' · ');
}
