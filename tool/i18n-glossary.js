#!/usr/bin/env node
/**
 * X-05 翻译工作流校验：
 *   1. 每个 locale 的键集合必须与 contracts/i18n.json 完全一致
 *   2. 声明了占位符的键，译文里必须保留同名占位符（且不得出现未声明的占位符）
 *   3. contracts/glossary.json 的 forbidden 写法不得出现在任何译文里
 *   4. 非 CJK 语言的译文里出现中文 → 记为「疑似未翻译」（仅提示，不失败）
 *
 * 用法：node tool/i18n-glossary.js [--strict]
 *   --strict 时空译文也视为失败（发布前使用；当前骨架阶段不加）
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..');
const contract = JSON.parse(fs.readFileSync(path.join(root, 'contracts', 'i18n.json'), 'utf8'));
const glossary = JSON.parse(fs.readFileSync(path.join(root, 'contracts', 'glossary.json'), 'utf8'));
const l10nDir = path.join(root, 'packages', 'nas_core', 'lib', 'l10n');

const STRICT = process.argv.includes('--strict');
const CJK = /[\u4e00-\u9fff]/;
const CJK_LOCALES = new Set(['zh-CN', 'ja-JP', 'ko-KR']);
const PH = /\{([a-zA-Z0-9_.]+)\}/g;

const expected = Object.keys(contract.keys);
const problems = [];
const notes = [];

function placeholdersOf(text) {
  const out = new Set();
  let m;
  PH.lastIndex = 0;
  while ((m = PH.exec(text)) !== null) out.add(m[1]);
  return out;
}

const locales = fs
  .readdirSync(l10nDir)
  .filter((f) => f.endsWith('.json'))
  .map((f) => f.replace(/\.json$/, ''));

for (const loc of locales) {
  const file = path.join(l10nDir, `${loc}.json`);
  const data = JSON.parse(fs.readFileSync(file, 'utf8'));
  const msgs = data.messages || {};
  const keys = Object.keys(msgs);

  for (const k of expected) {
    if (!(k in msgs)) problems.push(`${loc}: 缺键 ${k}`);
  }
  for (const k of keys) {
    if (!expected.includes(k)) problems.push(`${loc}: 多余键 ${k}`);
  }

  for (const k of expected) {
    const value = msgs[k];
    if (typeof value !== 'string') continue;
    // 空译文＝尚未翻译：骨架阶段允许，--strict 才视为问题
    if (value.trim() === '') {
      if (STRICT) problems.push(`${loc}: ${k} 空译文`);
      continue;
    }

    const decl = contract.keys[k] || {};
    const declared = new Set(Object.keys(decl));
    const got = placeholdersOf(value);

    for (const p of declared) {
      if (!got.has(p)) problems.push(`${loc}: ${k} 缺占位符 {${p}}`);
    }
    for (const p of got) {
      if (!declared.has(p)) problems.push(`${loc}: ${k} 出现未声明占位符 {${p}}`);
    }

    for (const term of glossary.terms) {
      for (const bad of term.forbidden || []) {
        if (value.includes(bad)) problems.push(`${loc}: ${k} 命中禁用译法「${bad}」(${term.id})`);
      }
    }

    if (value && !CJK_LOCALES.has(loc) && CJK.test(value)) {
      notes.push(`${loc}: ${k} 疑似未翻译（含中文）`);
    }
  }
}

const summary =
  `[i18n] ${locales.length} 个 locale × ${expected.length} 键 ` +
  `（术语 ${glossary.terms.length} 条，占位符键 ${expected.filter((k) => Object.keys(contract.keys[k] || {}).length).length} 个）`;

if (notes.length) {
  console.log(`[i18n] 提示：${notes.length} 条疑似未翻译（骨架阶段正常）`);
}
if (problems.length) {
  console.error(`${summary}\n[FAIL] ${problems.length} 处问题：`);
  for (const p of problems.slice(0, 30)) console.error('  - ' + p);
  process.exit(1);
}
console.log(`${summary}\n[OK]   键 / 占位符 / 术语一致`);
process.exit(0);