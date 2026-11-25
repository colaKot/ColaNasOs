import 'i18n.dart';

/// 服务端「错误文本」→ 界面显示名的统一收口（各端共用）。
///
/// 背景：服务端大量接口的 `message` 是英文（`user not found`、
/// `bad credentials`…），客户端一些地方会把异常原文直接塞进提示条，
/// 导致中文界面下冒出英文。这里负责把已知短语换成中文，并把没有
/// 对应文案的技术异常收成一句本地化的兜底提示，避免直接把英文抛给用户。
///
/// 约定：
///   - 只做「显示」转换，不改变存储值、不改变提交给服务端的值；
///   - 英文界面直接返回原文；
///   - 表里没有、但明显是技术异常的文本，按当前语言给统一兜底；
///   - 普通业务文本（含中文、用户自定义内容）原样返回。
bool get _zh => I18n.instance.locale.startsWith('zh');

final RegExp _cjk = RegExp(r'[\u4e00-\u9fff]');

/// 服务端常见的英文 `message` / `error` / `reason`（小写 → 中文）。
/// 键用小写，匹配时先精确、再包含；值里保留 TMDB / Transmission 等专名。
const Map<String, String> kErrorPhrases = <String, String>{
  'source offline': '来源离线，暂时无法播放',
  'source file missing': '源文件不存在',
  'transmission url not configured': '未配置 Transmission 地址',
  'transmission not configured': '未配置 Transmission',
  'torrent url required': '缺少种子链接',
  'no candidate': '没有符合条件的结果',
  'bad credentials': '账号或密码错误',
  'invalid credentials': '账号或密码错误',
  'username/password required': '请输入用户名和密码',
  'totp code required': '请输入两步验证码',
  'bad totp code': '两步验证码错误',
  'invalid code': '验证码无效',
  'username exists': '用户名已存在',
  'username already exists': '用户名已存在',
  'user not found': '用户不存在',
  'missing user': '用户信息缺失',
  'account disabled': '账号已被禁用',
  'already initialized': '系统已完成初始化',
  'id required': '缺少 ID',
  'name required': '缺少名称',
  'scopes required': '缺少权限范围',
  'scopes must not be empty': '权限范围不能为空',
  'token not found': '令牌不存在',
  'cannot delete yourself': '不能删除当前登录账号',
  'last administrator cannot be deleted': '不能删除最后一个管理员',
  'call setup first': '请先完成设置',
  'invalid ip or cidr': 'IP 或网段格式不正确',
  'ip blocked': 'IP 已被封禁',
  'indexer unavailable': '索引服务不可用',
  'q required': '请输入搜索关键词',
  'unknown voice': '未知音色',
  'preview not generated': '预览未生成',
  'ai_unavailable': 'AI 服务不可用',
  'quality_unknown': '画质未知',
  'quality_too_low': '画质低于要求',
  'hdr_too_low': 'HDR 规格低于要求',
  'audio_missing': '缺少所需音轨',
  'size_exceeded': '文件体积超出限制',
  'seeders_too_low': '做种数不足',
  'season_mismatch': '季数不匹配',
  'title_mismatch': '标题不匹配',
  'excluded': '已被排除规则过滤',
  'permission denied': '没有权限',
  'file not found': '文件不存在',
  'no such file or directory': '文件或目录不存在',
  'bad request': '请求参数有误',
  'not found': '未找到',
  'forbidden': '没有权限',
  'unauthorized': '登录已失效，请重新登录',
  'internal server error': '服务内部错误',
  'internal error': '服务内部错误',
  'network unreachable': '网络不可达',
  'connection refused': '连接被拒绝',
  'connection reset': '连接被重置',
  'timed out': '请求超时',
  'timeout': '请求超时',
};

/// 判断文本里是否包含 Dart / 网络异常包装，避免误改普通业务提示。
final RegExp _technicalMarker = RegExp(
  r'ApiError\(|Exception|Error:|Bad state|SocketException|ClientException|DioException|TimeoutException|HTTP \d{3}',
);

final RegExp _wrapper = RegExp(r'ApiError\([^)]*\):\s*');
final RegExp _prefix = RegExp(
  r'^(Bad state|StateError|Exception|FormatException|SocketException|ClientException|DioException|TimeoutException):\s*',
);
final RegExp _chinesePrefix = RegExp(r'^(.*[:：]\s*)(.+)$');

/// 把异常 / 服务端 message 转成给用户看的文本。
///
/// 先剥掉 Dart 的异常包装（`ApiError(400 X): xxx`、`Bad state: xxx`），
/// 再按短语表转中文；仍然无法识别的技术异常按当前语言给统一兜底。
String localizeErrorText(Object? error) {
  if (error == null) return '';
  var text = error.toString().trim();
  if (text.isEmpty) return text;

  final technical = _technicalMarker.hasMatch(text);
  text = text.replaceAll(_wrapper, '').replaceAll(_prefix, '');
  if (!_zh || text.isEmpty) return text;

  if (_cjk.hasMatch(text)) {
    // 已有中文前缀（如「保存失败：」）时只处理冒号后的英文细节，避免改坏前缀。
    final match = _chinesePrefix.firstMatch(text);
    if (match == null) return text;
    final detail = _localizeDetail(match.group(2)!, technical: technical);
    return detail == null ? text : '${match.group(1)}$detail';
  }
  return _localizeDetail(text, technical: technical) ?? text;
}

/// 返回本地化后的细节；无法识别时返回 null，交给调用方保留原文。
String? _localizeDetail(String raw, {required bool technical}) {
  final text = raw.trim();
  if (text.isEmpty) return null;

  final lower = text.toLowerCase();
  final exact = kErrorPhrases[lower];
  if (exact != null) return exact;

  var out = text;
  for (final entry in kErrorPhrases.entries) {
    out = out.replaceAll(
      RegExp(RegExp.escape(entry.key), caseSensitive: false),
      entry.value,
    );
  }
  if (out != text) return out;

  if (technical) return I18n.instance.tr('common.error');
  return null;
}
