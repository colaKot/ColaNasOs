/// 播放器「播放列表」的同组文件判定。
///
/// 两种来源：
/// 1. 剧集：服务端按 `series` 直接给同系列的全部集，这里不管。
/// 2. 电影分卷：同目录下共用同一前缀的文件，例如
///    `abd-121-cd1` / `abd-121-cd2` / `abd-121-cd3`，
///    或 `abd-121-1` / `abd-121-2`。
///
/// 只做字符串判定，不碰 IO / 网络，方便用单测钉住命名规则。
library;

/// 末尾的分卷序号：最多 4 位（够覆盖 cd9999 / 第 9999 集）。
final RegExp _tailNumber = RegExp(r'(\d{1,4})$');

/// 末尾的「分隔符链」：空格 / 点 / 下划线 / 连字符。
final RegExp _sepTail = RegExp(r'[\s._\-]+$');

/// 中文分卷写法：`第 1 部` / `第 2 集`，前面可能带分隔符。
final RegExp _cnVolume = RegExp(r'第\s*\d{1,4}\s*[集部篇回]$');

/// 取文件名（不含扩展名），兼容 Windows 反斜杠路径。
String relatedBasename(String path) {
  final p = path.replaceAll('\\', '/');
  final name = p.contains('/') ? p.substring(p.lastIndexOf('/') + 1) : p;
  final dot = name.lastIndexOf('.');
  return dot > 0 ? name.substring(0, dot) : name;
}

/// 取所在目录（不带尾斜杠）；根目录文件返回空串。
String relatedDir(String path) {
  final p = path.replaceAll('\\', '/');
  final i = p.lastIndexOf('/');
  return i > 0 ? p.substring(0, i) : '';
}

/// 从文件名推出同组前缀；认不出分卷序号就返回 null（此时不该显示播放列表）。
///
/// `abd-121-cd1` → `abd-121-cd`（保留 `cd` 标记）
/// `abd-121-1`   → `abd-121-`（保留分隔符，避免把 `abd-1210-1` 也拉进来）
/// `Movie.Part2` → `movie.part`
/// `Movie 第 2 部` → `movie 第 ` 之后交给 [_tailNumber] 处理
///
/// 前缀去掉分隔符后至少要剩 3 个字符 —— `A-1` / `1` 这种太短，
/// 会把整个目录都匹配进来。
String? relatedPrefix(String basename) {
  String base = basename.trim();
  // 「第 N 部 / 集」：先把中文数字换成普通数字，让后面的规则复用
  base = base.replaceAllMapped(
    RegExp(r'第\s*(\d{1,4})\s*([集部篇回])$'),
    (m) => '${m[1]}',
  );
  final m = _tailNumber.firstMatch(base);
  if (m == null) return null;
  final stem = base.substring(0, m.start);
  if (stem.isEmpty) return null;
  final core = _sepTail.hasMatch(stem) ? stem.replaceFirst(_sepTail, '') : stem;
  if (core.length < 3) return null;
  return stem.toLowerCase();
}

/// 候选文件是否属于同一组。
///
/// 除了前缀匹配，还要求候选本身也以数字结尾：同目录下常有
/// `xxx-cd1-花絮`、`xxx-cd1-预告` 之类的同名开头视频，不该混进正片列表。
bool relatedMatches(String prefix, String candidateBasename) {
  final c = candidateBasename.trim().toLowerCase();
  if (!c.startsWith(prefix)) return false;
  if (!_tailNumber.hasMatch(c)) {
    // 中文「第 N 部」写法
    return _cnVolume.hasMatch(candidateBasename.trim());
  }
  return true;
}

/// 取分卷序号，用于自然排序（cd2 排在 cd10 前面）。
int? relatedOrdinal(String basename) {
  final b = basename.trim();
  final m = _tailNumber.firstMatch(b);
  if (m != null) return int.tryParse(m[1]!);
  final cn = RegExp(r'第\s*(\d{1,4})\s*[集部篇回]$').firstMatch(b);
  return cn == null ? null : int.tryParse(cn[1]!);
}

/// 自然序：先按分卷号，再按文件名（大小写不敏感）。
int compareRelatedNames(String a, String b) {
  final na = relatedOrdinal(a);
  final nb = relatedOrdinal(b);
  if (na != null && nb != null && na != nb) return na.compareTo(nb);
  return a.toLowerCase().compareTo(b.toLowerCase());
}
