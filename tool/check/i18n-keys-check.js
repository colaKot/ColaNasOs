#!/usr/bin/env node
/**
 * `tr('key')` ↔ `contracts/i18n.json` 的对账。
 *
 * 为什么要有：`tr()` 的兜底链是「当前语言 → zh-CN → **键本身**」。
 * 键不存在时它不报错、不抛异常，直接把 `music.play` 这种键名糊到界面上 ——
 * 表现就是「界面上好多英文」（其实是键名），而且**跑门禁全绿、跑测试也全绿**，
 * 只有人眼盯着才发现。2026-11-04 一次扫出 147 个这种键（音乐来源对话框、影视设置、
 * 服务端设置、笔记冲突……），就是靠这个脚本补的。
 *
 * 检查范围：客户端 `apps/colanas_os/lib` + 共享包 `packages/<name>/lib`。
 * 跳过带 `$` 的动态键（`discover.genre.$g` 这种是拼接出来的，静态查不了）。
 *
 * 用法：node tool/check/i18n-keys-check.js
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..', '..');
const registry = JSON.parse(
  fs.readFileSync(path.join(root, 'contracts', 'i18n.json'), 'utf-8'),
).keys;
const known = new Set(Object.keys(registry));

const SCAN_DIRS = [
  'apps/colanas_os/lib',
  ...fs
    .readdirSync(path.join(root, 'packages'), { withFileTypes: true })
    .filter((e) => e.isDirectory())
    .map((e) => `packages/${e.name}/lib`),
];

/** 命中位置：key → ['file:line', …] */
const missing = new Map();

function walk(dir) {
  const abs = path.join(root, dir);
  if (!fs.existsSync(abs)) return;
  for (const entry of fs.readdirSync(abs, { withFileTypes: true })) {
    const rel = `${dir}/${entry.name}`;
    if (entry.isDirectory()) {
      walk(rel);
      continue;
    }
    if (!entry.name.endsWith('.dart')) continue;
    const text = fs.readFileSync(path.join(root, rel), 'utf-8');
    // 按整个 `tr(...)` 调用扫参数：`tr(a ? 'x.y' : 'x.z')` 这种同一行只有第一个键
    // 会被行内正则漏掉，界面上于是又冒出「英文」（其实是第二个键名）。
    for (const call of text.matchAll(/\btr\s*\(/g)) {
      const loc = `${rel}:${text.slice(0, call.index).split('\n').length}`;
      let i = call.index + call[0].length;
      let depth = 1;
      while (i < text.length && depth > 0) {
        const ch = text[i];
        if (ch === "'") {
          let j = i + 1;
          while (j < text.length && !(text[j] === "'" && text[j - 1] !== '\\')) j += 1;
          const key = text.slice(i + 1, j);
          i = j + 1;
          if (key.includes('$')) continue; // 动态拼接，静态无法判定
          if (!/^[a-z][a-zA-Z0-9]*(\.[a-zA-Z0-9_]+)+$/.test(key)) continue; // 占位符值等非键
          if (known.has(key)) continue;
          if (!missing.has(key)) missing.set(key, []);
          missing.get(key).push(loc);
          continue;
        }
        if (ch === '/' && text[i + 1] === '/') {
          while (i < text.length && text[i] !== '\n') i += 1;
          continue;
        }
        if (ch === '(') depth += 1;
        else if (ch === ')') depth -= 1;
        i += 1;
      }
    }
  }
}

for (const dir of SCAN_DIRS) walk(dir);

if (missing.size === 0) {
  console.log(`[i18n.keys] ${known.size} 个键，界面里的 tr() 全部有对应文案`);
  process.exit(0);
}

console.error(`[i18n.keys] 有 ${missing.size} 个键在 contracts/i18n.json 里不存在，`);
console.error('界面会把键名直接显示出来（tr 的兜底就是键本身）：');
for (const [key, where] of [...missing.entries()].sort()) {
  console.error(`  ${key.padEnd(34)} ${where.slice(0, 3).join(', ')}`);
}
console.error('\n补法：contracts/i18n.json 注册键（带占位符要声明），');
console.error('      contracts/messages/{zh-CN,en-US}.json 各加一条，然后 npm run gen:i18n');
process.exit(1);
