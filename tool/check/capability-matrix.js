#!/usr/bin/env node
/**
 * 端能力矩阵门禁（CL4-02）：
 *  1. `contracts/apps.json#capabilities` 结构完整（6 能力 × 6 端，档位合法）
 *  2. nameKey 在 i18n 契约中登记，apps 引用真实存在的 App
 *  3. 与 `docs/04-客户端.md` §64 表格逐格一致（✅ full / ⚠️ limited / ❌ none）
 *  4. 生成物 `capability_matrix.dart` 与契约一致（调用 gen-capabilities --check）
 *  5. 客户端外壳已接线（`CapabilityMatrix.forApp` + `NasCapabilityNotice`）
 *
 * 用法：node tool/check/capability-matrix.js
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const root = path.join(__dirname, '..', '..');
const appsSpec = JSON.parse(fs.readFileSync(path.join(root, 'contracts', 'apps.json'), 'utf-8'));
const i18n = JSON.parse(fs.readFileSync(path.join(root, 'contracts', 'i18n.json'), 'utf-8'));
const docPath = path.join(root, 'docs', '04-客户端.md');

const caps = appsSpec.capabilities || {};
const endpoints = caps.endpoints || [];
const levels = caps.levels || [];
const items = caps.items || [];

const results = [];
const check = (name, ok, detail) => {
  results.push({ name, ok, detail: detail || '' });
};

/** 1. 结构完整 */
const expectedCapIds = ['files', 'photo', 'video', 'music', 'terminal', 'system'];
check(
  'contract_shape',
  endpoints.length === 6 && items.length === expectedCapIds.length,
  `endpoints=${endpoints.length}, items=${items.length}`,
);
const missingCaps = expectedCapIds.filter((id) => !items.some((it) => it.id === id));
check('capability_ids', missingCaps.length === 0, missingCaps.join(','));

const badLevels = [];
const missingCells = [];
for (const it of items) {
  for (const ep of endpoints) {
    const v = (it.levels || {})[ep];
    if (!v) missingCells.push(`${it.id}.${ep}`);
    else if (!levels.includes(v)) badLevels.push(`${it.id}.${ep}=${v}`);
  }
}
check('levels_complete', missingCells.length === 0, missingCells.join(','));
check('levels_enum', badLevels.length === 0, badLevels.join(','));

const dupIds = items.map((it) => it.id).filter((id, i, a) => a.indexOf(id) !== i);
check('capability_unique', dupIds.length === 0, dupIds.join(','));

/** 2. nameKey / apps 引用 */
const keys = new Set(Object.keys(i18n.keys || {}));
const unknownKeys = items.filter((it) => !keys.has(it.nameKey)).map((it) => it.nameKey);
check('name_keys_declared', unknownKeys.length === 0, unknownKeys.join(','));

const appIds = new Set((appsSpec.apps || []).map((a) => a.id));
const unknownApps = [];
for (const it of items) {
  for (const id of it.apps || []) if (!appIds.has(id)) unknownApps.push(`${it.id}->${id}`);
}
check('app_refs_exist', unknownApps.length === 0, unknownApps.join(','));


/** 3. 文档表格一致 */
const DOC_ROWS = {
  文件管理: 'files',
  相册: 'photo',
  影视播放: 'video',
  音乐: 'music',
  书籍阅读: 'book',
  终端: 'terminal',
  编辑器: 'editor',
  系统管理: 'system',
};
const MARK = { '✅': 'full', '⚠️': 'limited', '⚠': 'limited', '❌': 'none' };
/** 表格单元格可能带补充说明（如「⚠️ 受限」「⚠️ 只读」），按首个符号判定档位。 */
function markLevel(mark) {
  const text = String(mark || '').trim();
  for (const [symbol, level] of Object.entries(MARK)) {
    if (text.startsWith(symbol)) return level;
  }
  return null;
}

const doc = fs.readFileSync(docPath, 'utf-8');
const section = doc.split(/^## 64\./m)[1];
if (!section) {
  check('doc_section', false, 'docs/04-客户端.md 缺少 §64 端能力矩阵');
} else {
  const tableLines = section
    .split('\n')
    .map((l) => l.trim())
    .filter((l) => l.startsWith('|'));
  const cellsOf = (line) =>
    line
      .replace(/^\|/, '')
      .replace(/\|$/, '')
      .split('|')
      .map((c) => c.trim());
  const docEndpoints = cellsOf(tableLines[0] || '').slice(1);
  check(
    'doc_endpoints',
    docEndpoints.join(',') === endpoints.join(','),
    `doc=${docEndpoints.join(',')} contract=${endpoints.join(',')}`,
  );

  const mismatches = [];
  for (const line of tableLines.slice(2)) {
    const cells = cellsOf(line);
    if (!cells.length) continue;
    const capId = DOC_ROWS[cells[0]];
    if (!capId) {
      mismatches.push(`未映射的能力行「${cells[0]}」`);
      continue;
    }
    const entry = items.find((it) => it.id === capId);
    if (!entry) continue;
    endpoints.forEach((ep, i) => {
      const mark = cells[i + 1];
      const want = markLevel(mark);
      if (!want) {
        mismatches.push(`${capId}.${ep} 标记无法识别「${mark}」`);
        return;
      }
      const got = entry.levels[ep];
      if (got !== want) mismatches.push(`${capId}.${ep}: doc=${mark}(${want}) contract=${got}`);
    });
  }
  const docRows = tableLines.slice(2).filter((l) => DOC_ROWS[cellsOf(l)[0]]).length;
  check(
    'doc_matches_contract',
    mismatches.length === 0 && docRows === expectedCapIds.length,
    mismatches.length ? mismatches.join('; ') : `rows=${docRows}`,
  );
}

/** 4. 生成物一致 */
const gen = spawnSync(process.execPath, [path.join(root, 'tool', 'gen-capabilities.js'), '--check'], {
  cwd: root,
  encoding: 'utf-8',
});
check('generated_dart', gen.status === 0, (gen.stdout || gen.stderr || '').trim());

/** 5. 客户端接线 */
const shell = fs.readFileSync(
  path.join(root, 'apps', 'colanas_os', 'lib', 'shell', 'app_shell.dart'),
  'utf-8',
);
check(
  'shell_wired',
  shell.includes('CapabilityMatrix.forApp') && shell.includes('NasCapabilityNotice'),
  shell.includes('CapabilityMatrix.forApp') ? '已接线' : '外壳未接入能力矩阵提示',
);

for (const r of results) console.log(`${r.ok ? '[OK]  ' : '[FAIL]'} ${r.name.padEnd(24)} ${r.detail}`);
const failed = results.filter((r) => !r.ok);
console.log(`\n[capability-matrix] ${results.length - failed.length}/${results.length} passed`);
process.exit(failed.length ? 1 : 0);