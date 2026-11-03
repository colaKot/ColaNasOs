#!/usr/bin/env node
/**
 * 语言发布开关（i18n 假开关收口）：`enabled` 不再手写，而是**由翻译覆盖率派生**。
 *
 *   覆盖率 = 已译键数 / 契约键总数（`contracts/messages/<code>.json` 中非空值）
 *   enabled = 覆盖率 >= 95%
 *
 * 派生结果同时写入：
 *   - `contracts/locales.json` 的 `enabled`
 *   - `packages/nas_core/lib/l10n/locales.dart`（客户端语言选择只展示 enabled）
 *
 * 用法：
 *   node tool/gen-locales.js          写入
 *   node tool/gen-locales.js --check  校验（verify 用）
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..');
const i18nPath = path.join(root, 'contracts', 'i18n.json');
const localesPath = path.join(root, 'contracts', 'locales.json');
const outPath = path.join(root, 'packages', 'nas_core', 'lib', 'l10n', 'locales.dart');
const checkOnly = process.argv.includes('--check');

/** 语言可用阈值：低于这个比例不对外展示（回退中文会显得"假支持"） */
const THRESHOLD = 0.95;

const i18n = JSON.parse(fs.readFileSync(i18nPath, 'utf-8'));
const keys = Object.keys(i18n.keys || {});
const locales = JSON.parse(fs.readFileSync(localesPath, 'utf-8'));
const suite = [];

function translatedCount(code) {
  const file = path.join(root, 'contracts', 'messages', `${code}.json`);
  if (!fs.existsSync(file)) return 0;
  const doc = JSON.parse(fs.readFileSync(file, 'utf-8'));
  const messages = doc.messages || doc;
  let n = 0;
  for (const key of keys) {
    const value = messages[key];
    if (typeof value === 'string' && value.trim() !== '') n += 1;
  }
  return n;
}

for (const locale of locales) {
  const done = translatedCount(locale.code);
  const coverage = keys.length === 0 ? 0 : done / keys.length;
  const enabled = coverage >= THRESHOLD;
  suite.push({ ...locale, done, coverage, enabled });
}

function dartString(s) {
  return `'${String(s).replace(/\\/g, '\\\\').replace(/'/g, "\\'")}'`;
}

function genDart() {
  const lines = [
    '// AUTO-GENERATED. DO NOT EDIT.',
    '// source: contracts/locales.json + contracts/messages/*.json',
    '// regenerate: npm run gen:locales',
    '',
    '/// 语言清单（`enabled` 由翻译覆盖率派生，阈值 95%）。',
    'class LocaleInfo {',
    '  const LocaleInfo({',
    '    required this.code,',
    '    required this.native,',
    '    required this.enabled,',
    '    required this.coverage,',
    '  });',
    '',
    '  final String code;',
    '  final String native;',
    '',
    '  /// 是否对外展示（覆盖率达标）',
    '  final bool enabled;',
    '',
    '  /// 已译键占比，0~1',
    '  final double coverage;',
    '}',
    '',
    'const List<LocaleInfo> kLocales = <LocaleInfo>[',
  ];
  for (const l of suite) {
    lines.push(
      '  LocaleInfo(' +
        `code: ${dartString(l.code)}, native: ${dartString(l.native)}, ` +
        `enabled: ${l.enabled ? 'true' : 'false'}, coverage: ${l.coverage.toFixed(4)}),`,
    );
  }
  lines.push(
    '];',
    '',
    '/// 语言选择只展示已翻译完成的语言（避免切过去整页回退中文）。',
    'List<LocaleInfo> get enabledLocales =>',
    '    kLocales.where((l) => l.enabled).toList(growable: false);',
    '',
  );
  return lines.join('\n');
}

const nextLocales = suite.map((l) => ({ ...l, done: undefined, coverage: undefined, enabled: l.enabled }));
for (const l of nextLocales) {
  delete l.done;
  delete l.coverage;
}
const content = JSON.stringify(nextLocales, null, 2) + '\n';
const dart = genDart();
const prevLocales = fs.readFileSync(localesPath, 'utf-8');
const prevDart = fs.existsSync(outPath) ? fs.readFileSync(outPath, 'utf-8') : '';

for (const l of suite) {
  const pct = (l.coverage * 100).toFixed(1);
  console.log(`${l.enabled ? '[on ]' : '[off]'} ${l.code.padEnd(6)} ${pct.padStart(6)}%  ${l.done}/${keys.length}`);
}

if (checkOnly) {
  const problems = [];
  if (prevLocales !== content) problems.push('contracts/locales.json 的 enabled 与覆盖率不一致');
  if (prevDart !== dart) problems.push('packages/nas_core/lib/l10n/locales.dart 已过期');
  if (problems.length) {
    console.error(`[gen:locales.check] ${problems.join('；')}；请运行 npm run gen:locales`);
    process.exit(1);
  }
  const on = suite.filter((l) => l.enabled).map((l) => l.code);
  console.log(`[gen:locales.check] ok, enabled=${on.join(',')}, threshold=${THRESHOLD * 100}%`);
} else {
  fs.writeFileSync(localesPath, content, 'utf-8');
  fs.mkdirSync(path.dirname(outPath), { recursive: true });
  fs.writeFileSync(outPath, dart, 'utf-8');
  console.log(`[gen:locales] wrote locales.json + ${path.relative(root, outPath)}`);
}