#!/usr/bin/env node
/**
 * SP4-02 签名工具：为构建目录生成 manifest.json（sha256 + ed25519 签名）。
 *
 * 用法：
 *   node tool/sign.js <dir> --version=104 --key=<private-key.pem> [--out=<path>]
 *
 * 私钥只在本机使用，禁止入库（.gitignore 已忽略 *.pem）。
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');

const { signManifest } = require(path.join(__dirname, '..', 'dist', 'kernel', 'updater.js'));

const args = process.argv.slice(2);
const dir = args.find((a) => !a.startsWith('--'));
const versionArg = args.find((a) => a.startsWith('--version='));
const keyArg = args.find((a) => a.startsWith('--key='));
const outArg = args.find((a) => a.startsWith('--out='));

if (!dir || !versionArg || !keyArg) {
  console.error('用法: node tool/sign.js <dir> --version=<n> --key=<private-key.pem> [--out=<path>]');
  process.exit(2);
}

const version = Number(versionArg.split('=')[1]);
const keyPath = keyArg.split('=')[1];
const outPath = outArg ? outArg.split('=')[1] : path.join(dir, 'manifest.json');

if (!fs.existsSync(dir)) {
  console.error('[FATAL] 目录不存在: ' + dir);
  process.exit(2);
}
if (!fs.existsSync(keyPath)) {
  console.error('[FATAL] 私钥不存在: ' + keyPath);
  process.exit(2);
}

const pem = fs.readFileSync(keyPath, 'utf8');
const manifest = signManifest(version, dir, pem);
fs.writeFileSync(outPath, JSON.stringify(manifest, null, 2), 'utf8');
console.log(`[OK] manifest: ${outPath}`);
console.log(`      version=${manifest.version} files=${Object.keys(manifest.files).length} algo=${manifest.algo}`);