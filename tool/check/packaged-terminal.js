#!/usr/bin/env node
/**
 * 打包形态的交互式终端探针（SP3-10 / SP4-03）。
 *
 *   npm run pack
 *   npm run smoke:packaged-terminal
 *
 * 验证的是「安装包里的 node-pty 真的能从 asar.unpacked 加载、并开出 PTY」——
 * 构建与 verify 都发现不了这一类问题（native 模块路径 / 预编译架构）。
 *
 * 与 `smoke:packaged` 的区别：这里显式打开 `COLANAS_DEV_TOKEN=1` 以便签发
 * 测试令牌，因此不能与生产配置断言混跑。
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');

const root = path.join(__dirname, '..', '..');
const port = Number(process.env.PORT || 7801);
const base = `http://127.0.0.1:${port}`;
const wsBase = `ws://127.0.0.1:${port}/api/v1/system/terminal/ws`;
const workDir = path.join(root, '.devdata', 'pack-terminal');
const dataDir = path.join(workDir, 'data');
const userDataDir = path.join(workDir, 'user-data');
const traceFile = path.join(workDir, 'launch-trace.log');

const bin = path.join(root, 'dist_installer', 'win-unpacked', 'ColaNasOs.exe');
if (!fs.existsSync(bin)) {
  console.error('[smoke:packaged-terminal] 缺少打包产物，先执行 npm run pack');
  process.exit(1);
}

const WebSocket = require('ws');
const results = [];
const check = (name, ok, detail) => results.push({ name, ok, detail: detail || '' });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

fs.rmSync(workDir, { recursive: true, force: true });
fs.mkdirSync(workDir, { recursive: true });

const env = {
  ...process.env,
  PORT: String(port),
  COLANAS_DATA_DIR: dataDir,
  COLANAS_USER_DATA_DIR: userDataDir,
  COLANAS_LAUNCH_LOG: traceFile,
  COLANAS_DEV_TOKEN: '1',
  ELECTRON_ENABLE_LOGGING: '1',
};
delete env.ELECTRON_RUN_AS_NODE;

const child = spawn(bin, [], { cwd: path.dirname(bin), stdio: 'ignore', env });

function killTree() {
  spawnSync('taskkill', ['/PID', String(child.pid), '/T', '/F'], { stdio: 'ignore' });
}

async function waitHealth(timeoutMs = 45000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const res = await fetch(`${base}/health`, { signal: globalThis.AbortSignal.timeout(2000) });
      if (res.ok) return true;
    } catch {
      /* 还没起来 */
    }
    await sleep(500);
  }
  return false;
}

(async () => {
  const healthy = await waitHealth();
  check('kernel_health', healthy, healthy ? `${base}/health 200` : '未就绪');
  if (!healthy) return finish();

  const tokenRes = await fetch(`${base}/api/v1/auth/dev-token`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ sub: 'pack-term', scopes: ['system:write'] }),
  }).catch(() => null);
  const token = tokenRes && tokenRes.ok ? (await tokenRes.json()).token : null;
  check('dev_token', Boolean(token), token ? 'ok' : `status=${tokenRes && tokenRes.status}`);
  if (!token) return finish();

  const session = await new Promise((resolve) => {
    const ws = new WebSocket(`${wsBase}?cols=80&rows=24&token=${token}`);
    const messages = [];
    let settled = false;
    const done = () => {
      if (settled) return;
      settled = true;
      try {
        ws.close();
      } catch {
        /* ignore */
      }
      resolve(messages);
    };
    ws.on('message', (raw) => {
      const msg = JSON.parse(String(raw));
      messages.push(msg);
      if (msg.type === 'ready') {
        const cmd = process.platform === 'win32' ? 'whoami\r' : 'id -un\r';
        ws.send(JSON.stringify({ type: 'input', data: cmd }));
        setTimeout(() => {
          try {
            ws.send(JSON.stringify({ type: 'close' }));
          } catch {
            /* ignore */
          }
        }, 1800);
      }
      if (msg.type === 'exit') done();
    });
    ws.on('error', done);
    ws.on('close', done);
    setTimeout(done, 12000);
  });

  const ready = session.find((m) => m.type === 'ready');
  const output = session
    .filter((m) => m.type === 'data')
    .map((m) => String(m.data || ''))

    .join('')
    // eslint-disable-next-line no-control-regex
    .replace(/\x1b\[[0-9;?]*[a-zA-Z]/g, '')
    .trim();
  const errorMsg = session.find((m) => m.type === 'error');

  check('pty_ready', Boolean(ready && ready.shell), ready ? `shell=${ready.shell}` : 'no ready');
  check('pty_output', output.length > 0, output ? JSON.stringify(output.slice(0, 50)) : 'empty');
  check(
    'pty_no_error',
    !errorMsg,
    errorMsg ? String(errorMsg.message).slice(0, 120) : 'ok',
  );

  finish();
})();

function finish() {
  killTree();
  const failed = results.filter((r) => !r.ok);
  for (const r of results) console.log(`${r.ok ? '[OK]  ' : '[FAIL]'} ${r.name.padEnd(16)} ${r.detail}`);
  if (failed.length) {
    console.error(`[smoke:packaged-terminal] 日志：${path.relative(root, traceFile)}`);
    if (fs.existsSync(traceFile)) console.error(fs.readFileSync(traceFile, 'utf-8').trim());
  }
  console.log(`\n[smoke:packaged-terminal] ${results.length - failed.length}/${results.length} passed`);
  process.exit(failed.length ? 1 : 0);
}