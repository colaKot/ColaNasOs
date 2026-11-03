#!/usr/bin/env node
/**
 * 错误码一致性（docs/10-DoD §2）：
 *   - 代码里用到的 `Err.xxx` 必须在 `contracts/errors.json` 里登记
 *   - 不许再出现裸字符串 `error: 'xxx'`（新代码）
 *   - 契约里登记但没人用的码只告警（可能是给外部客户端预留）
 *
 * 用法：node tool/check/errors.js
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..', '..');
const spec = JSON.parse(fs.readFileSync(path.join(root, 'contracts', 'errors.json'), 'utf-8'));
const known = new Map(Object.entries(spec.codes || {}));

function walk(dir, out = []) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) {
      if (e.name === 'dist' || e.name === 'node_modules') continue;
      walk(p, out);
    } else if (p.endsWith('.ts')) out.push(p);
  }
  return out;
}

const files = [
  ...walk(path.join(root, 'src')),
  ...walk(path.join(root, 'kernel')),
  ...walk(path.join(root, 'electron')),
].filter((f) => !f.endsWith(path.join('kernel', 'errors.ts')));

const used = new Map();
const raw = [];
const missing = [];

for (const file of files) {
  const src = fs.readFileSync(file, 'utf-8');
  const rel = path.relative(root, file);

  for (const m of src.matchAll(/\bErr\.([A-Za-z][A-Za-z0-9]*)/g)) {
    const code = m[1];
    used.set(code, (used.get(code) || 0) + 1);
    if (!known.has(code)) missing.push(`${rel}: Err.${code}`);
  }

  // 裸字符串错误码（忽略 kernel/errors.ts 与注释里提到的样例）
  const lines = src.split('\n');
  lines.forEach((line, i) => {
    if (line.trim().startsWith('*') || line.trim().startsWith('//')) return;
    const m = /error:\s*'([A-Za-z][A-Za-z0-9]*)'/.exec(line);
    if (m && known.has(m[1])) raw.push(`${rel}:${i + 1} error: '${m[1]}'`);
  });
}

let failed = 0;
if (missing.length > 0) {
  failed += 1;
  console.error('[FAIL] 代码用了契约里没有的错误码：');
  for (const m of missing.slice(0, 20)) console.error('  ' + m);
  if (missing.length > 20) console.error(`  ... 还有 ${missing.length - 20} 条`);
}

if (raw.length > 0) {
  failed += 1;
  console.error('[FAIL] 仍在用裸字符串错误码（应改为 Err.<code>）：');
  for (const m of raw.slice(0, 20)) console.error('  ' + m);
  if (raw.length > 20) console.error(`  ... 还有 ${raw.length - 20} 条`);
}

const unused = [...known.keys()].filter((c) => !used.has(c));
if (unused.length > 0) {
  console.log(`[warn] 契约里登记但代码未使用的码：${unused.join(' / ')}`);
}

if (failed === 0) {
  console.log(`[OK] 错误码一致：登记 ${known.size} 个，使用 ${used.size} 个，裸字符串 0 处`);
}
process.exit(failed === 0 ? 0 : 1);