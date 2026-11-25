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

/// 错误文案收口已下沉到 `nas_core`（各端提示条共用），这里保留原入口。
String errorMessageOf(Object? error) => localizeErrorText(error);
