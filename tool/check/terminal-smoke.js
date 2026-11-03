#!/usr/bin/env node
/**
 * 交互式终端（PTY）验收（SP3-10 二期）：
 *   1. 无 token / scope 不足 → 升级被拒（401 / 403）
 *   2. 正常会话：`ready` → 输入 `whoami` 有回显 → `resize` 不报错 → `close` 收 exit
 *   3. 会话结束即回收（进程退出、并发计数释放）
 *
 * 素材与平台无关：Windows 用 `whoami`，POSIX 用 `id -un`；只看「有非空输出」。
 * 用法：node tool/check/terminal-smoke.js
 */
'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

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
const WebSocket = require('ws');

process.env.COLANAS_LOG_FILE = '0';
process.chdir(root);

const results = [];
const check = (name, ok, detail) => results.push({ name, ok, detail: detail || '' });


/** 连一次 WS，收集协议消息；返回 { messages, closed } */
function connect(url, { timeoutMs = 10000 } = {}) {
  return new Promise((resolve) => {
    const ws = new WebSocket(url);
    const messages = [];
    let closed = null;

    const done = () => {
      try {
        ws.close();
      } catch {
        /* already closed */
      }
      resolve({ ws, messages, closed });
    };

    ws.on('message', (raw) => {
      try {
        messages.push(JSON.parse(String(raw)));
      } catch {
        /* ignore */
      }
    });
    ws.on('close', (code, reason) => {
      closed = { code, reason: String(reason || '') };
      resolve({ ws, messages, closed });
    });
    ws.on('unexpected-response', (_req, res) => {
      closed = { code: res.statusCode, reason: 'http' };
      resolve({ ws, messages, closed });
    });
    ws.on('error', (err) => {
      closed = { code: 0, reason: err.message };
      resolve({ ws, messages, closed });
    });
    setTimeout(done, timeoutMs);
  });
}

(async () => {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-terminal-'));
  process.env.COLANAS_DEV_TOKEN = '1';
  process.env.COLANAS_FILES_ROOT = path.join(dataDir, 'files');
  process.env.COLANAS_JWT_SECRET = 'test-secret-0123456789abcdef';

  const k = await startKernel({ dataDir, port: 0, listen: false });
  await k.app.listen({ port: 0, host: '127.0.0.1' });
  const port = k.app.server.address().port;
  const base = `http://127.0.0.1:${port}`;
  const wsBase = `ws://127.0.0.1:${port}/api/v1/system/terminal/ws`;

  const mkToken = async (sub, scopes) => {
    const res = await fetch(`${base}/api/v1/auth/dev-token`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ sub, scopes }),
    });
    return (await res.json()).token;
  };

  const writer = await mkToken('term-u1', ['system:write']);
  const reader = await mkToken('term-u2', ['system:read']);

  // 1. 无 token
  let r = await connect(`${wsBase}?cols=80&rows=24`, { timeoutMs: 4000 });
  check('no_token_401', r.closed && r.closed.code === 401, JSON.stringify(r.closed));

  // 2. scope 不足
  r = await connect(`${wsBase}?cols=80&rows=24&token=${reader}`, { timeoutMs: 4000 });
  check('missing_scope_403', r.closed && r.closed.code === 403, JSON.stringify(r.closed));

  // 3. 正常会话
  const session = await new Promise((resolve) => {
    const ws = new WebSocket(`${wsBase}?cols=80&rows=24&token=${writer}`);
    const messages = [];
    let settled = false;
    const finish = () => {
      if (settled) return;
      settled = true;
      try {
        ws.close();
      } catch {
        /* ignore */
      }
      resolve({ messages });
    };
    ws.on('message', (raw) => {
      const msg = JSON.parse(String(raw));
      messages.push(msg);
      if (msg.type === 'ready') {
        ws.send(JSON.stringify({ type: 'resize', cols: 100, rows: 30 }));
        const cmd = process.platform === 'win32' ? 'whoami\r' : 'id -un\r';
        ws.send(JSON.stringify({ type: 'input', data: cmd }));
        // 等 shell 把 banner 与命令结果都吐出来再关；只靠 data 事件会被 banner 抢先
        setTimeout(() => {
          try {
            ws.send(JSON.stringify({ type: 'close' }));
          } catch {
            /* 已关闭 */
          }
        }, 1800);
      }
      if (msg.type === 'exit') finish();
    });
    ws.on('error', finish);
    ws.on('close', finish);
    setTimeout(finish, 12000);
  });

  const ready = session.messages.find((m) => m.type === 'ready');
  const output = session.messages
    .filter((m) => m.type === 'data')
    .map((m) => String(m.data || ''))
    .join('')
    // 终端输出里的 CSI / OSC 转义：这里必须匹配控制字符
// eslint-disable-next-line no-control-regex
    .replace(/\x1b\[[0-9;?]*[a-zA-Z]/g, '')
    // eslint-disable-next-line no-control-regex
    .replace(/\x1b\][^\x07]*\x07/g, '')
    .trim();
  const exit = session.messages.find((m) => m.type === 'exit');

  check('session_ready', Boolean(ready && ready.shell), ready ? `shell=${ready.shell}` : 'no ready');
  check('session_echo', output.length > 0, `output=${JSON.stringify(output.slice(0, 40))}`);
  check('session_close', Boolean(exit), exit ? JSON.stringify(exit) : 'no exit');

  // 4. 会话回收：再开一个会话应立刻 ready（说明并发计数已释放）
  const again = await connect(`${wsBase}?cols=80&rows=24&token=${writer}`, { timeoutMs: 6000 });
  const readyAgain = again.messages.find((m) => m.type === 'ready');
  check('session_released', Boolean(readyAgain), readyAgain ? 'ready' : 'not ready');

  await k.app.close();
  fs.rmSync(dataDir, { recursive: true, force: true });

  for (const x of results) console.log(`${x.ok ? '[OK]  ' : '[FAIL]'} ${x.name.padEnd(20)} ${x.detail}`);
  const failed = results.filter((x) => !x.ok);
  console.log(`\n[terminal] ${results.length - failed.length}/${results.length} passed`);
  process.exit(failed.length ? 1 : 0);
})();