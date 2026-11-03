#!/usr/bin/env node
/**
 * 版本单一真源（X-01 / SP4-03）：
 *   `package.json.version` 是产品版本（npm + electron-builder 都读它），
 *   `apps/colanas_os/pubspec.yaml` 与鸿蒙 `AppScope/app.json5` 由本脚本同步。
 *
 * 用法：
 *   node tool/version.js                 同步 pubspec / 鸿蒙版本
 *   node tool/version.js --check         校验三处一致（verify 用）
 *   node tool/version.js --set=1.0.1     升级产品版本（build 号 +1）
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
const pubspecPath = path.join(root, 'apps', 'colanas_os', 'pubspec.yaml');
const ohosAppPath = path.join(root, 'apps', 'colanas_os', 'ohos', 'AppScope', 'app.json5');

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

function readPubspec() {
  const text = fs.readFileSync(pubspecPath, 'utf-8');
  const m = /^version:\s*([0-9]+)\.([0-9]+)\.([0-9]+)\+([0-9]+)\s*$/m.exec(text);
  if (!m) throw new Error('pubspec.yaml 缺少 `version: X.Y.Z+B`');
  return {
    text,
    name: `${m[1]}.${m[2]}.${m[3]}`,
    build: +m[4],
    line: m[0],
  };
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

const product = parseProduct();
const pubspec = readPubspec();
const ohos = readOhos();
const wantOhosCode = ohosCode(product);

const mismatches = [];
if (pubspec.name !== product.raw) mismatches.push(`pubspec=${pubspec.name}`);
if (ohos.name !== product.raw) mismatches.push(`ohos.versionName=${ohos.name}`);
if (ohos.code !== wantOhosCode) mismatches.push(`ohos.versionCode=${ohos.code}`);

if (checkOnly) {
  if (mismatches.length) {
    console.error(
      `[version.check] 版本不一致（产品 ${product.raw}）：${mismatches.join(', ')}；` +
        '运行 npm run version:sync 同步',
    );
    process.exit(1);
  }
  console.log(`[version.check] ok ${product.raw} (pubspec +${pubspec.build}, ohos ${wantOhosCode})`);
  process.exit(0);
}

let target = product;
let nextBuild = pubspec.build;
if (setArg) {
  const value = setArg.slice('--set='.length);
  const m = SEMVER.exec(value);
  if (!m) throw new Error(`--set 需要 X.Y.Z：${value}`);
  target = { raw: value, major: +m[1], minor: +m[2], patch: +m[3] };
  nextBuild = pubspec.build + 1;
} else if (mismatches.length === 0) {
  console.log(`[version] 已是 ${product.raw}，无需同步`);
  process.exit(0);
}

/** 1. package.json（仅 --set 时改） */
if (setArg) {
  const pkg = JSON.parse(fs.readFileSync(pkgPath, 'utf-8'));
  pkg.version = target.raw;
  fs.writeFileSync(pkgPath, JSON.stringify(pkg, null, 2) + '\n', 'utf-8');
}

/** 2. pubspec：替换 version 行，保留 build 号（--set 时 +1） */
const nextPubspec = pubspec.text.replace(/^version:.*$/m, `version: ${target.raw}+${nextBuild}`);
fs.writeFileSync(pubspecPath, nextPubspec, 'utf-8');

/** 3. 鸿蒙 AppScope：versionName / versionCode */
const nextOhos = ohos.text
  .replace(/"versionName":\s*"[^"]+"/, `"versionName": "${target.raw}"`)
  .replace(/"versionCode":\s*\d+/, `"versionCode": ${ohosCode(target)}`);
fs.writeFileSync(ohosAppPath, nextOhos, 'utf-8');

console.log(
  `[version] ${target.raw} → pubspec ${target.raw}+${nextBuild}，` +
    `ohos ${target.raw}/${ohosCode(target)}${setArg ? '（build +1）' : ''}`,
);