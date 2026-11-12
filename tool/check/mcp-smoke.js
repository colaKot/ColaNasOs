#!/usr/bin/env node
/**
 * MCP server 验收（sidecars/mcp）：stdio JSON-RPC 握手 / 工具清单 / 只读调用 / 错误处理。
 *
 * 走真实内核 HTTP：起内核（随机端口）→ 发只读 token → spawn `sidecars/mcp/main.js`
 * → 按行收发 JSON-RPC，断言工具结果与错误码。
 *
 * 用法：node tool/check/mcp-smoke.js（Electron 自举）
 */
'use strict';

const path = require('node:path');
const fs = require('node:fs');
const os = require('node:os');
const { spawn, spawnSync } = require('node:child_process');

if (!process.versions.electron) {
  const exe = path.join(
    process.cwd(),
    'node_modules',
    'electron',
    'dist',
    process.platform === 'win32' ? 'electron.exe' : 'electron',
  );
  if (!fs.existsSync(exe)) {
    console.error('[FATAL] 找不到 electron，请先 npm install');
    process.exit(2);
  }
  const r = spawnSync(exe, [__filename], {
    stdio: 'inherit',
    env: Object.assign({}, process.env, { ELECTRON_RUN_AS_NODE: '1' }),
  });
  process.exit(typeof r.status === 'number' ? r.status : 1);
}

const root = path.join(__dirname, '..', '..');
const { startKernel } = require(path.join(root, 'dist', 'kernel', 'index'));

// 测试环境不落盘日志：临时目录在 app.close() 后立刻删除，异步日志句柄会触发 ENOTEMPTY
process.env.COLANAS_LOG_FILE = '0';

process.chdir(root);

/** 启动一个 MCP 子进程，返回 { call(method, params), stop() } */
function startMcp(baseUrl, token) {
  const child = spawn(process.execPath, [path.join(root, 'sidecars', 'mcp', 'main.js')], {
    env: Object.assign({}, process.env, {
      ELECTRON_RUN_AS_NODE: '1',
      COLANAS_MCP_BASE_URL: baseUrl,
      COLANAS_MCP_TOKEN: token || '',
    }),
    stdio: ['pipe', 'pipe', 'pipe'],
  });

  let nextId = 1;
  const pending = new Map();
  let buf = '';
  child.stdout.setEncoding('utf8');
  child.stdout.on('data', (chunk) => {
    buf += chunk;
    let idx = buf.indexOf('\n');
    while (idx >= 0) {
      const line = buf.slice(0, idx).trim();
      buf = buf.slice(idx + 1);
      if (line) {
        try {
          const msg = JSON.parse(line);
          const p = pending.get(msg.id);
          if (p) {
            pending.delete(msg.id);
            p(msg);
          }
        } catch {
          /* 忽略非协议行 */
        }
      }
      idx = buf.indexOf('\n');
    }
  });
  child.stderr.resume();

  const call = (method, params) =>
    new Promise((resolve, reject) => {
      const id = nextId++;
      const timer = setTimeout(() => {
        pending.delete(id);
        reject(new Error(`mcp timeout: ${method}`));
      }, 20_000);
      pending.set(id, (msg) => {
        clearTimeout(timer);
        resolve(msg);
      });
      child.stdin.write(
        JSON.stringify({ jsonrpc: '2.0', id, method, params: params || {} }) + '\n',
      );
    });

  return {
    call,
    notify: (method) => child.stdin.write(JSON.stringify({ jsonrpc: '2.0', method }) + '\n'),
    stop: () => {
      try {
        child.stdin.end();
        child.kill();
      } catch {
        /* 已退出 */
      }
    },
  };
}

(async () => {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-mcp-'));
  const filesRoot = path.join(dataDir, 'files');
  fs.mkdirSync(path.join(filesRoot, 'docs'), { recursive: true });
  fs.writeFileSync(path.join(filesRoot, 'seed.txt'), 'mcp seed');
  fs.writeFileSync(path.join(filesRoot, 'docs', 'note.md'), '# note');

  process.env.COLANAS_DEV_TOKEN = '1';
  process.env.COLANAS_JWT_SECRET = 'test-secret-0123456789abcdef';
  process.env.COLANAS_FILES_ROOT = filesRoot;

  const k = await startKernel({ dataDir, port: 0 });
  await k.app.ready();
  const port = k.app.server.address().port;
  const base = `http://127.0.0.1:${port}`;

  const results = [];
  const check = (name, ok, detail) => results.push({ name, ok, detail: detail || '' });

  const readScopes = [
    'files:read',
    'photo:read',
    'video:read',
    'music:read',
    'system:read',
  ];
  const token = (
    await k.app.inject({
      method: 'POST',
      url: '/api/v1/auth/dev-token',
      payload: { sub: 'mcp', scopes: readScopes },
    })
  ).json().token;

  // 路径 ACL 默认拒绝（用户 2026-11-11）：没授权目录的账号列不出文件根。
  // 这里验的是 MCP 工具调用形态，不验授权，所以显式授权文件根。
  await k.config.set('accessPolicy.mcp', {
    apps: null,
    paths: [{ path: '/', actions: ['view', 'download', 'update', 'delete', 'upload'] }],
  });

  const mcp = startMcp(base, token);
  try {
    // ---- 握手 ----
    let r = await mcp.call('initialize', {
      protocolVersion: '2024-11-05',
      capabilities: {},
      clientInfo: { name: 'smoke', version: '1.0.0' },
    });
    check(
      'initialize',
      r.result &&
        r.result.protocolVersion === '2024-11-05' &&
        r.result.serverInfo.name === 'colanas-mcp',
      JSON.stringify(r.result && r.result.serverInfo),
    );
    mcp.notify('notifications/initialized');

    r = await mcp.call('ping');
    check('ping', r.result !== undefined && !r.error, JSON.stringify(r.error || {}));

    // ---- 工具清单 ----
    r = await mcp.call('tools/list');
    const tools = (r.result && r.result.tools) || [];
    const names = tools.map((t) => t.name);
    // 以 sidecars/mcp/main.js 实际注册的工具为准：多一个少一个都要红，
    // 避免以后增删工具时这条静默通过。
    const expectedTools = [
      'files_list',
      'photo_timeline',
      'video_list',
      'music_list',
      'system_monitor',
      'media_libraries',
    ];
    check(
      'tools_list',
      [...names].sort().join(',') === [...expectedTools].sort().join(','),
      names.join(','),
    );
    check(
      'tools_count',
      tools.length === expectedTools.length,
      `count=${tools.length} expected=${expectedTools.length}`,
    );
    check(
      'tools_schema',
      tools.every((t) => t.inputSchema && t.inputSchema.type === 'object'),
      'all object schemas',
    );

    // ---- 只读调用 ----
    r = await mcp.call('tools/call', { name: 'files_list', arguments: { path: '/' } });
    const filesText =
      r.result && r.result.content && r.result.content[0] && r.result.content[0].text;
    let filesJson = null;
    try {
      filesJson = JSON.parse(filesText);
    } catch {
      /* 失败时 filesJson 保持 null */
    }
    check(
      'call_files_list',
      !r.result.isError &&
        filesJson &&
        Array.isArray(filesJson.items) &&
        filesJson.items.some((x) => x.name === 'seed.txt'),
      String(filesText).slice(0, 80),
    );

    r = await mcp.call('tools/call', { name: 'files_list', arguments: { path: 'docs' } });
    const docsText = r.result.content[0].text;
    check('call_files_list_subdir', docsText.includes('note.md'), docsText.slice(0, 80));

    r = await mcp.call('tools/call', { name: 'system_monitor', arguments: {} });
    const monitor = JSON.parse(r.result.content[0].text);
    check(
      'call_system_monitor',
      Number(monitor.uptimeSec ?? 0) > 0 && ('memory' in monitor || 'cpu' in monitor),
      'uptime=' + monitor.uptimeSec,
    );

    r = await mcp.call('tools/call', { name: 'media_libraries', arguments: {} });
    const libs = JSON.parse(r.result.content[0].text);
    check(
      'call_media_libraries',
      ['photo', 'video', 'music'].every((key) => Array.isArray(libs[key])),
      Object.keys(libs).join(','),
    );

    // ---- 错误处理 ----
    r = await mcp.call('tools/call', { name: 'nope', arguments: {} });
    check('unknown_tool', r.error && r.error.code === -32602, JSON.stringify(r.error));

    r = await mcp.call('resources/list');
    check('unknown_method', r.error && r.error.code === -32601, JSON.stringify(r.error));
  } finally {
    mcp.stop();
  }

  // ---- 无 token：内核 401 应作为 isError 结果返回 ----
  const anon = startMcp(base, '');
  try {
    const r = await anon.call('tools/call', { name: 'files_list', arguments: { path: '/' } });
    const text =
      (r.result && r.result.content && r.result.content[0] && r.result.content[0].text) || '';
    check(
      'no_token_isError',
      Boolean(r.result && r.result.isError) && text.includes('401'),
      text.slice(0, 80),
    );
  } finally {
    anon.stop();
  }

  await k.app.close();
  try { fs.rmSync(dataDir, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 }); } catch { /* 句柄释放有延迟 */ }

  let failed = 0;
  for (const x of results) {
    console.log(`${x.ok ? '[OK]  ' : '[FAIL]'} ${x.name.padEnd(26)} ${x.detail}`);
    if (!x.ok) failed++;
  }
  console.log(`[summary] ${results.length - failed}/${results.length} passed`);
  process.exit(failed ? 1 : 0);
})().catch((e) => {
  console.error('[FATAL]', e);
  process.exit(1);
});
