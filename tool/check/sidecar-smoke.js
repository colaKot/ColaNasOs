#!/usr/bin/env node
/**
 * Sidecar 守护验收（SP2-01）：启动探测 / invoke / 事件 / 错误 / 超时 / 崩溃重启 / 优雅退出。
 * 纯 Node 运行（不依赖 Electron ABI）。
 *
 * 用法：node tool/check/sidecar-smoke.js
 */
'use strict';

const path = require('node:path');

const root = path.join(__dirname, '..', '..');
const { SidecarSupervisor } = require(path.join(root, 'dist', 'kernel', 'sidecar', 'supervisor'));

const results = [];
const check = (name, ok, detail) => results.push({ name, ok, detail: detail || '' });

function alive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

(async () => {
  const sup = new SidecarSupervisor({
    name: 'echo',
    command: process.execPath,
    args: [path.join(root, 'sidecars', 'echo', 'main.js')],
    requestTimeoutMs: 2_000,
    heartbeatMs: 1_000,
    maxRestarts: 3,
    startTimeoutMs: 5_000,
    stopGraceMs: 3_000,
    log: () => {},
  });

  await sup.start();
  check('start_ready', sup.state === 'ready' && typeof sup.pid === 'number', `pid=${sup.pid}`);

  const echoed = await sup.request('echo', { a: 1, b: 'x' });
  check('invoke_echo', echoed && echoed.a === 1 && echoed.b === 'x', JSON.stringify(echoed));

  let eventSeen = null;
  sup.on('event', (name, data) => {
    eventSeen = { name, data };
  });
  await sup.request('emit');
  await new Promise((r) => setTimeout(r, 50));
  check(
    'event_frame',
    eventSeen && eventSeen.name === 'progress' && eventSeen.data.pct === 50,
    JSON.stringify(eventSeen),
  );

  let failCode = null;
  try {
    await sup.request('fail');
  } catch (err) {
    failCode = err.code;
  }
  check('error_frame', failCode === 'E_FAIL', 'code=' + failCode);

  let timeoutCode = null;
  try {
    await sup.request('sleep', { ms: 600 }, 120);
  } catch (err) {
    timeoutCode = err.code;
  }
  check('timeout', timeoutCode === 'E_TIMEOUT', 'code=' + timeoutCode);

  // 崩溃 → 自动重启
  const pidBefore = sup.pid;
  const readyAgain = new Promise((resolve) => sup.once('ready', resolve));
  process.kill(pidBefore, 'SIGKILL');
  await Promise.race([
    readyAgain,
    new Promise((_, rej) => setTimeout(() => rej(new Error('restart timeout')), 8_000)),
  ]);
  const pidAfter = sup.pid;

  check(
    'crash_restart',
    sup.state === 'ready' && pidAfter !== pidBefore && typeof pidAfter === 'number',
    `${pidBefore} -> ${pidAfter}`,
  );

  const afterRestart = await sup.request('echo', { b: 2 });
  check('post_restart_invoke', afterRestart && afterRestart.b === 2, JSON.stringify(afterRestart));

  // 优雅退出
  const pidLast = sup.pid;
  await sup.stop();
  check(
    'graceful_stop',
    sup.state === 'stopped' && !alive(pidLast) && sup.pid === undefined,
    `state=${sup.state} pid=${pidLast}`,
  );

  let failed = 0;
  for (const x of results) {
    console.log(`${x.ok ? '[OK]  ' : '[FAIL]'} ${x.name.padEnd(20)} ${x.detail}`);
    if (!x.ok) failed++;
  }
  console.log(`[summary] ${results.length - failed}/${results.length} passed`);
  process.exit(failed ? 1 : 0);
})().catch((e) => {
  console.error('[FATAL]', e);
  process.exit(1);
});