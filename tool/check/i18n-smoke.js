#!/usr/bin/env node
/**
 * i18n 与 AppRegistry 一致性验收（SP1-02 / SP1-03，不需要 Dart SDK）。
 * 校验项：
 *  1. 生成物幂等（apps / i18n 的 --check 均通过）
 *  2. 13 个语言文件全部存在，且键集合与契约完全一致（缺键 0）
 *  3. keys.dart 覆盖全部契约键
 *  4. apps.json 里每个 nameKey 都在 i18n 契约中
 *  5. app_registry.dart 覆盖全部 App 与全部端
 *
 * 用法：node tool/check/i18n-smoke.js
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const root = path.join(__dirname, '..', '..');
const contracts = path.join(root, 'contracts');
const l10nDir = path.join(root, 'packages', 'nas_core', 'lib', 'l10n');
const appsDart = path.join(root, 'packages', 'nas_core', 'lib', 'app_registry.dart');

const i18n = JSON.parse(fs.readFileSync(path.join(contracts, 'i18n.json'), 'utf-8'));
const apps = JSON.parse(fs.readFileSync(path.join(contracts, 'apps.json'), 'utf-8'));
const locales = JSON.parse(fs.readFileSync(path.join(contracts, 'locales.json'), 'utf-8'));

const keys = Object.keys(i18n.keys || {}).sort();
const codes = locales.filter((l) => l.enabled !== false).map((l) => l.code);

const results = [];
const check = (name, ok, detail) => results.push({ name, ok, detail: detail || '' });

/** 1. 幂等 */
const appsCheck = spawnSync(process.execPath, [path.join(root, 'tool', 'gen-apps.js'), '--check'], {
  cwd: root,
  encoding: 'utf-8',
});
const i18nCheck = spawnSync(process.execPath, [path.join(root, 'tool', 'gen-i18n.js'), '--check'], {
  cwd: root,
  encoding: 'utf-8',
});
check(
  'generators_idempotent',
  appsCheck.status === 0 && i18nCheck.status === 0,
  `${(appsCheck.stdout || '').trim()} | ${(i18nCheck.stdout || '').trim()}`,
);

/** 2. 每语言键集合一致 */
const mismatched = [];
for (const code of codes) {
  const file = path.join(l10nDir, `${code}.json`);
  if (!fs.existsSync(file)) {
    mismatched.push(`${code}:missing-file`);
    continue;
  }
  const msg = JSON.parse(fs.readFileSync(file, 'utf-8'));
  const got = Object.keys(msg.messages || {}).sort();
  const missing = keys.filter((k) => !got.includes(k));
  const extra = got.filter((k) => !keys.includes(k));
  if (missing.length || extra.length) {
    mismatched.push(`${code}: -${missing.length} +${extra.length}`);
  }
}
check(
  'locale_keys_complete',
  mismatched.length === 0 && codes.length >= 2,
  mismatched.length ? mismatched.join(', ') : `${codes.length} locales x ${keys.length} keys`,
);

/** 3. keys.dart 覆盖 */
const keysDart = fs.readFileSync(path.join(l10nDir, 'keys.dart'), 'utf-8');
const missingInDart = keys.filter((k) => !keysDart.includes(`= '${k}';`));
check(
  'keys_dart_complete',
  missingInDart.length === 0,
  missingInDart.length ? 'missing=' + missingInDart.join(',') : `${keys.length} constants`,
);

/** 4. App 名称键存在 */
const missingNameKeys = apps.apps.map((a) => a.nameKey).filter((k) => !keys.includes(k));
check(
  'app_name_keys_exist',
  missingNameKeys.length === 0,
  missingNameKeys.length ? 'missing=' + missingNameKeys.join(',') : `${apps.apps.length} apps`,
);

/** 5. app_registry.dart 覆盖 */
const appsDartSrc = fs.readFileSync(appsDart, 'utf-8');
const missingApps = apps.apps.filter((a) => !appsDartSrc.includes(`id: '${a.id}'`));
const missingEndpoints = apps.endpoints.filter(
  (e) => !new RegExp(`^  ${e},`, 'm').test(appsDartSrc),
);
check(
  'app_registry_complete',
  missingApps.length === 0 && missingEndpoints.length === 0,
  `apps=${apps.apps.length} endpoints=${apps.endpoints.length}` +
    (missingApps.length ? ' missing_app=' + missingApps.map((a) => a.id).join(',') : '') +
    (missingEndpoints.length ? ' missing_ep=' + missingEndpoints.join(',') : ''),
);

/** 6. 语言清单：总 13 个，对外启用的是覆盖率达标的（至少 zh-CN / en-US） */
check('locales_count', locales.length === 13, 'total=' + locales.length);
check(
  'locales_enabled',
  codes.includes('zh-CN') && codes.includes('en-US') && codes.length >= 2,
  'enabled=' + codes.join(','),
);

let failed = 0;
for (const x of results) {
  console.log(`${x.ok ? '[OK]  ' : '[FAIL]'} ${x.name.padEnd(24)} ${x.detail}`);
  if (!x.ok) failed++;
}
console.log(`[summary] ${results.length - failed}/${results.length} passed`);
process.exit(failed ? 1 : 0);
