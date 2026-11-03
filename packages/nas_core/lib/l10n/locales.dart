// AUTO-GENERATED. DO NOT EDIT.
// source: contracts/locales.json + contracts/messages/*.json
// regenerate: npm run gen:locales

/// 语言清单（`enabled` 由翻译覆盖率派生，阈值 95%）。
class LocaleInfo {
  const LocaleInfo({
    required this.code,
    required this.native,
    required this.enabled,
    required this.coverage,
  });

  final String code;
  final String native;

  /// 是否对外展示（覆盖率达标）
  final bool enabled;

  /// 已译键占比，0~1
  final double coverage;
}

const List<LocaleInfo> kLocales = <LocaleInfo>[
  LocaleInfo(code: 'zh-CN', native: '简体中文', enabled: true, coverage: 1.0000),
  LocaleInfo(code: 'en-US', native: 'English', enabled: true, coverage: 1.0000),
  LocaleInfo(code: 'ja-JP', native: '日本語', enabled: false, coverage: 0.0000),
  LocaleInfo(code: 'ko-KR', native: '한국어', enabled: false, coverage: 0.0000),
  LocaleInfo(code: 'fr-FR', native: 'Français', enabled: false, coverage: 0.0000),
  LocaleInfo(code: 'de-DE', native: 'Deutsch', enabled: false, coverage: 0.0000),
  LocaleInfo(code: 'es-ES', native: 'Español', enabled: false, coverage: 0.0000),
  LocaleInfo(code: 'pt-BR', native: 'Português', enabled: false, coverage: 0.0000),
  LocaleInfo(code: 'ru-RU', native: 'Русский', enabled: false, coverage: 0.0000),
  LocaleInfo(code: 'ar-SA', native: 'العربية', enabled: false, coverage: 0.0000),
  LocaleInfo(code: 'th-TH', native: 'ไทย', enabled: false, coverage: 0.0000),
  LocaleInfo(code: 'vi-VN', native: 'Tiếng Việt', enabled: false, coverage: 0.0000),
  LocaleInfo(code: 'id-ID', native: 'Bahasa Indonesia', enabled: false, coverage: 0.0000),
];

/// 语言选择只展示已翻译完成的语言（避免切过去整页回退中文）。
List<LocaleInfo> get enabledLocales =>
    kLocales.where((l) => l.enabled).toList(growable: false);
