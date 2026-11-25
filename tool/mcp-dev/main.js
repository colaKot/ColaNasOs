#!/usr/bin/env node
/**
 * ColaNasOs 工程台 MCP server（stdio JSON-RPC，只读本地仓库）。
 *
 * 与产品侧 `sidecars/mcp` 的区别：
 * - 只在**源码仓库**里跑（`npm run mcp:dev`），不进安装包（打包时 tool/ 只带两个下载脚本）；
 * - 不连内核、不要 token，直接读 contracts/ + docs/ + 各端 pubspec；
 * - 只暴露「查工程信息」的只读工具，不做任何写操作。
 *
 * 协议：MCP 2024-11-05，按行分隔 JSON-RPC 2.0；stdout 只写协议帧，日志一律走 stderr。
 * 工具清单以 contracts/mcp-tools.json 的 dev server 为准，由 tool/check/mcp-tools.js 校验。
 */
'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');

const PROTOCOL_VERSION = '2024-11-05';
const ROOT = path.join(__dirname, '..', '..');

const send = (obj) => {
  if (process.stdout.writable) process.stdout.write(JSON.stringify(obj) + '\n');
};
const log = (msg) => process.stderr.write(`[colanas-dev] ${msg}\n`);

const SKIP_DIRS = new Set([
  'node_modules',
  'dist',
  'dist_release',
  'build',
  '.git',
  '.devdata',
  'vendor',
  '.dart_tool',
]);
const TEXT_EXT = new Set(['.md', '.txt']);

/** 递归收集文本文件（.md / .txt），跳过构建产物与依赖目录 */
function walkText(absDir, out = []) {
  let entries;
  try {
    entries = fs.readdirSync(absDir, { withFileTypes: true });
  } catch {
    return out;
  }
  for (const e of entries) {
    const p = path.join(absDir, e.name);
    if (e.isDirectory()) {
      if (SKIP_DIRS.has(e.name)) continue;
      walkText(p, out);
    } else if (TEXT_EXT.has(path.extname(e.name).toLowerCase())) {
      out.push(p);
    }
  }
  return out;
}

const readJson = (rel) => JSON.parse(fs.readFileSync(path.join(ROOT, rel), 'utf8'));
const relOf = (p) => path.relative(ROOT, p).replace(/\\/g, '/');

function docSearch(args) {
  const q = String(args.q || '').trim();
  if (!q) throw new Error('缺少 q（搜索关键词）');
  const limit = Math.min(Math.max(Number(args.limit) || 30, 1), 100);
  const scope = String(args.scope || 'all');
  const rootsByScope = {
    docs: ['docs'],
    wiki: ['docs/wiki'],
    agents: ['AGENTS.md', 'README.md', 'CLAUDE.md'],
    all: ['docs', 'AGENTS.md', 'README.md', 'CLAUDE.md'],
  };
  const roots = rootsByScope[scope];
  if (!roots) throw new Error(`scope 只能是 ${Object.keys(rootsByScope).join(' / ')}`);

  const needle = q.toLowerCase();
  const hits = [];
  for (const rel of roots) {
    if (hits.length >= limit) break;
    const abs = path.join(ROOT, rel);
    if (!fs.existsSync(abs)) continue;
    const files = fs.statSync(abs).isDirectory() ? walkText(abs) : [abs];
    for (const f of files) {
      if (hits.length >= limit) break;
      let lines;
      try {
        lines = fs.readFileSync(f, 'utf8').split('\n');
      } catch {
        continue;
      }
      for (let i = 0; i < lines.length && hits.length < limit; i += 1) {
        if (lines[i].toLowerCase().includes(needle)) {
          hits.push({ file: relOf(f), line: i + 1, text: lines[i].trim().slice(0, 240) });
        }
      }
    }
  }
  return { query: q, scope, count: hits.length, truncated: hits.length >= limit, items: hits };
}

function contractLookup(args) {
  const kind = String(args.kind || '').trim().toLowerCase();
  const q = String(args.q || '').trim().toLowerCase();
  const has = (s) => !q || String(s).toLowerCase().includes(q);

  if (kind === 'error') {
    const m = readJson('contracts/errors.json');
    const items = Object.entries(m.codes || {})
      .filter(([k, v]) => has(k) || has(v.message))
      .map(([name, v]) => ({ name, status: v.status, message: v.message }));
    return { kind, count: items.length, items };
  }
  if (kind === 'api') {
    const o = readJson('contracts/openapi.json');
    const items = [];
    for (const [p, ops] of Object.entries(o.paths || {})) {
      if (!has(p)) continue;
      for (const [method, op] of Object.entries(ops)) {
        if (!['get', 'post', 'put', 'patch', 'delete'].includes(method)) continue;
        items.push({
          method: method.toUpperCase(),
          path: p,
          operationId: op.operationId,
          summary: op.summary,
          tags: op.tags,
        });
        if (items.length >= 80) break;
      }
      if (items.length >= 80) break;
    }
    return { kind, count: items.length, truncated: items.length >= 80, items };
  }
  if (kind === 'i18n') {
    const m = readJson('contracts/i18n.json');
    const names = Object.keys(m.keys || {});
    const items = names.filter(has).slice(0, 60);
    return { kind, total: names.length, count: items.length, items };
  }
  if (kind === 'app') {
    const m = readJson('contracts/apps.json');
    const items = (m.apps || [])
      .filter((a) => has(a.id) || has(a.route) || has(a.nameKey))
      .map((a) => ({ id: a.id, route: a.route, nameKey: a.nameKey, available: a.available, group: a.group }));
    return { kind, count: items.length, items };
  }
  if (kind === 'glossary') {
    const m = readJson('contracts/glossary.json');
    const items = (m.terms || [])
      .filter((t) => Object.keys(t).some((k) => has(t[k])))
      .slice(0, 60);
    return { kind, count: items.length, items };
  }
  throw new Error('kind 只能是 error / api / i18n / app / glossary');
}

function apiEndpoint(args) {
  const p = String(args.path || '').trim();
  const opId = String(args.operationId || '').trim();
  if (!p && !opId) throw new Error('需要 path 或 operationId');
  const o = readJson('contracts/openapi.json');
  const items = [];
  for (const [pth, ops] of Object.entries(o.paths || {})) {
    for (const [method, op] of Object.entries(ops)) {
      if (!['get', 'post', 'put', 'patch', 'delete'].includes(method)) continue;
      const hit = (opId && op.operationId === opId) || (p && (pth === p || pth.startsWith(p)));
      if (!hit) continue;
      items.push({
        method: method.toUpperCase(),
        path: pth,
        operationId: op.operationId,
        summary: op.summary,
        tags: op.tags,
        security: op.security || [],
        parameters: (op.parameters || []).map((x) => x.name),
        hasRequestBody: !!op.requestBody,
        responses: Object.keys(op.responses || {}),
      });
    }
  }
  return { count: items.length, items };
}

function pubspecVersion(rel) {
  try {
    const src = fs.readFileSync(path.join(ROOT, rel), 'utf8');
    const m = /^version:\s*([^\s#]+)/m.exec(src);
    return m ? m[1] : null;
  } catch {
    return null;
  }
}

function listDirs(rel) {
  try {
    return fs
      .readdirSync(path.join(ROOT, rel), { withFileTypes: true })
      .filter((e) => e.isDirectory())
      .map((e) => e.name);
  } catch {
    return [];
  }
}

function countJson(rel, pick) {
  try {
    return pick(readJson(rel));
  } catch {
    return null;
  }
}

function projectFacts() {
  const pkg = readJson('package.json');

  const apps = [];
  for (const dir of listDirs('apps')) {
    const version = pubspecVersion(`apps/${dir}/pubspec.yaml`);
    if (version) apps.push({ dir, version });
  }

  const contracts = {
    errors: countJson('contracts/errors.json', (m) => Object.keys(m.codes || {}).length),
    apiPaths: countJson('contracts/openapi.json', (m) => Object.keys(m.paths || {}).length),
    i18nKeys: countJson('contracts/i18n.json', (m) => Object.keys(m.keys || {}).length),
    apps: countJson('contracts/apps.json', (m) => (m.apps || []).length),
    glossary: countJson('contracts/glossary.json', (m) => (m.terms || []).length),
  };

  let mcp = null;
  try {
    const servers = Object.entries(readJson('contracts/mcp-tools.json').servers || {});
    mcp = { servers: servers.length, tools: servers.reduce((n, [, s]) => n + (s.tools || []).length, 0) };
  } catch {
    /* ignore */
  }

  return {
    version: pkg.version,
    apps,
    modules: listDirs('src/modules'),
    contracts,
    mcp,
    docs: {
      textFiles: walkText(path.join(ROOT, 'docs')).length,
      wikiPages: (() => {
        try {
          return fs.readdirSync(path.join(ROOT, 'docs', 'wiki')).filter((f) => f.endsWith('.md')).length;
        } catch {
          return 0;
        }
      })(),
    },
  };
}

// ---------------------------------------------------------------- 诊断（只读）

const DATA_DIR =
  process.env.COLANAS_DATA_DIR ||
  path.join(process.env.APPDATA || path.join(os.homedir(), 'AppData', 'Roaming'), 'colanas_os_server');
const LOG_DIR = path.join(DATA_DIR, 'logs');

const PINO_LEVEL = { 10: 'trace', 20: 'debug', 30: 'info', 40: 'warn', 50: 'error', 60: 'fatal' };
const MIN_LEVEL = { all: 0, info: 30, warn: 40, error: 50 };

/** 读文件末尾 maxBytes，避免把几十 MB 的轮转日志整个读进来 */
function readTail(abs, maxBytes) {
  const stat = fs.statSync(abs);
  const start = Math.max(0, stat.size - maxBytes);
  const len = stat.size - start;
  if (len <= 0) return '';
  const buf = Buffer.alloc(len);
  const fd = fs.openSync(abs, 'r');
  try {
    fs.readSync(fd, buf, 0, len, start);
  } finally {
    fs.closeSync(fd);
  }
  const text = buf.toString('utf8');
  if (start <= 0) return text;
  const nl = text.indexOf('\n');
  return nl >= 0 ? text.slice(nl + 1) : text;
}

function logQuery(args) {
  const file = String(args.file || 'kernel.log').trim();
  if (!/^(kernel(-console)?\.log(\.\d+)?|shell\.log)$/.test(file)) {
    throw new Error('file 只允许 kernel.log / kernel-console.log / shell.log（可带 .N 轮转）');
  }
  const abs = path.join(LOG_DIR, file);
  if (!fs.existsSync(abs)) {
    return {
      file,
      path: abs,
      exists: false,
      hint: '未找到日志文件（确认服务端跑过且 COLANAS_DATA_DIR 正确）',
      items: [],
    };
  }
  const level = String(args.level || 'all').toLowerCase();
  if (!(level in MIN_LEVEL)) throw new Error('level 只能是 all / info / warn / error');
  const minLevel = MIN_LEVEL[level];
  const q = String(args.q || '').trim().toLowerCase();
  const limit = Math.min(Math.max(Number(args.limit) || 50, 1), 200);

  const lines = readTail(abs, 1024 * 1024).split('\n');
  const picked = [];
  for (let i = lines.length - 1; i >= 0 && picked.length < limit; i -= 1) {
    const raw = lines[i];
    if (!raw.trim()) continue;
    if (q && !raw.toLowerCase().includes(q)) continue;
    let levelNum = null;
    let entry;
    try {
      const o = JSON.parse(raw);
      levelNum = typeof o.level === 'number' ? o.level : null;
      entry = {
        time: o.time ? new Date(o.time).toISOString() : null,
        level: PINO_LEVEL[o.level] || o.level,
        msg: o.msg,
        raw: raw.length > 2000 ? raw.slice(0, 2000) + '…' : raw,
      };
    } catch {
      entry = { raw: raw.length > 2000 ? raw.slice(0, 2000) + '…' : raw };
    }
    if (minLevel > 0 && (levelNum == null || levelNum < minLevel)) continue;
    picked.push(entry);
  }
  picked.reverse();
  return { file, path: abs, level, query: q || null, count: picked.length, items: picked };
}

function diagDigest(args) {
  const topSlow = Math.min(Math.max(Number(args.topSlow) || 8, 1), 50);
  const p = path.join(ROOT, 'dist', 'verify-report.json');
  if (!fs.existsSync(p)) {
    return { exists: false, hint: '还没有 dist/verify-report.json，先跑一次 npm run verify' };
  }
  const r = JSON.parse(fs.readFileSync(p, 'utf8'));
  const steps = Array.isArray(r.steps) ? r.steps : [];
  const failed = steps.filter((s) => !s.ok);
  return {
    exists: true,
    generatedAt: r.generatedAt,
    mode: r.mode,
    totalMs: r.totalMs,
    planned: r.planned,
    passed: r.passed,
    failed: r.failed,
    ok: (r.failed || 0) === 0,
    failedSteps: failed.map((s) => ({ script: s.script, label: s.label, ms: s.ms })),
    slowest: steps.slice(0, topSlow).map((s) => ({ script: s.script, label: s.label, ok: s.ok, ms: s.ms })),
  };
}

const STATIC_CHECKS = [
  'errors.check',
  'mcp.tools.check',
  'gen:errors.check',
  'gen:apps.check',
  'gen:i18n.check',
  'gen:locales.check',
  'version:check',
  'app-nav.check',
  'sbom.check',
  'i18n.keys.check',
  'compat.i18n.check',
  'scope.catalog.check',
  'caps.check',
];

function runScript(script, timeoutMs) {
  return new Promise((resolve) => {
    const t0 = Date.now();
    let output = '';
    let child;
    try {
      child = spawn(`npm run -s ${script}`, { cwd: ROOT, shell: true, windowsHide: true });
    } catch (e) {
      resolve({ script, ok: false, ms: 0, tail: String(e) });
      return;
    }
    const timer = setTimeout(() => {
      try {
        child.kill();
      } catch {
        /* ignore */
      }
    }, timeoutMs);
    child.stdout.on('data', (d) => (output += d));
    child.stderr.on('data', (d) => (output += d));
    child.on('error', (e) => (output += String(e)));
    child.on('close', (code) => {
      clearTimeout(timer);
      const tail = output.trim();
      resolve({ script, ok: code === 0, ms: Date.now() - t0, tail: tail.length > 600 ? tail.slice(-600) : tail });
    });
  });
}

async function diagStatic(args) {
  const checks = Array.isArray(args.checks) && args.checks.length > 0 ? args.checks.map(String) : STATIC_CHECKS;
  const allowed = new Set(STATIC_CHECKS);
  const rejected = checks.filter((c) => !allowed.has(c));
  if (rejected.length > 0) {
    throw new Error(`只允许这些轻量只读检查：${STATIC_CHECKS.join(', ')}；不支持的：${rejected.join(', ')}`);
  }
  const timeoutMs = Math.min(Math.max(Number(args.timeoutMs) || 20000, 3000), 120000);
  const results = [];
  for (const c of checks) results.push(await runScript(c, timeoutMs));
  const failed = results.filter((r) => !r.ok);
  return { ok: failed.length === 0, total: results.length, failed: failed.length, results };
}

const TOOLS = [
  {
    name: 'doc_search',
    description: '在 docs/ 与 AGENTS.md 等工程文档里按关键词检索，返回文件:行号 + 片段',
    inputSchema: {
      type: 'object',
      properties: {
        q: { type: 'string', description: '关键词（大小写不敏感）' },
        scope: {
          type: 'string',
          enum: ['all', 'docs', 'wiki', 'agents'],
          description: '检索范围，默认 all',
        },
        limit: { type: 'integer', minimum: 1, maximum: 100, description: '条数上限，默认 30' },
      },
      required: ['q'],
    },
    handler: docSearch,
  },
  {
    name: 'contract_lookup',
    description: '查契约：error 错误码 / api 路由 / i18n 键 / app 应用 / glossary 术语',
    inputSchema: {
      type: 'object',
      properties: {
        kind: { type: 'string', enum: ['error', 'api', 'i18n', 'app', 'glossary'] },
        q: { type: 'string', description: '关键词；留空返回全部（部分类型有上限）' },
      },
      required: ['kind'],
    },
    handler: contractLookup,
  },
  {
    name: 'api_endpoint',
    description: '按 path 或 operationId 查端点：method / 权限 / 参数 / 响应码',
    inputSchema: {
      type: 'object',
      properties: {
        path: { type: 'string', description: '路径（精确或前缀），如 /api/v1/photo/timeline' },
        operationId: { type: 'string', description: 'operationId，如 photoTimeline' },
      },
    },
    handler: apiEndpoint,
  },
  {
    name: 'project_facts',
    description: '工程元信息：版本 / 各端版本 / 模块清单 / 契约计数 / MCP 工具数 / 文档数',
    inputSchema: { type: 'object', properties: {} },
    handler: projectFacts,
  },
  {
    name: 'diag_digest',
    description: '读 dist/verify-report.json，返回结构化摘要：是否通过、失败步骤、最慢步骤',
    inputSchema: {
      type: 'object',
      properties: {
        topSlow: { type: 'integer', minimum: 1, maximum: 50, description: '最慢步骤条数，默认 8' },
      },
    },
    handler: diagDigest,
  },
  {
    name: 'diag_static',
    description: '跑一组轻量只读检查（错误码 / 契约一致性 / i18n / sbom 等），不 build、不跑 smoke',
    inputSchema: {
      type: 'object',
      properties: {
        checks: {
          type: 'array',
          items: { type: 'string' },
          description: '要跑的检查（缺省用白名单）；传不支持的名字会被拒绝',
        },
        timeoutMs: {
          type: 'integer',
          minimum: 3000,
          maximum: 120000,
          description: '单个检查超时，默认 20000',
        },
      },
    },
    handler: diagStatic,
  },
  {
    name: 'log_query',
    description: '查内核日志（%APPDATA%/colanas_os_server/logs），按级别 / 关键字过滤，只读尾部',
    inputSchema: {
      type: 'object',
      properties: {
        file: {
          type: 'string',
          description: 'kernel.log（默认）/ kernel-console.log / shell.log，可带 .N 轮转',
        },
        level: { type: 'string', enum: ['all', 'info', 'warn', 'error'], description: '最低级别，默认 all' },
        q: { type: 'string', description: '关键字（整行包含，大小写不敏感）' },
        limit: { type: 'integer', minimum: 1, maximum: 200, description: '返回条数，默认 50' },
      },
    },
    handler: logQuery,
  },
];

const TOOL_MAP = new Map(TOOLS.map((t) => [t.name, t]));

async function handleToolsCall(msg) {
  const name = msg.params && msg.params.name;
  const args = (msg.params && msg.params.arguments) || {};
  const tool = TOOL_MAP.get(name);
  if (!tool) {
    throw Object.assign(new Error(`unknown tool: ${name}`), { rpcCode: -32602, rpc: true });
  }
  const result = await tool.handler(args || {});
  const text = JSON.stringify(result ?? null);
  return {
    content: [{ type: 'text', text: text.length > 200_000 ? text.slice(0, 200_000) + '…' : text }],
    isError: false,
  };
}

async function handle(msg) {
  const id = msg.id;
  const method = msg.method;

  if (id === undefined || id === null) {
    log(`notification: ${method}`);
    return;
  }

  switch (method) {
    case 'initialize':
      send({
        jsonrpc: '2.0',
        id,
        result: {
          protocolVersion: PROTOCOL_VERSION,
          capabilities: { tools: { listChanged: false } },
          serverInfo: { name: 'colanas-dev', version: '1.0.0' },
        },
      });
      return;
    case 'ping':
      send({ jsonrpc: '2.0', id, result: {} });
      return;
    case 'tools/list':
      send({
        jsonrpc: '2.0',
        id,
        result: {
          tools: TOOLS.map((t) => ({
            name: t.name,
            description: t.description,
            inputSchema: t.inputSchema,
          })),
        },
      });
      return;
    case 'tools/call':
      try {
        send({ jsonrpc: '2.0', id, result: await handleToolsCall(msg) });
      } catch (e) {
        if (e && e.rpc) {
          send({ jsonrpc: '2.0', id, error: { code: e.rpcCode, message: e.message } });
        } else {
          send({
            jsonrpc: '2.0',
            id,
            result: {
              content: [{ type: 'text', text: `调用失败：${String((e && e.message) || e)}` }],
              isError: true,
            },
          });
        }
      }
      return;
    default:
      send({ jsonrpc: '2.0', id, error: { code: -32601, message: `method not found: ${method}` } });
  }
}

let buf = '';
let pending = 0;
let stdinEnded = false;

/** stdin 关了也不能立刻退：diag_static 这类慢工具还在跑，退早了响应就丢了 */
function maybeExit() {
  if (stdinEnded && pending === 0) process.exit(0);
}

process.stdin.setEncoding('utf8');
process.stdin.on('data', (chunk) => {
  buf += chunk;
  let idx = buf.indexOf('\n');
  while (idx >= 0) {
    const line = buf.slice(0, idx).trim();
    buf = buf.slice(idx + 1);
    if (line) {
      try {
        const msg = JSON.parse(line);
        pending += 1;
        handle(msg)
          .catch((e) =>
            send({
              jsonrpc: '2.0',
              id: msg && msg.id,
              error: { code: -32603, message: String((e && e.message) || e) },
            }),
          )
          .finally(() => {
            pending -= 1;
            maybeExit();
          });
      } catch {
        send({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'parse error' } });
      }
    }
    idx = buf.indexOf('\n');
  }
});
process.stdin.on('end', () => {
  stdinEnded = true;
  maybeExit();
});
log(`ready (root=${ROOT})`);
