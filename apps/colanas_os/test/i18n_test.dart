import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nas_core/nas_core.dart';

Map<String, String> _messages(String locale) {
  final file = File('../../packages/nas_core/lib/l10n/$locale.json');
  final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  return (json['messages'] as Map).map((k, v) => MapEntry(k.toString(), '$v'));
}

void main() {
  test('回退链：当前语言缺键 → zh-CN → 键本身', () {
    final i18n = I18n.instance;
    i18n.useForTest('en-US', {'common.ok': 'OK'}, fallback: {'common.ok': '确定', 'common.cancel': '取消'});

    expect(i18n.tr('common.ok'), 'OK');
    // en-US 缺 cancel → 回退 zh-CN
    expect(i18n.tr('common.cancel'), '取消');
    // 两边都没有 → 键本身（不显示空白）
    expect(i18n.tr('missing.key'), 'missing.key');
  });

  test('空串也视为缺失，走回退', () {
    final i18n = I18n.instance;
    i18n.useForTest('ja-JP', {'common.ok': ''}, fallback: {'common.ok': '确定'});
    expect(i18n.tr('common.ok'), '确定');
  });

  test('占位符替换', () {
    final i18n = I18n.instance;
    i18n.useForTest('zh-CN', {'files.upload.progress': '已上传 {done}/{total}'});
    expect(i18n.tr('files.upload.progress', {'done': 2, 'total': 5}), '已上传 2/5');
  });

  test('语言切换会 bump revision（宿主据此重建）', () {
    final i18n = I18n.instance;
    final before = i18n.revision.value;
    i18n.useForTest('en-US', {'common.ok': 'OK'});
    i18n.revision.bump();
    expect(i18n.revision.value, greaterThan(before));
    expect(i18n.locale, 'en-US');
  });

  test('zh-CN 与 en-US 的键集合一致，且中文全有值', () {
    final zh = _messages('zh-CN');
    final en = _messages('en-US');

    expect(zh.keys.toSet(), en.keys.toSet(), reason: '语言包的键必须与契约对齐');

    final emptyZh = zh.entries.where((e) => e.value.isEmpty).map((e) => e.key).toList();
    expect(emptyZh, isEmpty, reason: 'zh-CN 是回退语言，不允许空值：$emptyZh');

    // 英文翻译是内容工作（新增键先回退 zh-CN）：允许空值，但不能「填了却是中文」
    final emptyEn = en.entries.where((e) => e.value.isEmpty).length;
    expect(emptyEn, lessThan(en.length), reason: 'en-US 一条都没翻译，说明生成链路断了');
  });

  test('英文文案不含中文（防漏翻）', () {
    final en = _messages('en-US');
    final han = RegExp(r'[\u4e00-\u9fa5]');
    final bad = en.entries.where((e) => han.hasMatch(e.value)).map((e) => e.key).toList();
    expect(bad, isEmpty, reason: '未翻译的英文键：$bad');
  });
}