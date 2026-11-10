import 'package:nas_core/nas_core.dart';

/// 影视「类型 / 题材」数据值 → 界面显示名。
///
/// 和 `video_region_labels.dart` 是一对：地区修完后，同一个筛选面板里的
/// 「类型」仍会把 `nfo_genres` 原值直接显示。真库里日系影片的题材本来就是
/// 中文/日文标签（`單體作品`、`ハイビジョン`…），不用动；但 `tmdb.ts` 请求
/// 没带 `language`，普通影视库刮削回来的是 `Action` / `Drama` /
/// `Science Fiction` 这类英文，中文界面下就会漏英文。
///
/// 做法：把 TMDB 标准类型（含中英常见写法）映射到 **已有的**
/// `discover.genre.*` 文案键，交给 `tr()` 按界面语言出中文或英文；
/// 映射不到的值（厂牌名、番号、缩写、日文标签）**原样保留**，不硬翻。
/// 选中/提交筛选时始终用原始值，显示名只影响 UI。
///
/// ⚠️ `tr()` 缺键会回落到「键本身」（`discover.genre.xxx`），那比英文更难看，
/// 所以下面对返回值做了一道兜底。
const Map<String, String> _kGenreKeys = <String, String>{
  'action': 'action',
  '动作': 'action',
  '动作片': 'action',
  'actionadventure': 'action',
  'adventure': 'adventure',
  '冒险': 'adventure',
  '冒险片': 'adventure',
  'animation': 'animation',
  'anime': 'animation',
  '动画': 'animation',
  '動畫': 'animation',
  '动画片': 'animation',
  'comedy': 'comedy',
  '喜剧': 'comedy',
  '喜劇': 'comedy',
  '喜剧片': 'comedy',
  'crime': 'crime',
  '犯罪': 'crime',
  '犯罪片': 'crime',
  'documentary': 'documentary',
  '纪录片': 'documentary',
  '紀錄片': 'documentary',
  '纪录': 'documentary',
  'drama': 'drama',
  '剧情': 'drama',
  '劇情': 'drama',
  '剧情片': 'drama',
  '戲劇': 'drama',
  '戏剧': 'drama',
  'family': 'family',
  '家庭': 'family',
  '家庭片': 'family',
  'fantasy': 'fantasy',
  '奇幻': 'fantasy',
  '奇幻片': 'fantasy',
  'history': 'history',
  '历史': 'history',
  '歷史': 'history',
  '历史片': 'history',
  'horror': 'horror',
  '恐怖': 'horror',
  '恐怖片': 'horror',
  'music': 'music',
  '音乐': 'music',
  '音樂': 'music',
  '音乐片': 'music',
  'mystery': 'mystery',
  '悬疑': 'mystery',
  '懸疑': 'mystery',
  '推理': 'mystery',
  '悬疑片': 'mystery',
  'reality': 'reality',
  'realitytv': 'reality',
  '真人秀': 'reality',
  '真人實境': 'reality',
  'romance': 'romance',
  '爱情': 'romance',
  '愛情': 'romance',
  '爱情片': 'romance',
  'scifi': 'scifi',
  'sciencefiction': 'scifi',
  'scififantasy': 'scifi',
  'sciencefictionfantasy': 'scifi',
  '科幻': 'scifi',
  '科幻片': 'scifi',
  'thriller': 'thriller',
  '惊悚': 'thriller',
  '驚悚': 'thriller',
  '惊悚片': 'thriller',
  'war': 'war',
  'warpolitics': 'war',
  '战争': 'war',
  '戰爭': 'war',
  '战争片': 'war',
  'western': 'western',
  '西部': 'western',
  '西部片': 'western',
  'tvmovie': 'tvMovie',
  '电视电影': 'tvMovie',
  '電視電影': 'tvMovie',
  'kids': 'kids',
  '儿童': 'kids',
  '兒童': 'kids',
  'news': 'news',
  '新闻': 'news',
  '新聞': 'news',
  'soap': 'soap',
  '肥皂剧': 'soap',
  'talk': 'talk',
  'talkshow': 'talk',
  '脱口秀': 'talk',
};

/// 忽略大小写、空白、常见连接符，让 `Science Fiction` / `Sci-Fi` 同义。
String _norm(String s) => s
    .trim()
    .toLowerCase()
    .replaceAll(RegExp(r'[\s\-_&·・.,，/]+'), '');

/// 单个题材值的显示名；表里没有的原样返回。
String genreLabel(String raw) {
  final key = _kGenreKeys[_norm(raw)];
  if (key == null) return raw;
  final text = I18n.instance.tr('discover.genre.$key');
  // 键还没进语言包时 tr() 会把键名吐出来，比英文还难看
  return text.startsWith('discover.genre.') ? raw : text;
}

/// 一批题材值的显示名（详情页 meta 行用）。
List<String> genreLabels(Iterable<String> raws) =>
    raws.map(genreLabel).toList(growable: false);
