#!/usr/bin/env node
/**
 * i18n 骨架生成器（SP1-03）。
 * 输入：contracts/i18n.json（键 + 占位符）、contracts/locales.json（语言清单）
 * 输出：packages/nas_core/lib/l10n/keys.dart + <locale>.json（每语言一份骨架，值为空）
 *
 * 只生成键与占位符，**不生成译文**（译文按术语表独立翻译，见 §0.1）。
 *
 * 用法：
 *   node tool/gen-i18n.js            生成
 *   node tool/gen-i18n.js --check    校验磁盘与契约一致
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..');
const i18nPath = path.join(root, 'contracts', 'i18n.json');
const localesPath = path.join(root, 'contracts', 'locales.json');
const outDir = path.join(root, 'packages', 'nas_core', 'lib', 'l10n');
const checkOnly = process.argv.includes('--check');

const i18n = JSON.parse(fs.readFileSync(i18nPath, 'utf-8'));
const locales = JSON.parse(fs.readFileSync(localesPath, 'utf-8'));

const keys = Object.keys(i18n.keys || {});
const localeCodes = locales.filter((l) => l.enabled !== false).map((l) => l.code);

/** `files.upload.progress` → `filesUploadProgress` */
function camelKey(key) {
  const parts = key.split(/[^a-zA-Z0-9]+/).filter(Boolean);
  return parts
    .map((p, i) =>
      i === 0 ? p.charAt(0).toLowerCase() + p.slice(1) : p.charAt(0).toUpperCase() + p.slice(1),
    )
    .join('');
}

function genKeys() {
  const lines = [
    '// AUTO-GENERATED. DO NOT EDIT.',
    '// source: contracts/i18n.json',
    '// regenerate: npm run gen:i18n',
    '',
    '/// 全部文案键。UI 禁止硬编码文案，一律引用这里的常量。',
    'class I18nKeys {',
    '  I18nKeys._();',
    '',
  ];

  let currentNs = null;
  const used = new Map();

  for (const key of keys) {
    const ns = key.split('.')[0];
    if (ns !== currentNs) {
      lines.push(`  // ---- ${ns} ----`);
      currentNs = ns;
    }
    let name = camelKey(key);
    if (used.has(name)) {
      // 冲突时加数字后缀，保证唯一
      const n = used.get(name) + 1;
      used.set(name, n);
      name = `${name}${n}`;
    } else {
      used.set(name, 1);
    }
    lines.push(`  static const ${name} = '${key}';`);
  }

  lines.push(
    '}',
    '',
    '/// 契约键总数（生成时确定），供完整性自检使用。',
    `const int i18nKeyCount = ${keys.length};`,
    '',
  );

  return lines.join('\n');
}

function genLocale(code) {
  // 文案来源：contracts/messages/<code>.json（人工维护）；缺失的键留空串，运行时回退 zh-CN
  const msgPath = path.join(root, 'contracts', 'messages', `${code}.json`);
  let messages = {};
  if (fs.existsSync(msgPath)) {
    try {
      messages = JSON.parse(fs.readFileSync(msgPath, 'utf-8')).messages || {};
    } catch (err) {
      console.error(`[gen-i18n] 读取 ${msgPath} 失败：${err.message}`);
      messages = {};
    }
  }
  const obj = {};
  for (const key of keys) obj[key] = typeof messages[key] === 'string' ? messages[key] : '';
  return JSON.stringify({ locale: code, version: 1, messages: obj }, null, 2) + '\n';
}

const outputs = [{ file: path.join(outDir, 'keys.dart'), content: genKeys() }];
const appAssetsDir = path.join(root, 'apps', 'colanas_os', 'assets', 'i18n');
for (const code of localeCodes) {
  const content = genLocale(code);
  outputs.push({ file: path.join(outDir, `${code}.json`), content });
  // Flutter 侧从 assets 加载（rootBundle），与契约产物保持同一份内容
  outputs.push({ file: path.join(appAssetsDir, `${code}.json`), content });
}

let stale = 0;
for (const { file, content } of outputs) {
  const prev = fs.existsSync(file) ? fs.readFileSync(file, 'utf-8') : '';
  if (prev === content) continue;
  stale++;
  if (checkOnly) continue;
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, content, 'utf-8');
}

if (checkOnly) {
  // 停用的语言不应再残留语言包（否则客户端可能加载到 0 译文的老文件）
  const staleLocaleFiles = [];
  for (const dir of [outDir, appAssetsDir]) {
    if (!fs.existsSync(dir)) continue;
    for (const name of fs.readdirSync(dir)) {
      const code = name.endsWith('.json') ? name.slice(0, -'.json'.length) : '';
      if (code && !localeCodes.includes(code)) {
        staleLocaleFiles.push(path.join(dir, name));
      }
    }
  }
  if (staleLocaleFiles.length) {
    console.error(
      `[gen-i18n.check] ${staleLocaleFiles.length} 个已停用语言包仍在磁盘上（${staleLocaleFiles
        .map((f) => path.basename(f))
        .join(', ')}），请运行 npm run gen:i18n`,
    );
    process.exit(1);
  }
  if (stale > 0) {
    console.error(`[gen-i18n.check] ${stale} 个文件已过期，请运行 npm run gen:i18n`);
    process.exit(1);
  }
  console.log(`[gen-i18n.check] ok, locales=${localeCodes.length}, keys=${keys.length}`);
} else {
  // 清理已停用语言的历史产物（enabled=false 后不应继续分发 0 译文的语言包）
  for (const dir of [outDir, appAssetsDir]) {
    if (!fs.existsSync(dir)) continue;
    for (const name of fs.readdirSync(dir)) {
      const code = name.endsWith('.json') ? name.slice(0, -'.json'.length) : '';
      if (code && !localeCodes.includes(code)) {
        fs.rmSync(path.join(dir, name), { force: true });
      }
    }
  }
  console.log(
    `[gen-i18n] keys=${keys.length}, locales=${localeCodes.length}, wrote ${stale} file(s)`,
  );
}
