#!/usr/bin/env node
/**
 * 数据库验收：完整性检查 / 迁移 / 幂等 / 失败回滚 / 优雅关闭。
 * 需 Electron 运行时（better-sqlite3 为 Electron ABI），脚本自动自举。
 *
 * 用法：node tool/check/db-smoke.js
 */
'use strict';

const path = require('node:path');
const fs = require('node:fs');
const os = require('node:os');
const { spawnSync } = require('node:child_process');

function exeName() {
  return process.platform === 'win32' ? 'electron.exe' : 'electron';
}

function resolveElectronExe() {
  const candidates = [
    path.join(process.cwd(), 'node_modules', 'electron', 'dist', exeName()),
    path.join(__dirname, '..', '..', 'node_modules', 'electron', 'dist', exeName()),
  ];
  for (const c of candidates) {
    if (fs.existsSync(c)) return c;
  }
  return null;
}

if (!process.versions.electron) {
  const exe = resolveElectronExe();
  if (!exe) {
    console.error('[FATAL] 找不到 electron，请先 npm install');
    process.exit(2);
  }
  console.log('[boot] electron runtime:', exe);
  const r = spawnSync(exe, [__filename], {
    stdio: 'inherit',
    env: Object.assign({}, process.env, { ELECTRON_RUN_AS_NODE: '1' }),
  });
  process.exit(typeof r.status === 'number' ? r.status : 1);
}

const root = path.join(__dirname, '..', '..');
const { createDb, checkIntegrity, closeDb } = require(path.join(root, 'dist', 'kernel', 'db'));
const { Migrator } = require(path.join(root, 'dist', 'kernel', 'migrator'));
const { TaskQueue } = require(path.join(root, 'dist', 'kernel', 'queue'));

(async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-db-'));
  const file = path.join(dir, 'test.sqlite');

  const handle = createDb(file);
  const { db, raw } = handle;

  const results = [];
  const check = (name, ok, detail) => results.push({ name, ok, detail: detail || '' });

  // 1. 完整性
  const integ = checkIntegrity(raw);
  check('integrity', integ.ok, integ.messages.join(','));

  // 2. 首次迁移
  const migrator = new Migrator(db);
  const mig1 = {
    id: '001_t',
    up: async (d) => {
      await d.schema.createTable('t').addColumn('id', 'integer').execute();
    },
  };

  const a1 = await migrator.run([mig1]);
  check('migrate_first', a1.length === 1, JSON.stringify(a1));

  // 3. 幂等（重复执行不再跑）
  const a2 = await migrator.run([mig1]);
  check('migrate_idempotent', a2.length === 0, JSON.stringify(a2));

  // 4. 失败回滚（迁移抛错不得留下记录）
  let threw = false;
  try {
    await migrator.run([
      {
        id: '002_bad',
        up: async () => {
          throw new Error('boom');
        },
      },
    ]);
  } catch {
    threw = true;
  }
  const ids = await migrator.applied();
  check('migrate_rollback', threw && !ids.includes('002_bad'), 'applied=' + JSON.stringify(ids));

  // 5. 队列：enqueue → claim → 失败重投 → 超限失败
  const queue = await TaskQueue.create(db, raw);

  const id1 = await queue.enqueue('noop', { n: 1 }, { maxAttempts: 2 });
  const claimed1 = await queue.claim(1);
  const okClaim =
    claimed1.length === 1 && claimed1[0].state === 'running' && claimed1[0].attempts === 1;

  await queue.fail(id1, 'boom', true);
  const retried = await queue.get(id1);
  const retryState = retried.state;
  // 重试按 next_run_at 退避：先确认退避时间被写入，再清空它以便继续验证后续状态迁移
  const backoffApplied = Number(retried.next_run_at || 0) > Date.now();
  await db.updateTable('tasks').set({ next_run_at: null }).where('id', '=', id1).execute();

  const claimed2 = await queue.claim(1);
  await queue.fail(id1, 'boom again', true);
  const finalState = (await queue.get(id1)).state;

  check(
    'queue_retry',
    okClaim && retryState === 'pending' && backoffApplied && claimed2.length === 1 && finalState === 'failed',
    `claim=${claimed1.length} retry=${retryState} backoff=${backoffApplied} final=${finalState}`,
  );

  // 6. 队列：崩溃恢复（running → pending）
  const id2 = await queue.enqueue('noop', { n: 2 });
  await queue.claim(1);
  const recovered = await queue.recover();
  const rec = await queue.get(id2);

  check(
    'queue_recover',
    recovered === 1 && rec.state === 'pending' && rec.attempts === 1,
    `recovered=${recovered} state=${rec.state} attempts=${rec.attempts}`,
  );

  // 7. 任务历史清理：只删「终态 + 超过保留天数 + 不在重试退避中」的行
  const oldDone = await queue.enqueue('noop', { n: 3 });
  const freshDone = await queue.enqueue('noop', { n: 4 });
  const retryPending = await queue.enqueue('noop', { n: 5 });
  // 造三行历史：① 30 天前的 done ② 刚才的 done ③ 终态但 next_run_at 在未来的 failed
  await db
    .updateTable('tasks')
    .set({ state: 'done', created_at: Date.now() - 40 * 86_400_000, finished_at: Date.now() - 40 * 86_400_000 })
    .where('id', '=', oldDone)
    .execute();
  await db
    .updateTable('tasks')
    .set({ state: 'done', finished_at: Date.now() })
    .where('id', '=', freshDone)
    .execute();
  await db
    .updateTable('tasks')
    .set({ state: 'failed', finished_at: Date.now() - 40 * 86_400_000, next_run_at: Date.now() + 60_000 })
    .where('id', '=', retryPending)
    .execute();
  // 再加一行 40 天前的 pending：绝不能被删
  const pendingRow = await queue.enqueue('noop', { n: 6 });
  await db
    .updateTable('tasks')
    .set({ created_at: Date.now() - 40 * 86_400_000 })
    .where('id', '=', pendingRow)
    .execute();

  const pruned = await queue.prune(30);
  const left = new Set((await db.selectFrom('tasks').select('id').execute()).map((r) => r.id));

  check(
    'queue_prune',
    pruned === 1 &&
      !left.has(oldDone) &&
      left.has(freshDone) &&
      left.has(retryPending) &&
      left.has(pendingRow),
    `pruned=${pruned} old=${left.has(oldDone)} fresh=${left.has(freshDone)} retry=${left.has(retryPending)} pending=${left.has(pendingRow)}`,
  );

  // 8. 优雅关闭
  await closeDb(handle);
  check('close', true, '');

  fs.rmSync(dir, { recursive: true, force: true });

  let failed = 0;
  for (const r of results) {
    console.log(`${r.ok ? '[OK]  ' : '[FAIL]'} ${r.name.padEnd(20)} ${r.detail}`);
    if (!r.ok) failed++;
  }
  console.log(`[summary] ${results.length - failed}/${results.length} passed`);
  process.exit(failed ? 1 : 0);
})().catch((e) => {
  console.error('[FATAL]', e);
  process.exit(1);
});
