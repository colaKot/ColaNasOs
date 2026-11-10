#!/usr/bin/env node
/**
 * ColaNasOs MCP server（stdio JSON-RPC，只读工具）。
 *
 * 协议：MCP `2024-11-05`，按行分隔的 JSON-RPC 2.0（stdout 只写协议帧，日志一律走 stderr）。
 * 能力：`initialize` / `tools/list` / `tools/call` / `ping`，以及 `notifications/*`（无响应）。
 *
 * 访问内核用 HTTP + 只读 token：
 *   COLANAS_MCP_BASE_URL（默认 http://127.0.0.1:7788）
 *   COLANAS_MCP_TOKEN   （必填；由内核签发，建议只给 *:read scope）
 *
 * 只暴露读接口：MCP 客户端（编辑器 / Agent）不应该能建库、删文件或改用户。
 */
'use strict';

const http = require('node:http');

const PROTOCOL_VERSION = '2024-11-05';
const BASE = (process.env.COLANAS_MCP_BASE_URL || 'http://127.0.0.1:7788').replace(/\/+$/, '');
const TOKEN = process.env.COLANAS_MCP_TOKEN || '';
const TIMEOUT_MS = 15_000;

const send = (obj) => {
  if (process.stdout.writable) process.stdout.write(JSON.stringify(obj) + '\n');
};

const log = (msg) => {
  process.stderr.write(`[colanas-mcp] ${msg}\n`);
};

/** 只读 GET，返回解析后的 JSON；非 2xx 抛错并带上服务端 error 字段 */
function api(path, query = {}) {
  return new Promise((resolve, reject) => {
    const url = new URL(BASE + path);
    for (const [k, v] of Object.entries(query)) {
      if (v !== undefined && v !== null && v !== '') url.searchParams.set(k, String(v));
    }
    const req = http.request(
      url,
      {
        method: 'GET',
        headers: TOKEN ? { authorization: `Bearer ${TOKEN}` } : {},
        timeout: TIMEOUT_MS,
      },
      (res) => {
        const chunks = [];
        res.on('data', (c) => chunks.push(c));
        res.on('end', () => {
          const body = Buffer.concat(chunks).toString('utf8');
          if (res.statusCode >= 200 && res.statusCode < 300) {
            try {
              resolve(body ? JSON.parse(body) : null);
            } catch (e) {
              reject(new Error(`bad json from ${path}: ${e.message}`));
            }
            return;
          }
          let message = body;
          try {
            const parsed = JSON.parse(body);
            message = parsed.message || parsed.error || body;
          } catch {
            /* 保留原文 */
          }
          reject(new Error(`HTTP ${res.statusCode} ${path}: ${String(message).slice(0, 300)}`));
        });
      },
    );
    req.on('timeout', () => req.destroy(new Error('kernel request timeout')));
    req.on('error', reject);
    req.end();
  });
}

const num = (v, def) => {
  const n = Math.round(Number(v));
  return Number.isFinite(n) && n > 0 ? n : def;
};

const TOOLS = [
  {
    name: 'files_list',
    description: '列出 files 根内某个目录（相对路径），返回名称与是否为目录',
    inputSchema: {
      type: 'object',
      properties: {
        path: { type: 'string', description: '目录相对路径，缺省为根 /' },
        limit: { type: 'integer', minimum: 1, maximum: 200, description: '条数上限，默认 50' },
      },
    },
    handler: (args) =>
      api('/api/v1/files/list', { path: args.path || '/', limit: num(args.limit, 50) }),
  },
  {
    name: 'photo_timeline',
    description: '相册时间轴（按拍摄时间倒序）',
    inputSchema: {
      type: 'object',
      properties: {
        libraryId: { type: 'string', description: '只看某个相册库' },
        limit: { type: 'integer', minimum: 1, maximum: 100, description: '默认 20' },
      },
    },
    handler: (args) =>
      api('/api/v1/photo/timeline', { libraryId: args.libraryId, limit: num(args.limit, 20) }),
  },
  {
    name: 'video_list',
    description: '影视列表（可关键词搜索；series=none 只看影片）',
    inputSchema: {
      type: 'object',
      properties: {
        q: { type: 'string', description: '标题 / 路径关键词' },
        series: { type: 'string', description: 'none = 只看非剧集' },
        limit: { type: 'integer', minimum: 1, maximum: 100, description: '默认 20' },
      },
    },
    handler: (args) =>
      api('/api/v1/video/list', { q: args.q, series: args.series, limit: num(args.limit, 20) }),
  },
  {
    name: 'music_list',
    description: '音乐曲目列表（可关键词 / 艺术家 / 专辑过滤）',
    inputSchema: {
      type: 'object',
      properties: {
        q: { type: 'string', description: '标题 / 艺术家 / 专辑关键词' },
        artist: { type: 'string', description: '艺术家精确匹配' },
        album: { type: 'string', description: '专辑精确匹配' },
        limit: { type: 'integer', minimum: 1, maximum: 100, description: '默认 20' },
      },
    },
    handler: (args) =>
      api('/api/v1/music/list', {
        q: args.q,
        artist: args.artist,
        album: args.album,
        limit: num(args.limit, 20),
      }),
  },
  {
    name: 'system_monitor',
    description: '整机监控：CPU 采样、内存、磁盘、负载、运行时长',
    inputSchema: { type: 'object', properties: {} },
    handler: () => api('/api/v1/system/monitor'),
  },
  {
    name: 'media_libraries',
    description: '各媒体库概况（相册 / 影视 / 音乐）',
    inputSchema: { type: 'object', properties: {} },
    handler: async () => {
      const [photo, video, music] = await Promise.all([
        api('/api/v1/photo/libraries'),
        api('/api/v1/video/libraries'),
        api('/api/v1/music/libraries'),
      ]);
      return { photo: photo.items, video: video.items, music: music.items };
    },
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

  // 通知不需要响应
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
          serverInfo: { name: 'colanas-mcp', version: '1.0.0' },
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
          // 内核侧错误按 MCP 约定放 result.isError，客户端能读错误文本
          send({
            jsonrpc: '2.0',
            id,
            result: {
              content: [{ type: 'text', text: `调用失败：${String(e.message || e)}` }],
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
        handle(msg).catch((e) => {
          send({
            jsonrpc: '2.0',
            id: msg && msg.id,
            error: { code: -32603, message: String((e && e.message) || e) },
          });
        });
      } catch {
        send({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'parse error' } });
      }
    }
    idx = buf.indexOf('\n');
  }
});

process.stdin.on('end', () => process.exit(0));
log(`ready (base=${BASE}, token=${TOKEN ? 'set' : 'missing'})`);
