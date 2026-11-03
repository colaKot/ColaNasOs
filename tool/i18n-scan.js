#!/usr/bin/env node
/**
 * i18n 接线进度（信息性，不失败）：
 *   - 扫描 apps 目录下 `lib/` 的 .dart 里的中文字符串字面量（排除注释与生成物）
 *   - 统计已接线的 `tr('...')` / `I18n.instance.tr('...')` 调用
 *   - 列出「中文最多但接线最少」的文件，供逐页迁移
 *
 * 约定：
 *   - `test/` 里的中文是断言/测试数据，不属于 UI 文案，不计入；
 *   - 协议值（如豆瓣接口的分类 tag、.desktop 内容）无法翻译，行尾标 `// i18n-ignore` 豁免。
 *
 * 用法：node tool/i18n-scan.js [--json]
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..');
const appsDir = path.join(root, 'apps');

function walk(dir, out = []) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    if (
      e.name === 'build' ||
      e.name === '.dart_tool' ||
      e.name === 'ios' ||
      e.name === 'android' ||
      e.name === 'test'
    ) {
      continue;
    }
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p, out);
    else if (p.endsWith('.dart') && !p.endsWith('keys.dart')) out.push(p);
  }
  return out;
}

const HAN = /[\u4e00-\u9fa5]/;
const files = walk(appsDir);

const perFile = [];

for (const file of files) {
  const rel = path.relative(root, file);
  const lines = fs.readFileSync(file, 'utf-8').split('\n');
  let hanLines = 0;
  let trCalls = 0;

  for (const line of lines) {
    const trimmed = line.trim();
    if (trimmed.startsWith('//') || trimmed.startsWith('*') || trimmed.startsWith('/*')) continue;
    // 协议常量 / 桌面文件内容等无法翻译的字面量：行尾 `// i18n-ignore`
    if (line.includes('i18n-ignore')) continue;
    // 去掉行尾注释后再判断
    const code = trimmed.split('//')[0];
    if (HAN.test(code)) hanLines += 1;
    trCalls += (code.match(/\btr\(/g) || []).length;
  }

  if (hanLines > 0 || trCalls > 0) perFile.push({ rel, hanLines, trCalls });
}

perFile.sort((a, b) => b.hanLines - a.hanLines);

const wired = perFile.reduce((acc, f) => acc + f.trCalls, 0);
const pending = perFile.reduce((acc, f) => acc + f.hanLines, 0);
const pct = wired + pending === 0 ? 100 : Math.round((wired / (wired + pending)) * 100);

if (process.argv.includes('--json')) {
  console.log(JSON.stringify({ wired, pending, ratio: pct, files: perFile }, null, 2));
} else {
  console.log(`[i18n] 已接线文案（tr 调用）${wired} 处，中文字面量 ${pending} 行，粗略进度 ${pct}%`);
  console.log('[i18n] 待迁移最多的文件：');
  for (const f of perFile.slice(0, 10)) {
    if (f.hanLines === 0) break;
    console.log(`  ${String(f.hanLines).padStart(3)} 行  tr=${String(f.trCalls).padStart(3)}  ${f.rel}`);
  }
}