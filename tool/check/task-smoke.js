#!/usr/bin/env node
/**
 * 任务队列（蓝图 §8）验收：
 *   注册 handler → 入队 → worker 执行 → done / 进度
 *   抛错 → 按退避重试到 maxAttempts → failed（attempts 与 error 落库）
 *   去重入队（同 type+payload 复用）→ 取消（pending 立即停）→ 重启恢复（running 回滚 pending）
 *
 * 依赖 Electron 运行时（better-sqlite3 的 ABI），脚本自动自举。
 * 用法：node tool/check/task-smoke.js
 */
'use strict';

const path = require('node:path');
const fs = require('node:fs');
const os = require('node:os');
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
    console.error('[FATAL] cannot find electron, run npm install first');
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

let passed = 0;
let failed = 0;

function ok(name, extra) {
  passed += 1;
  console.log('[OK]  ', name.padEnd(26), extra === undefined ? '' : extra);
}

function fail(name, detail) {
  failed += 1;
  console.log('[FAIL]', name.padEnd(26), detail);
}

function check(name, cond, detail) {
  if (cond) ok(name);
  else fail(name, detail);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function waitFor(fn, timeoutMs = 8000, stepMs = 50) {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    const v = await fn();
    if (v) return v;
    await sleep(stepMs);
  }
  return null;
}

(async () => {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-task-'));
  process.env.COLANAS_DEV_TOKEN = '1';
  process.env.COLANAS_FILES_ROOT = path.join(dataDir, 'files');
  process.env.LOG_LEVEL = 'warn';
  process.env.COLANAS_TASK_RETRY_BASE_MS = '60';
  process.env.COLANAS_TASK_POLL_MS = '50';

  const k = await startKernel({ dataDir, port: 0, listen: false });
  const { app, queue } = k;

  const tokenRes = await app.inject({
    method: 'POST',
    url: '/api/v1/auth/dev-token',
    payload: { sub: 'task', scopes: ['*'] },
  });
  const bearer = { authorization: 'Bearer ' + tokenRes.json().token };

  // 1. 正常执行 + 进度
  let progressSeen = 0;
  queue.register('test.echo', async (payload, ctx) => {
    await ctx.progress(42);
    progressSeen = 42;
    return { echo: payload };
  });
  const echoId = await queue.enqueue('test.echo', { hello: 'world' });
  const echoDone = await waitFor(async () => {
    const t = await queue.get(echoId);
    return t && t.state === 'done' ? t : null;
  });
  check('worker_executes', Boolean(echoDone), 'task never reached done');
  check('handler_progress', progressSeen === 42, 'progress=' + progressSeen);
  check('done_progress_100', echoDone && Number(echoDone.progress) === 100, 'progress=' + (echoDone && echoDone.progress));

  // 2. 抛错 → 重试到 maxAttempts → failed
  let attempts = 0;
  queue.register('test.fail', async () => {
    attempts += 1;
    throw new Error('boom');
  });
  const failId = await queue.enqueue('test.fail', {}, { maxAttempts: 2 });
  const failedRow = await waitFor(async () => {
    const t = await queue.get(failId);
    return t && t.state === 'failed' ? t : null;
  }, 10000);
  check('failure_marks_failed', Boolean(failedRow), 'state never became failed');
  check('failure_attempts', failedRow && Number(failedRow.attempts) === 2, 'attempts=' + (failedRow && failedRow.attempts));
  check(
    'failure_error_text',
    failedRow && String(failedRow.error || '').includes('boom'),
    failedRow && failedRow.error,
  );
  check('handler_called_twice', attempts === 2, 'calls=' + attempts);

  // 3. 去重入队
  const a = await queue.enqueueIfIdle('test.echo', { dedupe: 1 });
  const b = await queue.enqueueIfIdle('test.echo', { dedupe: 1 });
  check('enqueue_dedupe', a.id === b.id && b.reused === true, `${a.reused}/${b.reused}`);

  // 4. 未注册类型 → 直接 failed（不重试）
  const noHandlerId = await queue.enqueue('test.unknown', {});
  const noHandler = await waitFor(async () => {
    const t = await queue.get(noHandlerId);
    return t && t.state === 'failed' ? t : null;
  });
  check('unknown_type_failed', Boolean(noHandler), 'task stayed pending');
  check(
    'unknown_type_reason',
    noHandler && String(noHandler.error || '').includes('no handler'),
    noHandler && noHandler.error,
  );

  // 5. 取消 pending：先停 worker，入队后经 HTTP 取消
  await queue.stop();
  const cancelId = await queue.enqueue('test.echo', { cancel: true });
  const cancelRes = await app.inject({
    method: 'POST',
    url: '/api/v1/tasks/cancel',
    headers: bearer,
    payload: { id: cancelId },
  });
  const canceled = await queue.get(cancelId);
  check('cancel_endpoint', cancelRes.statusCode === 200, 'status=' + cancelRes.statusCode);
  check('cancel_state', canceled && canceled.state === 'canceled', canceled && canceled.state);

  // 5.1 暂停 / 恢复：paused 不会被 claim
  const pauseId = await queue.enqueue('test.echo', { pause: true });
  const pauseRes = await app.inject({
    method: 'POST',
    url: '/api/v1/tasks/pause',
    headers: bearer,
    payload: { id: pauseId },
  });
  const pausedRow = await queue.get(pauseId);
  check('pause_endpoint', pauseRes.statusCode === 200, 'status=' + pauseRes.statusCode);
  check('pause_state', Boolean(pausedRow) && pausedRow.state === 'paused', pausedRow && pausedRow.state);
  check('pause_not_claimed', (await queue.claim(1)).length === 0, 'paused task was claimed');

  const resumeRes = await app.inject({
    method: 'POST',
    url: '/api/v1/tasks/resume',
    headers: bearer,
    payload: { id: pauseId },
  });
  const resumedRow = await queue.get(pauseId);
  check('resume_endpoint', resumeRes.statusCode === 200, 'status=' + resumeRes.statusCode);
  check('resume_state', Boolean(resumedRow) && resumedRow.state === 'pending', resumedRow && resumedRow.state);

  // 6. 重启恢复：把一条任务手工置为 running，再 recover
  const reviveId = await queue.enqueue('test.echo', { revive: true });
  await k.db.updateTable('tasks').set({ state: 'running' }).where('id', '=', reviveId).execute();
  const recovered = await queue.recover();
  const revived = await queue.get(reviveId);
  check('recover_running', recovered >= 1, 'recovered=' + recovered);
  check('recover_to_pending', revived && revived.state === 'pending', revived && revived.state);

  // 7. 重启 worker 后任务继续被消费
  queue.start({ concurrency: 1, pollMs: 50 });
  const revivedDone = await waitFor(async () => {
    const t = await queue.get(reviveId);
    return t && t.state === 'done' ? t : null;
  });
  check('resume_after_restart', Boolean(revivedDone), 'task not resumed');

  await app.close();
  ok('kernel_close');

  try { fs.rmSync(dataDir, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 }); } catch { /* 句柄释放有延迟 */ }
  console.log(`[summary] ${passed}/${passed + failed} passed`);
  process.exit(failed === 0 ? 0 : 1);
})().catch((err) => {
  console.error('[FATAL]', err && err.stack ? err.stack : err);
  process.exit(1);
});