import 'package:nas_core/nas_core.dart';

/// 服务端「数据值 / 错误文本」→ 界面显示名的统一收口。
///
/// 背景：主链 `tr()` 覆盖的是**固定 UI 文案**，但界面上还有大量**服务端返回的
/// 值**会直接进 `Text` —— 有限枚举（`none`/`Released`/`info`…）和失败提示
/// （`source offline`/`bad credentials`…）。中文界面下这些就是漏出来的英文。
///
/// 约定：
///   - 只做「显示」转换，**不改变存储值、不改变提交给服务端的查询值**；
///   - 有限枚举按当前语言出中文或英文；
///   - 表里没有的值原样保留（专有名词、技术缩写、用户自定义内容都不硬翻）；
///   - 未知状态给中文兜底，不再把英文原值直接吐给用户。
///
/// 纯 Dart（只依赖 nas_core），方便独立验证，也能被 nas_ui 之外的层复用。
bool get _zh => I18n.instance.locale.startsWith('zh');

String _pick(String raw, String zh) => _zh ? zh : raw;

// ---------------------------------------------------------------- 有限枚举

/// 详情页「来源」：`nfo_source` 的 `none` / 空值不该显示成英文。
/// `tmdb` / `jav` 等是数据源专名，按约定保留。
String nfoSourceLabel(String? raw) {
  final v = (raw ?? '').trim();
  if (v.isEmpty || v.toLowerCase() == 'none' || v.toLowerCase() == 'null') {
    return _pick('none', '无');
  }
  return v;
}

String mediaTypeLabel(String raw) => switch (raw.trim().toLowerCase()) {
      'movie' => _pick(raw, '电影'),
      'tv' || 'show' || 'series' => _pick(raw, '剧集'),
      'image' || 'photo' => _pick(raw, '图片'),
      'music' || 'audio' => _pick(raw, '音乐'),
      _ => raw,
    };

/// TMDB 影视状态（官方取值固定）。
String tmdbStatusLabel(String raw) => switch (raw.trim().toLowerCase()) {
      'released' => _pick(raw, '已上映'),
      'returning series' => _pick(raw, '连载中'),
      'ended' => _pick(raw, '已完结'),
      'canceled' || 'cancelled' => _pick(raw, '已取消'),
      'in production' => _pick(raw, '制作中'),
      'planned' => _pick(raw, '筹备中'),
      'pilot' => _pick(raw, '试播'),
      _ => raw,
    };

String subscriptionStatusLabel(String raw) =>
    switch (raw.trim().toLowerCase()) {
      'active' || 'enabled' || 'running' => _pick(raw, '已启用'),
      'paused' || 'inactive' || 'disabled' => _pick(raw, '已停用'),
      'error' || 'failed' => _pick(raw, '出错'),
      'completed' || 'done' => _pick(raw, '已完成'),
      _ => raw,
    };

/// 设置页日志区显示的级别标签（原本是 `INFO.toUpperCase()`）。
String logLevelLabel(String raw) => switch (raw.trim().toLowerCase()) {
      'debug' || 'trace' => _pick(raw, '调试'),
      'info' => _pick(raw, '信息'),
      'warn' || 'warning' => _pick(raw, '警告'),
      'error' => _pick(raw, '错误'),
      'fatal' => _pick(raw, '致命'),
      _ => raw,
    };

String cleanupKindLabel(String raw) => switch (raw.trim().toLowerCase()) {
      'duplicate' => _pick(raw, '重复照片'),
      'similar' => _pick(raw, '相似照片'),
      _ => raw,
    };

/// 状态映射函数遇到未知值时的中文兜底。
String unknownStatusLabel() => _pick('unknown', '未知状态');

// ---------------------------------------------------------------- 错误文本

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
  'totp code required': '请输入两步验证码',
  'invalid code': '验证码无效',
  'username exists': '用户名已存在',
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
  'not found': '未找到',
  'forbidden': '没有权限',
  'unauthorized': '登录已失效，请重新登录',
  'internal server error': '服务内部错误',
  'network unreachable': '网络不可达',
  'connection refused': '连接被拒绝',
  'timed out': '请求超时',
  'timeout': '请求超时',
};

/// 把异常 / 服务端 message 转成给用户看的文本。
///
/// 先剥掉 Dart 的异常包装（`ApiError(400 X): xxx`、`Bad state: xxx`），
/// 再按短语表转中文；没命中的原样返回 —— 宁可留一个英文专名，
/// 也不要把错误信息吞掉或翻错。英文界面直接返回原文。
String errorMessageOf(Object? error) {
  if (error == null) return '';
  var text = error.toString().trim();
  text = text.replaceFirst(RegExp(r'^ApiError\([^)]*\):\s*'), '');
  text = text.replaceFirst(
    RegExp(r'^(Bad state|StateError|Exception|FormatException|SocketException):\s*'),
    '',
  );
  if (!_zh || text.isEmpty) return text;
  final lower = text.toLowerCase();
  final exact = kErrorPhrases[lower];
  if (exact != null) return exact;
  for (final entry in kErrorPhrases.entries) {
    if (lower.contains(entry.key)) return entry.value;
  }
  return text;
}
