#!/usr/bin/env node
/**
 * MCP 工具清单一致性：
 *   - `contracts/mcp-tools.json` 是单一真源；
 *   - 每套 server 的 source 文件里 `const TOOLS = [...]` 的工具 name 集合必须与清单一致；
 *   - source 里的 `serverInfo.name` 必须与清单一致；
 *   - 照片 HTTP server 对外工具清单还硬编码在 `ai/settings.ts` 的 `MCP_TOOLS`，也要一致。
 *
 * 只读源码文本，不依赖 `npm run build`，可作为契约层一步并行跑。
 *
 * 用法：node tool/check/mcp-tools.js
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..', '..');
const manifestPath = path.join(root, 'contracts', 'mcp-tools.json');
const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf-8'));

function read(rel) {
  return fs.readFileSync(path.join(root, rel), 'utf-8');
}

/**
 * 截取从 `decl` 命中的位置起、到第一个行首 `];` 的片段。
 * 两套 server 的 TOOLS 都是顶层缩进 0 的数组，行首 `];` 是可靠的结束标志
 * （比括号配平更不怕 description 里出现方括号）。
 */
function blockOf(src, decl) {
  const start = src.indexOf(decl);
  if (start < 0) return null;
  const open = src.indexOf('[', start);
  if (open < 0) return null;
  const rest = src.slice(open);
  const endRel = rest.search(/^\];/m);
  if (endRel < 0) return null;
  return rest.slice(0, endRel + 2);
}

/** 从 TOOLS 块里提取 `name: '...'` */
function toolNames(src, decl) {
  const block = blockOf(src, decl);
  if (!block) return null;
  return [...block.matchAll(/name:\s*'([^']+)'/g)].map((m) => m[1]);
}

// 约定：serverInfo 必须**内联字面量** `serverInfo: { name: '...' }`，
// 不要用 `serverInfo: SOME_CONST` 间接引用 —— 否则这层文本校验读不到名字。
function serverInfoName(src) {
  const m = /serverInfo:\s*\{\s*name:\s*'([^']+)'/.exec(src);
  return m ? m[1] : null;
}

const problems = [];

function diff(message, expected, actual) {
  const miss = expected.filter((n) => !actual.includes(n));
  const extra = actual.filter((n) => !expected.includes(n));
  if (miss.length) problems.push(`${message}：清单登记但代码缺失 → ${miss.join(', ')}`);
  if (extra.length) problems.push(`${message}：代码有但清单未登记 → ${extra.join(', ')}`);
}

for (const [key, cfg] of Object.entries(manifest.servers || {})) {
  const src = read(cfg.source);
  const expected = (cfg.tools || []).map((t) => t.name);

  const actual = toolNames(src, 'const TOOLS =');
  if (!actual) {
    problems.push(`${key}: 在 ${cfg.source} 里找不到 const TOOLS = [...]`);
  } else {
    diff(`${key}(${cfg.source})`, expected, actual);
  }

  const info = serverInfoName(src);
  if (info !== cfg.serverInfo.name) {
    problems.push(`${key}: serverInfo.name 不一致（代码 ${info} ≠ 清单 ${cfg.serverInfo.name}）`);
  }
}

// photo HTTP server 的管理侧还维护了一份对外工具清单
const photo = manifest.servers && manifest.servers.photo;
if (photo) {
  const src = read('src/modules/photo/ai/settings.ts');
  const block = blockOf(src, 'export const MCP_TOOLS =');
  const settingsNames = block ? [...block.matchAll(/'([^']+)'/g)].map((m) => m[1]) : null;
  if (!settingsNames) {
    problems.push('photo: 在 src/modules/photo/ai/settings.ts 里找不到 MCP_TOOLS');
  } else {
    diff('photo(ai/settings.ts MCP_TOOLS)', photo.tools.map((t) => t.name), settingsNames);
  }
}

const serverCount = Object.keys(manifest.servers || {}).length;
const toolCount = Object.values(manifest.servers || {}).reduce(
  (n, s) => n + (s.tools || []).length,
  0,
);

if (problems.length > 0) {
  console.error('[FAIL] MCP 工具清单不一致：');
  for (const p of problems) console.error('  - ' + p);
  process.exit(1);
}

console.log(`[OK] MCP 工具清单一致：${serverCount} 套 server，共 ${toolCount} 个工具`);
