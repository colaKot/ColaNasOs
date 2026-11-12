#!/usr/bin/env node
/**
 * 版本单一真源（X-01 / SP4-03）：
 *   `package.json.version` 是产品版本（npm + electron-builder 都读它），
 *   其它版本号来源都由本脚本同步：
 *     - apps/*\/pubspec.yaml            version: X.Y.Z+B
 *     - apps/*\/windows/runner/Runner.rc 兜底字面量（FLUTTER_VERSION 分支不动）
 *     - apps/colanas_os/ohos/AppScope/app.json5   versionName / versionCode
 *     - apps/colanas_os/ohos/entry/oh-package.json5
 *     - apps/colanas_os/lib/core/app_version.dart 关于页展示用常量
 *
 * 用法：
 *   node tool/version.js                 同步以上各处
 *   node tool/version.js --check         校验全部一致（verify 用）
 *   node tool/version.js --set=1.0.1     升级产品版本（各 pubspec build 号 +1）
 *
 * 版本规则：
 *   产品版本 X.Y.Z（package.json）
 *   pubspec  version: X.Y.Z+B（B = Flutter build number，独立递增）
 *   鸿蒙     versionName: X.Y.Z，versionCode: X*1000000 + Y*1000 + Z
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..');
const pkgPath = path.join(root, 'package.json');
const ohosAppPath = path.join(root, 'apps', 'colanas_os', 'ohos', 'AppScope', 'app.json5');
const ohosPkgPath = path.join(root, 'apps', 'colanas_os', 'ohos', 'entry', 'oh-package.json5');
const dartVersionPath = path.join(root, 'apps', 'colanas_os', 'lib', 'core', 'app_version.dart');

/** 所有随仓库发布的 Flutter 应用（存在才处理）。 */
const appPaths = fs
  .readdirSync(path.join(root, 'apps'), { withFileTypes: true })
  .filter((d) => d.isDirectory())
  .map((d) => ({
    id: d.name,
    pubspec: path.join(root, 'apps', d.name, 'pubspec.yaml'),
    runnerRc: path.join(root, 'apps', d.name, 'windows', 'runner', 'Runner.rc'),
  }))
  .filter((a) => fs.existsSync(a.pubspec));

const args = process.argv.slice(2);
const checkOnly = args.includes('--check');
const setArg = args.find((a) => a.startsWith('--set='));

const SEMVER = /^(\d+)\.(\d+)\.(\d+)$/;

function parseProduct() {
  const pkg = JSON.parse(fs.readFileSync(pkgPath, 'utf-8'));
  const m = SEMVER.exec(pkg.version || '');
  if (!m) throw new Error(`package.json version 不是 X.Y.Z：${pkg.version}`);
  return { pkg, raw: pkg.version, major: +m[1], minor: +m[2], patch: +m[3] };
}

function readPubspec(file) {
  const text = fs.readFileSync(file, 'utf-8');
  const m = /^version:\s*([0-9]+)\.([0-9]+)\.([0-9]+)\+([0-9]+)\s*$/m.exec(text);
  if (!m) throw new Error(`${path.relative(root, file)} 缺少 \`version: X.Y.Z+B\``);
  return { file, text, name: `${m[1]}.${m[2]}.${m[3]}`, build: +m[4], line: m[0] };
}

function ohosCode(v) {
  return v.major * 1000000 + v.minor * 1000 + v.patch;
}

function readOhos() {
  const text = fs.readFileSync(ohosAppPath, 'utf-8');
  const name = /"versionName":\s*"([^"]+)"/.exec(text);
  const code = /"versionCode":\s*(\d+)/.exec(text);
  return { text, name: name && name[1], code: code && +code[1] };
}

function readOhosPkg() {
  if (!fs.existsSync(ohosPkgPath)) return null;
  const text = fs.readFileSync(ohosPkgPath, 'utf-8');
  const m = /"version":\s*"([^"]+)"/.exec(text);
  return { text, name: m && m[1] };
}

function readDartVersion() {
  if (!fs.existsSync(dartVersionPath)) return null;
  const text = fs.readFileSync(dartVersionPath, 'utf-8');
  const m = /kAppVersion\s*=\s*'([^']+)'/.exec(text);
  return { text, name: m && m[1] };
}

const product = parseProduct();
const pubspecs = appPaths.map((a) => ({ ...a, pub: readPubspec(a.pubspec) }));
const ohos = readOhos();
const ohosPkg = readOhosPkg();
const dartVersion = readDartVersion();
const wantOhosCode = ohosCode(product);

const mismatches = [];
for (const p of pubspecs) {
  if (p.pub.name !== product.raw) mismatches.push(`${p.id}.pubspec=${p.pub.name}`);
}
if (ohos.name !== product.raw) mismatches.push(`ohos.versionName=${ohos.name}`);
if (ohos.code !== wantOhosCode) mismatches.push(`ohos.versionCode=${ohos.code}`);
if (ohosPkg && ohosPkg.name !== product.raw) mismatches.push(`ohos.entry=${ohosPkg.name}`);
if (dartVersion && dartVersion.name !== product.raw) {
  mismatches.push(`app_version.dart=${dartVersion.name}`);
}

if (checkOnly) {
  if (mismatches.length) {
    console.error(
      `[version.check] 版本不一致（产品 ${product.raw}）：${mismatches.join(', ')}；` +
        '运行 npm run version:sync 同步',
    );
    process.exit(1);
  }
  const builds = pubspecs.map((p) => `${p.id}+${p.pub.build}`).join(', ');
  console.log(`[version.check] ok ${product.raw} (${builds}; ohos ${wantOhosCode})`);
  process.exit(0);
}

let target = product;
const hasDrift = mismatches.length > 0;
if (setArg) {
  const value = setArg.slice('--set='.length);
  const m = SEMVER.exec(value);
  if (!m) throw new Error(`--set 需要 X.Y.Z：${value}`);
  target = { raw: value, major: +m[1], minor: +m[2], patch: +m[3] };
} else if (!hasDrift) {
  console.log(`[version] 已是 ${product.raw}，无需同步`);
  process.exit(0);
}

/** 1. package.json（仅 --set 时改） */
if (setArg) {
  const pkg = JSON.parse(fs.readFileSync(pkgPath, 'utf-8'));
  pkg.version = target.raw;
  fs.writeFileSync(pkgPath, JSON.stringify(pkg, null, 2) + '\n', 'utf-8');
}

/** 2. 各 app 的 pubspec：替换 version 行，--set 时 build 号 +1 */
for (const p of pubspecs) {
  const nextBuild = setArg ? p.pub.build + 1 : p.pub.build;
  const next = p.pub.text.replace(/^version:.*$/m, `version: ${target.raw}+${nextBuild}`);
  fs.writeFileSync(p.pubspec, next, 'utf-8');
}

/** 3. 鸿蒙 AppScope：versionName / versionCode */
const nextOhos = ohos.text
  .replace(/"versionName":\s*"[^"]+"/, `"versionName": "${target.raw}"`)
  .replace(/"versionCode":\s*\d+/, `"versionCode": ${ohosCode(target)}`);
fs.writeFileSync(ohosAppPath, nextOhos, 'utf-8');

/** 4. 鸿蒙 entry 包版本 */
if (ohosPkg) {
  const nextPkg = ohosPkg.text.replace(/"version":\s*"[^"]+"/, `"version": "${target.raw}"`);
  fs.writeFileSync(ohosPkgPath, nextPkg, 'utf-8');
}

/** 5. 关于页展示常量 */
if (dartVersion) {
  const nextDart = dartVersion.text.replace(
    /kAppVersion\s*=\s*'[^']+'/,
    `kAppVersion = '${target.raw}'`,
  );
  fs.writeFileSync(dartVersionPath, nextDart, 'utf-8');
}

/** 6. Windows runner 的兜底字面量（FLUTTER_VERSION 分支保持不动） */
for (const a of appPaths) {
  if (!fs.existsSync(a.runnerRc)) continue;
  const text = fs.readFileSync(a.runnerRc, 'utf-8');
  const next = text.replace(
    /(#define VERSION_AS_STRING ")\d+\.\d+\.\d+(")/,
    `$1${target.raw}$2`,
  );
  if (next !== text) fs.writeFileSync(a.runnerRc, next, 'utf-8');
}

const builds = pubspecs.map((p) => `${p.id} ${target.raw}+${setArg ? p.pub.build + 1 : p.pub.build}`);
console.log(
  `[version] ${target.raw} → ${builds.join('，')}；` +
    `ohos ${target.raw}/${ohosCode(target)}${setArg ? '（各 build +1）' : ''}`,
);
