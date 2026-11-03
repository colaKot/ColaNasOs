#!/usr/bin/env node
/**
 * 鸿蒙端（CL4-01）工程门禁：
 *   1. `apps/colanas_os/ohos` 工程骨架齐全（AppScope / entry / 入口 / 页面 / 资源）
 *   2. bundleName 固定 com.colanas.os（docs/01 §234），不与 water 参考工程混用
 *   3. versionName / versionCode 与 `apps/colanas_os/pubspec.yaml` 同步
 *   4. module.json5 的 mainElement、srcEntry、pages profile、权限声明自洽
 *   5. EntryAbility 继承 flutter_ohos 的 FlutterAbility
 *   6. 报告 flutter_ohos SDK / har 是否就绪（缺 SDK 时**不失败**，只提示无法实测）
 *
 * 用法：node tool/check/ohos-project.js
 */
'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const root = path.join(__dirname, '..', '..');
const appDir = path.join(root, 'apps', 'colanas_os');
const ohosDir = path.join(appDir, 'ohos');
const BUNDLE = 'com.colanas.os';

const results = [];
const check = (name, ok, detail) => results.push({ name, ok, detail: detail || '' });

/** 轻量 JSON5 → JSON（去行注释 / 块注释 / 尾逗号），够读 hvigor 配置。 */
function readJson5(file) {
  let text = fs.readFileSync(file, 'utf-8');
  text = text
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .replace(/(^|[^:])\/\/.*$/gm, '$1')
    .replace(/,\s*([}\]])/g, '$1');
  return JSON.parse(text);
}

function exists(rel) {
  return fs.existsSync(path.join(ohosDir, rel));
}

/** 1. 骨架齐全 */
const REQUIRED = [
  'build-profile.json5',
  'hvigorfile.ts',
  'hvigor/hvigor-config.json5',
  'oh-package.json5',
  'AppScope/app.json5',
  'AppScope/resources/base/element/string.json',
  'AppScope/resources/base/media/app_icon.png',
  'entry/build-profile.json5',
  'entry/hvigorfile.ts',
  'entry/oh-package.json5',
  'entry/src/main/module.json5',
  'entry/src/main/ets/entryability/EntryAbility.ets',
  'entry/src/main/ets/pages/Index.ets',
  'entry/src/main/resources/base/element/string.json',
  'entry/src/main/resources/base/element/color.json',
  'entry/src/main/resources/base/profile/main_pages.json',
  'entry/src/main/resources/base/media/app_icon.png',
];
const missing = REQUIRED.filter((f) => !exists(f));
check('project_files', missing.length === 0, missing.join(','));

/** 2. bundleName */
let appSpec = {};
try {
  appSpec = readJson5(path.join(ohosDir, 'AppScope/app.json5'));
} catch (err) {
  check('bundle_name', false, `AppScope/app.json5 解析失败：${err.message}`);
}
if (appSpec.app) {
  check('bundle_name', appSpec.app.bundleName === BUNDLE, `bundleName=${appSpec.app.bundleName}`);
}

/** 3. 版本与 pubspec 同步 */
const pubspec = fs.readFileSync(path.join(appDir, 'pubspec.yaml'), 'utf-8');
const m = /^version:\s*([0-9]+)\.([0-9]+)\.([0-9]+)(?:\+([0-9]+))?/m.exec(pubspec);
const semver = m ? { major: +m[1], minor: +m[2], patch: +m[3] } : null;
const wantVersionName = semver ? `${semver.major}.${semver.minor}.${semver.patch}` : '';
const wantVersionCode = semver ? semver.major * 1000000 + semver.minor * 1000 + semver.patch : 0;
if (semver && appSpec.app) {
  check(
    'version_sync',
    appSpec.app.versionName === wantVersionName && appSpec.app.versionCode === wantVersionCode,
    `app=${appSpec.app.versionName}/${appSpec.app.versionCode} pubspec=${wantVersionName}/${wantVersionCode}`,
  );
} else {
  check('version_sync', false, '无法读取 pubspec 版本或 AppScope/app.json5');
}

/** 4. module.json5 自洽 */
let mod = {};
try {
  mod = readJson5(path.join(ohosDir, 'entry/src/main/module.json5'));
} catch (err) {
  check('module_entry', false, `module.json5 解析失败：${err.message}`);
}
const moduleSpec = mod.module || {};
const ability = (moduleSpec.abilities || []).find((a) => a.name === moduleSpec.mainElement);
check(
  'module_entry',
  Boolean(ability) && exists(ability.srcEntry.replace('./', 'entry/src/main/')),
  `mainElement=${moduleSpec.mainElement} srcEntry=${ability && ability.srcEntry}`,
);

const pagesProfile = String(moduleSpec.pages || '').replace('$profile:', '');
const pagesFile = path.join(ohosDir, 'entry/src/main/resources/base/profile', `${pagesProfile}.json`);
const pagesOk = moduleSpec.pages && fs.existsSync(pagesFile);
check('pages_profile', Boolean(pagesOk), `pages=${moduleSpec.pages}`);
if (pagesOk) {
  const pages = JSON.parse(fs.readFileSync(pagesFile, 'utf-8'));
  const pageOk = (pages.src || []).every((p) =>
    fs.existsSync(path.join(ohosDir, 'entry/src/main/ets', `${p}.ets`)),
  );
  check('pages_resolve', pageOk, (pages.src || []).join(','));
}

const perms = (moduleSpec.requestPermissions || []).map((p) => p.name);
check('internet_permission', perms.includes('ohos.permission.INTERNET'), perms.join(','));

const devices = (moduleSpec.deviceTypes || []).slice().sort().join(',');
check('device_types', devices === 'phone,tablet,tv', devices);

/** 5. EntryAbility 继承 flutter_ohos */
const abilitySrc = fs.readFileSync(path.join(ohosDir, 'entry/src/main/ets/entryability/EntryAbility.ets'), 'utf-8');
check(
  'flutter_ability',
  abilitySrc.includes('@ohos/flutter_ohos') && abilitySrc.includes('extends FlutterAbility'),
  'EntryAbility 必须继承 flutter_ohos 的 FlutterAbility',
);

/** 6. 工具链就绪度（仅提示） */
const flutterOhos = process.env.COLANAS_FLUTTER_OHOS || '';
let sdkState = 'missing';
if (flutterOhos && fs.existsSync(flutterOhos)) sdkState = 'env';
else {
  const probe = spawnSync('flutter', ['--version'], { encoding: 'utf-8', shell: true });
  const text = `${probe.stdout || ''}${probe.stderr || ''}`;
  if (probe.status === 0 && /ohos/i.test(text)) sdkState = 'path';
}
const harPath = path.join(ohosDir, 'entry/har/ohos-release.har');
const harState = fs.existsSync(harPath) ? 'present' : 'missing';

for (const r of results) console.log(`${r.ok ? '[OK]  ' : '[FAIL]'} ${r.name.padEnd(20)} ${r.detail}`);
console.log(`[info]   flutter_ohos_sdk    ${sdkState}${flutterOhos ? ` (${flutterOhos})` : ''}`);
console.log(`[info]   flutter_ohos_har    ${harState} (${path.join('ohos', 'entry', 'har', 'ohos-release.har')})`);
if (sdkState === 'missing' || harState === 'missing') {
  console.log(
    '[info]   build 未实测：需要 flutter_ohos（与 Flutter 3.47 配套）与 entry/har/ohos-release.har；' +
      `本机 ${os.platform()} 未检测到，接入后执行 \`flutter build hap\` 复测`,
  );
}

const failed = results.filter((r) => !r.ok);
console.log(`\n[ohos-project] ${results.length - failed.length}/${results.length} passed`);
process.exit(failed.length ? 1 : 0);