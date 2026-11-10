import 'package:nas_core/nas_core.dart';

/// 影片「地区 / 国家」值的本地化与同义合并。
///
/// 数据现状（`nfo_regions`）：同一个地区会存成好几种写法 —— 刮削器写中文
/// （`日本`），TMDB 写英文（`Japan`），NFO 里的 `<country>` 原样保留
/// （`United States of America`）。真库实测 917 条有地区的影片里，
/// 「日本」709 条 + "Japan" 179 条是同一个国家，筛选面板却裂成两个 chip，
/// 而且切换界面语言时这两个 chip 一个字都不变。
///
/// 这里做三件事：
///   1. **按当前界面语言显示**：zh-CN 显示「日本」，en-US 显示 "Japan"；
///      表里没有的地区名**原样显示**（其它语言写的就用其它语言，不硬翻）。
///   2. **同义写法合并成一项**：选中「日本」时把该组所有写法一起提交，
///      服务端 `likeJson` 用的是 OR，所以 200 条样本里没抽到的写法照样命中。
///   3. **提交值不带逗号**：`regions` 是逗号拼接的 querystring
///      （`items.ts#csvList` 按 `,` 拆、上限 40 个），含逗号的值会被拆坏，
///      也会白占名额，所以只交「样本原值 + 中英主写法」。
///
/// 地区名是**数据值的显示映射**（要能反查存储值、要能合并别名），不是 UI 文案，
/// 所以放在这张双语表里而不是塞进 `tr()` —— i18n 的 key→文案是单向的，
/// 既承载不了别名分组，也没有「未知值原样」的兜底。
class _RegionGroup {
  const _RegionGroup({
    required this.id,
    required this.zh,
    required this.en,
    this.aliases = const <String>[],
  });

  final String id;
  final String zh;
  final String en;
  final List<String> aliases;

  List<String> get forms => <String>[zh, en, ...aliases];
}

/// 覆盖真库出现过的全部 13 个值 + 常见国家/地区。
///
/// ⚠️ 香港、澳门、台湾按规范写作「中国香港 / 中国澳门 / 中国台湾」，
/// 英文用 "Hong Kong, China" / "Macao, China" / "Taiwan, China"。
const List<_RegionGroup> _kGroups = <_RegionGroup>[
  _RegionGroup(
    id: 'japan',
    zh: '日本',
    en: 'Japan',
    aliases: <String>['JP', '日本国', 'Nippon'],
  ),
  _RegionGroup(
    id: 'china',
    zh: '中国',
    en: 'China',
    aliases: <String>['CN', '中国大陆', '大陆', 'PRC', 'China (Mainland)'],
  ),
  _RegionGroup(
    id: 'hongkong',
    zh: '中国香港',
    en: 'Hong Kong, China',
    aliases: <String>['Hong Kong', 'HK', '香港', 'Hong Kong SAR'],
  ),
  _RegionGroup(
    id: 'macau',
    zh: '中国澳门',
    en: 'Macao, China',
    aliases: <String>['Macao', 'Macau', 'MO', '澳门', 'Macau, China'],
  ),
  _RegionGroup(
    id: 'taiwan',
    zh: '中国台湾',
    en: 'Taiwan, China',
    aliases: <String>['Taiwan', 'TW', '台湾', '中国台湾'],
  ),
  _RegionGroup(
    id: 'usa',
    zh: '美国',
    en: 'United States',
    aliases: <String>[
      'United States of America',
      'USA',
      'U.S.A.',
      'US',
      'America',
      '美利坚合众国',
      '米国',
    ],
  ),
  _RegionGroup(
    id: 'uk',
    zh: '英国',
    en: 'United Kingdom',
    aliases: <String>['UK', 'Great Britain', 'Britain', 'England', '大不列颠', '英格兰'],
  ),
  _RegionGroup(
    id: 'korea',
    zh: '韩国',
    en: 'South Korea',
    aliases: <String>['Korea', 'KR', 'Republic of Korea', '南韩', '大韩民国'],
  ),
  _RegionGroup(
    id: 'canada',
    zh: '加拿大',
    en: 'Canada',
    aliases: <String>['CA'],
  ),
  _RegionGroup(
    id: 'australia',
    zh: '澳大利亚',
    en: 'Australia',
    aliases: <String>['AU', '澳洲'],
  ),
  _RegionGroup(
    id: 'netherlands',
    zh: '荷兰',
    en: 'Netherlands',
    aliases: <String>['The Netherlands', 'Holland', 'NL'],
  ),
  _RegionGroup(
    id: 'switzerland',
    zh: '瑞士',
    en: 'Switzerland',
    aliases: <String>['CH'],
  ),
  _RegionGroup(
    id: 'germany',
    zh: '德国',
    en: 'Germany',
    aliases: <String>['DE'],
  ),
  _RegionGroup(
    id: 'belgium',
    zh: '比利时',
    en: 'Belgium',
    aliases: <String>['BE'],
  ),
  _RegionGroup(
    id: 'italy',
    zh: '意大利',
    en: 'Italy',
    aliases: <String>['IT'],
  ),
  _RegionGroup(
    id: 'france',
    zh: '法国',
    en: 'France',
    aliases: <String>['FR'],
  ),
  _RegionGroup(
    id: 'spain',
    zh: '西班牙',
    en: 'Spain',
    aliases: <String>['ES'],
  ),
  _RegionGroup(
    id: 'portugal',
    zh: '葡萄牙',
    en: 'Portugal',
    aliases: <String>['PT'],
  ),
  _RegionGroup(
    id: 'greece',
    zh: '希腊',
    en: 'Greece',
    aliases: <String>['GR'],
  ),
  _RegionGroup(
    id: 'sweden',
    zh: '瑞典',
    en: 'Sweden',
    aliases: <String>['SE'],
  ),
  _RegionGroup(
    id: 'denmark',
    zh: '丹麦',
    en: 'Denmark',
    aliases: <String>['DK'],
  ),
  _RegionGroup(
    id: 'norway',
    zh: '挪威',
    en: 'Norway',
    aliases: <String>['NO'],
  ),
  _RegionGroup(
    id: 'finland',
    zh: '芬兰',
    en: 'Finland',
    aliases: <String>['FI'],
  ),
  _RegionGroup(
    id: 'austria',
    zh: '奥地利',
    en: 'Austria',
    aliases: <String>['AT'],
  ),
  _RegionGroup(
    id: 'poland',
    zh: '波兰',
    en: 'Poland',
    aliases: <String>['PL'],
  ),
  _RegionGroup(
    id: 'czech',
    zh: '捷克',
    en: 'Czechia',
    aliases: <String>['Czech Republic', 'CZ'],
  ),
  _RegionGroup(
    id: 'hungary',
    zh: '匈牙利',
    en: 'Hungary',
    aliases: <String>['HU'],
  ),
  _RegionGroup(
    id: 'romania',
    zh: '罗马尼亚',
    en: 'Romania',
    aliases: <String>['RO'],
  ),
  _RegionGroup(
    id: 'russia',
    zh: '俄罗斯',
    en: 'Russia',
    aliases: <String>['Russian Federation', 'RU', '俄国'],
  ),
  _RegionGroup(
    id: 'ukraine',
    zh: '乌克兰',
    en: 'Ukraine',
    aliases: <String>['UA'],
  ),
  _RegionGroup(
    id: 'turkey',
    zh: '土耳其',
    en: 'Turkey',
    aliases: <String>['Türkiye', 'TR'],
  ),
  _RegionGroup(
    id: 'israel',
    zh: '以色列',
    en: 'Israel',
    aliases: <String>['IL'],
  ),
  _RegionGroup(
    id: 'iran',
    zh: '伊朗',
    en: 'Iran',
    aliases: <String>['IR'],
  ),
  _RegionGroup(
    id: 'india',
    zh: '印度',
    en: 'India',
    aliases: <String>['IN'],
  ),
  _RegionGroup(
    id: 'thailand',
    zh: '泰国',
    en: 'Thailand',
    aliases: <String>['TH'],
  ),
  _RegionGroup(
    id: 'singapore',
    zh: '新加坡',
    en: 'Singapore',
    aliases: <String>['SG', '星加坡'],
  ),
  _RegionGroup(
    id: 'malaysia',
    zh: '马来西亚',
    en: 'Malaysia',
    aliases: <String>['MY'],
  ),
  _RegionGroup(
    id: 'indonesia',
    zh: '印度尼西亚',
    en: 'Indonesia',
    aliases: <String>['ID', '印尼'],
  ),
  _RegionGroup(
    id: 'philippines',
    zh: '菲律宾',
    en: 'Philippines',
    aliases: <String>['PH'],
  ),
  _RegionGroup(
    id: 'vietnam',
    zh: '越南',
    en: 'Vietnam',
    aliases: <String>['VN'],
  ),
  _RegionGroup(
    id: 'newzealand',
    zh: '新西兰',
    en: 'New Zealand',
    aliases: <String>['NZ'],
  ),
  _RegionGroup(
    id: 'ireland',
    zh: '爱尔兰',
    en: 'Ireland',
    aliases: <String>['IE'],
  ),
  _RegionGroup(
    id: 'brazil',
    zh: '巴西',
    en: 'Brazil',
    aliases: <String>['BR'],
  ),
  _RegionGroup(
    id: 'argentina',
    zh: '阿根廷',
    en: 'Argentina',
    aliases: <String>['AR'],
  ),
  _RegionGroup(
    id: 'mexico',
    zh: '墨西哥',
    en: 'Mexico',
    aliases: <String>['MX'],
  ),
  _RegionGroup(
    id: 'chile',
    zh: '智利',
    en: 'Chile',
    aliases: <String>['CL'],
  ),
  _RegionGroup(
    id: 'colombia',
    zh: '哥伦比亚',
    en: 'Colombia',
    aliases: <String>['CO'],
  ),
  _RegionGroup(
    id: 'peru',
    zh: '秘鲁',
    en: 'Peru',
    aliases: <String>['PE'],
  ),
  _RegionGroup(
    id: 'egypt',
    zh: '埃及',
    en: 'Egypt',
    aliases: <String>['EG'],
  ),
  _RegionGroup(
    id: 'southafrica',
    zh: '南非',
    en: 'South Africa',
    aliases: <String>['ZA'],
  ),
];

/// 归一化：忽略大小写、空白、常见连接符，让 "United States of America"
/// 和 `united states of america` 落到同一格。
String _norm(String s) => s
    .trim()
    .toLowerCase()
    .replaceAll(RegExp(r'[\s\u00a0·・._\-]+'), '')
    .replaceAll(RegExp(r'[,，、/;；]+'), '');

final Map<String, _RegionGroup> _byNorm = <String, _RegionGroup>{
  for (final g in _kGroups)
    for (final f in g.forms) _norm(f): g,
};

/// 归一化后的分组 id；表里没有的返回 `null`（调用方按原值处理）。
String? regionGroupId(String raw) => _byNorm[_norm(raw)]?.id;

/// 按界面语言取显示名；表里没有的值**原样返回**（其它语言保持其它语言）。
String regionLabel(String raw, [String? locale]) {
  final loc = locale ?? I18n.instance.locale;
  final g = _byNorm[_norm(raw)];
  if (g == null) return raw;
  return loc.startsWith('zh') ? g.zh : g.en;
}

/// 一组地区要提交给服务端的写法。
///
/// 只交「样本里真实出现的值 + 该组的中英主写法」，不交整张别名表：
/// `csvList` 按逗号拆分且最多 40 个，长尾别名既占名额又容易踩逗号。
/// 服务端 `likeJson` 是 OR，多传的写法匹配不到也只是无害的空条件。
List<String> regionQueryValues(Iterable<String> raws) {
  final out = <String>{};
  bool usable(String v) =>
      v.isNotEmpty && !v.contains(',') && !v.contains('，');
  for (final raw in raws) {
    final v = raw.trim();
    if (usable(v)) out.add(v);
    final g = _byNorm[_norm(raw)];
    if (g == null) continue;
    for (final f in <String>[g.zh, g.en]) {
      if (usable(f)) out.add(f);
    }
  }
  return out.toList(growable: false);
}

/// 筛选面板的一个地区选项。
class RegionOption {
  const RegionOption({
    required this.key,
    required this.label,
    required this.values,
  });

  /// 分组 id（未知值时是 `raw:<归一化值>`）
  final String key;

  /// 已按当前语言本地化的显示名
  final String label;

  /// 这一组在样本里真实出现的原始写法
  final List<String> values;

  List<String> get queryValues => regionQueryValues(values);
}

/// 把一堆原始地区值收敛成「一个地区一项」的选项列表，按显示名排序。
List<RegionOption> groupRegions(Iterable<String> raws, [String? locale]) {
  final buckets = <String, List<String>>{};
  for (final raw in raws) {
    final v = raw.trim();
    if (v.isEmpty) continue;
    final key = regionGroupId(v) ?? 'raw:${_norm(v)}';
    (buckets[key] ??= <String>[]).add(v);
  }
  final out = <RegionOption>[
    for (final entry in buckets.entries)
      RegionOption(
        key: entry.key,
        label: regionLabel(entry.value.first, locale),
        values: entry.value.toSet().toList(growable: false),
      ),
  ];
  out.sort((a, b) => a.label.compareTo(b.label));
  return out;
}
