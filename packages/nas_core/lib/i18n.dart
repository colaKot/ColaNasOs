import 'dart:async';

/// 语言包加载器：由 app 注入（桌面/移动用 `rootBundle` 读 assets，测试直接给 Map）。
typedef LocaleLoader = Future<Map<String, String>> Function(String locale);

/// 运行时 i18n（契约见 `contracts/i18n.json`，文案在 `contracts/messages/<locale>.json`）。
///
/// 回退链：**当前语言 → zh-CN → 键本身**。
/// 这样 13 个语言包里没翻译的键不会显示成空白，也不会抛错；
/// `tool/i18n-scan.js` 可以列出「还有多少键没翻译 / 多少处 UI 文案没接线」。
class I18n {
  I18n._();

  static final I18n instance = I18n._();

  static const String fallbackLocale = 'zh-CN';

  String _locale = fallbackLocale;
  Map<String, String> _current = const {};
  Map<String, String> _fallback = const {};
  LocaleLoader? _loader;

  /// 语言切换后自增，宿主（MaterialApp）监听它来重建
  final ValueNotifierLike revision = ValueNotifierLike();

  String get locale => _locale;

  bool get isConfigured => _loader != null;

  void configure(LocaleLoader loader) => _loader = loader;

  /// 加载语言包；同一 locale 重复调用是幂等的
  Future<void> load(String locale) async {
    final loader = _loader;
    if (loader == null) {
      _locale = locale;
      revision.bump();
      return;
    }
    if (_fallback.isEmpty) _fallback = await loader(fallbackLocale);
    _current = locale == fallbackLocale ? _fallback : await loader(locale);
    _locale = locale;
    revision.bump();
  }

  /// 测试注入（不走 loader）
  void useForTest(String locale, Map<String, String> messages, {Map<String, String>? fallback}) {
    _locale = locale;
    _current = messages;
    _fallback = fallback ?? messages;
  }

  /// 取文案；`args` 支持 `{name}` 占位符
  String tr(String key, [Map<String, Object?>? args]) {
    var text = _current[key];
    if (text == null || text.isEmpty) text = _fallback[key];
    if (text == null || text.isEmpty) text = key;
    if (args == null || args.isEmpty) return text;
    var out = text;
    for (final entry in args.entries) {
      out = out.replaceAll('{${entry.key}}', '${entry.value}');
    }
    return out;
  }
}

/// 极简可监听计数器（避免 nas_core 依赖 flutter 的 ChangeNotifier）
class ValueNotifierLike {
  final List<void Function()> _listeners = [];
  int _value = 0;

  int get value => _value;

  void addListener(void Function() listener) => _listeners.add(listener);

  void removeListener(void Function() listener) => _listeners.remove(listener);

  void bump() {
    _value += 1;
    for (final l in List<void Function()>.of(_listeners)) {
      l();
    }
  }
}