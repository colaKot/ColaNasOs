#!/usr/bin/env node
/**
 * 从 `contracts/openapi.json` 生成 API 参考（`docs/api/api-reference.md`）。
 *
 * 契约是唯一真源：本文件只是它的人类可读投影，**禁止手改**。
 *   npm run api:doc        重新生成
 *   npm run api:doc.check  仅校验（与契约不一致则退出 1，已接入 verify）
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..');
const specPath = path.join(root, 'contracts', 'openapi.json');
const outPath = path.join(root, 'docs', 'api', 'api-reference.md');
const METHODS = ['get', 'post', 'put', 'patch', 'delete'];

const TAG_TITLES = {
  auth: '认证与账号',
  accounts: '子账号与权限',
  photo: '相册',
  video: '影视',
  music: '音乐',
  book: '书房',
  notes: '笔记',
  files: '文件',
  share: '分享',
  safety: '安全中心（备份 / 加密空间）',
  system: '系统监控',
  rss: 'RSS 订阅',
  sync: '同步',
  messages: '站内消息',
  message: '站内消息',
  webhook: 'Webhook',
  integration: '开放集成（Webhook / deliveries）',
  mount: '远程挂载',
  media: '媒体工具',
  other: '其他',
};

/** 把 schema 压成一行可读类型，避免文档里出现整块 JSON Schema。 */
function typeOf(schema) {
  if (!schema || typeof schema !== 'object') return '-';
  if (schema.$ref) return '`' + String(schema.$ref).split('/').pop() + '`';
  if (Array.isArray(schema.anyOf)) {
    const enums = schema.anyOf.filter((s) => Array.isArray(s.enum));
    if (enums.length === schema.anyOf.length) {
      return 'enum(' + enums.map((s) => s.enum.join('|')).join(', ') + ')';
    }
    return schema.anyOf.map(typeOf).join(' | ');
  }
  if (Array.isArray(schema.enum)) return 'enum(' + schema.enum.join('|') + ')';
  if (schema.type === 'array') return 'array<' + typeOf(schema.items) + '>';
  return schema.type || '-';
}

function bodyFields(op) {
  const schema = op.requestBody?.content?.['application/json']?.schema;
  if (!schema) return null;
  const required = new Set(schema.required || []);
  const props = schema.properties || {};
  const names = Object.keys(props);
  if (names.length === 0) return '（空对象）';
  return names
    .map((n) => {
      const mark = required.has(n) ? '**必填**' : '可选';
      return `\`${n}\` ${typeOf(props[n])} · ${mark}`;
    })
    .join('<br>');
}

function paramRows(op) {
  const rows = (op.parameters || []).map((p) => {
    const where = p.in === 'path' ? '路径' : p.in === 'query' ? '查询' : p.in;
    return `\`${p.name}\` · ${where} · ${typeOf(p.schema)} · ${p.required ? '**必填**' : '可选'}`;
  });
  return rows.length ? rows.join('<br>') : null;
}

function responseSummary(op) {
  const codes = Object.keys(op.responses || {}).sort();
  const ok = op.responses?.['200']?.content?.['application/json']?.schema;
  const okType = ok ? typeOf(ok) : '-';
  const errors = codes.filter((c) => c !== '200');
  return `200 ${okType}${errors.length ? ` · 错误 ${errors.join(' / ')}` : ''}`;
}

function collect(spec) {
  const groups = new Map();
  for (const p of Object.keys(spec.paths).sort()) {
    for (const m of METHODS) {
      const op = spec.paths[p][m];
      if (!op) continue;
      const tag = op.tags?.[0] || p.split('/')[3] || 'other';
      if (!groups.has(tag)) groups.set(tag, []);
      groups.get(tag).push({ path: p, method: m.toUpperCase(), op });
    }
  }
  return groups;
}

function render(spec) {
  const groups = collect(spec);
  const total = [...groups.values()].reduce((n, list) => n + list.length, 0);
  const tags = [...groups.keys()].sort();

  const lines = [];
  lines.push('# API 参考');
  lines.push('');
  lines.push(
    '> 由 `tool/gen-api-doc.js` 从 `contracts/openapi.json` 生成，**请勿手改**；' +
      '改契约后执行 `npm run api:doc`。',
  );
  lines.push(
    `> 当前：**${Object.keys(spec.paths).length} 个路径 / ${total} 个操作 / ${tags.length} 个域**。` +
      '鉴权统一为 `Authorization: Bearer <jwt>`，媒体直链另支持 `?token=`（5 分钟）。',
  );
  lines.push('');
  lines.push('## 域索引');
  lines.push('');
  for (const tag of tags) {
    const list = groups.get(tag);
    const title = TAG_TITLES[tag] || tag;
    lines.push(`- **${title}**（\`${tag}\`）· ${list.length} 个操作 · [跳转](#${tag})`);
  }
  lines.push('');

  for (const tag of tags) {
    const title = TAG_TITLES[tag] || tag;
    lines.push(`## ${tag}`);
    lines.push('');
    lines.push(`### ${title}`);
    lines.push('');
    for (const item of groups.get(tag)) {
      lines.push(`#### \`${item.method} ${item.path}\``);
      lines.push('');
      const summary = item.op.summary || '-';
      lines.push(`${summary} · \`${item.op.operationId || '-'}\``);
      lines.push('');
      const params = paramRows(item.op);
      const body = bodyFields(item.op);
      if (params) lines.push(`- 参数：${params}`);
      if (body) lines.push(`- 请求体：${body}`);
      lines.push(`- 响应：${responseSummary(item.op)}`);
      lines.push('');
    }
  }

  return lines.join('\n');
}

const spec = JSON.parse(fs.readFileSync(specPath, 'utf-8'));
const next = render(spec).replace(/\s*$/, '') + '\n';
const prev = fs.existsSync(outPath) ? fs.readFileSync(outPath, 'utf-8') : null;

if (process.argv.includes('--check')) {
  if (prev !== next) {
    console.error('[api:doc] docs/api/api-reference.md 与契约不一致，请执行 `npm run api:doc`');
    process.exit(1);
  }
  console.log('[api:doc] ok');
} else {
  fs.mkdirSync(path.dirname(outPath), { recursive: true });
  fs.writeFileSync(outPath, next, 'utf-8');
  console.log('[api:doc] wrote docs/api/api-reference.md');
}
