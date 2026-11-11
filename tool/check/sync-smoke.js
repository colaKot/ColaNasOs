#!/usr/bin/env node
/**
 * SP3-12（sync 本体）验收：增量同步 / 幂等 / 三种冲突策略 / 冲突裁决 / 差异预览 / 越界。
 *
 * 需 Electron 运行时（better-sqlite3 为 Electron ABI），脚本自动自举。
 * 用法：node tool/check/sync-smoke.js
 */
'use strict';

const path = require('node:path');
const fs = require('node:fs');
const os = require('node:os');
const { spawnSync } = require('node:child_process');

if (!process.versions.electron) {
  const exe = path.join(process.cwd(), 'node_modules', 'electron', 'dist', process.platform === 'win32' ? 'electron.exe' : 'electron');
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

(async () => {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-sync-'));
  const filesRoot = path.join(dataDir, 'files');
  const src = path.join(filesRoot, 'src');
  const dst = path.join(filesRoot, 'dst');
  fs.mkdirSync(path.join(src, 'sub'), { recursive: true });
  fs.writeFileSync(path.join(src, 'a.txt'), 'aaa');
  fs.writeFileSync(path.join(src, 'b.txt'), 'bbb');
  fs.writeFileSync(path.join(src, 'sub', 'c.txt'), 'ccc');

  process.env.COLANAS_DEV_TOKEN = '1';
  process.env.COLANAS_FILES_ROOT = filesRoot;
  process.env.COLANAS_JWT_SECRET = 'test-secret-0123456789abcdef';

  const k = await startKernel({ dataDir, port: 0, listen: false });
  const app = k.app;

  const results = [];
  const check = (name, ok, detail) => results.push({ name, ok, detail: detail || '' });

  const t = await app.inject({
    method: 'POST',
    url: '/api/v1/auth/dev-token',
    payload: { sub: 'u1', scopes: ['sync:read', 'sync:write'] },
  });
  const bearer = { authorization: 'Bearer ' + (t.json().token || '') };
  // 路径 ACL 默认拒绝（用户 2026-11-11）：没授权目录的账号连文件根都列不出来。
  // 本用例验的不是授权，所以显式把文件根授给这个测试账号。
  await k.config.set('accessPolicy.u1', {
    apps: null,
    paths: [{ path: '/', actions: ['view', 'download', 'update', 'delete', 'upload'] }],
  });


  const run = (payload) => app.inject({ method: 'POST', url: '/api/v1/sync/run', headers: bearer, payload });

  // 1. 首次全量
  let r = await run({ source: '/src', target: '/dst', policy: 'skip' });
  const first = r.json();
  check(
    'first_copy',
    r.statusCode === 200 && first.copied === 3 && first.conflicts === 0,
    JSON.stringify(first),
  );
  check(
    'files_landed',
    fs.readFileSync(path.join(dst, 'sub', 'c.txt'), 'utf8') === 'ccc',
    'c.txt ok',
  );

  // 2. 幂等
  r = await run({ source: '/src', target: '/dst', policy: 'skip' });
  const second = r.json();
  check('idempotent', second.copied === 0 && second.skipped === 3, JSON.stringify(second));

  // 3. skip 策略记录冲突
  fs.writeFileSync(path.join(dst, 'b.txt'), 'dst-modified');
  r = await run({ source: '/src', target: '/dst', policy: 'skip' });
  const skippedRun = r.json();
  check(
    'conflict_skip',
    skippedRun.conflicts === 1 && fs.readFileSync(path.join(dst, 'b.txt'), 'utf8') === 'dst-modified',
    JSON.stringify(skippedRun),
  );

  r = await app.inject({ method: 'GET', url: '/api/v1/sync/conflicts?jobId=' + skippedRun.id, headers: bearer });
  const conflicts = r.json();
  const c0 = conflicts.items[0];
  check('conflict_list', r.statusCode === 200 && conflicts.items.length === 1 && c0.path === 'b.txt', JSON.stringify(c0));

  // 4. 裁决为 source
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/sync/conflicts/resolve',
    headers: bearer,
    payload: { id: c0.id, action: 'source' },
  });
  check(
    'conflict_resolve',
    r.statusCode === 200 && fs.readFileSync(path.join(dst, 'b.txt'), 'utf8') === 'bbb',
    'content=' + fs.readFileSync(path.join(dst, 'b.txt'), 'utf8'),
  );

  // 5. overwrite
  fs.writeFileSync(path.join(dst, 'a.txt'), 'dst-a');
  r = await run({ source: '/src', target: '/dst', policy: 'overwrite' });
  check(
    'conflict_overwrite',
    r.json().copied === 1 && fs.readFileSync(path.join(dst, 'a.txt'), 'utf8') === 'aaa',
    JSON.stringify(r.json()),
  );

  // 6. rename
  fs.writeFileSync(path.join(dst, 'a.txt'), 'dst-a2');
  r = await run({ source: '/src', target: '/dst', policy: 'rename' });
  const renamedRun = r.json();
  const backups = fs.readdirSync(dst).filter((n) => n.includes('.conflict-'));
  check(
    'conflict_rename',
    renamedRun.conflicts === 1 && backups.length === 1 && fs.readFileSync(path.join(dst, 'a.txt'), 'utf8') === 'aaa',
    `conflicts=${renamedRun.conflicts} backups=${backups.join(',')}`,
  );

  // 7. 差异预览
  fs.writeFileSync(path.join(src, 'd.txt'), 'ddd');
  r = await app.inject({ method: 'GET', url: '/api/v1/sync/diff?source=/src&target=/dst', headers: bearer });
  const diff = r.json();
  check(
    'diff_preview',
    r.statusCode === 200 && diff.onlySource.includes('d.txt') && Array.isArray(diff.changed),
    JSON.stringify(diff),
  );

  // 8. 越界
  r = await run({ source: '../../etc', target: '/dst' });
  check('path_escape_400', r.statusCode === 400, 'status=' + r.statusCode);

  // 9. 历史
  r = await app.inject({ method: 'GET', url: '/api/v1/sync/jobs', headers: bearer });
  const jobs = r.json();
  check('jobs_history', r.statusCode === 200 && jobs.items.length >= 5, 'items=' + jobs.items.length);

  // ---------------------------------------------------------------- 多端同步（三向比对）
  const remoteDir = path.join(filesRoot, 'remote');
  fs.mkdirSync(remoteDir, { recursive: true });
  fs.writeFileSync(path.join(remoteDir, 'a.txt'), 'aaa');
  const t0 = new Date('2026-01-01T00:00:00Z');
  fs.utimesSync(path.join(remoteDir, 'a.txt'), t0, t0);
  const aMtime = fs.statSync(path.join(remoteDir, 'a.txt')).mtimeMs;

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/sync/tasks/upsert',
    headers: bearer,
    payload: {
      name: '照片备份',
      deviceId: 'machine-guid-1',
      deviceName: 'PC-A',
      mode: 'bidirectional',
      localDir: '/local',
      remoteDir: '/remote',
      include: [],
      exclude: ['*.tmp'],
    },
  });
  const task = r.json();
  check('task_create', r.statusCode === 200 && task.id && task.mode === 'bidirectional', JSON.stringify(task).slice(0, 100));
  check('task_name_roundtrip', task.name === '照片备份', `name=${task.name}`);

  const plan = (payload) =>
    app.inject({ method: 'POST', url: '/api/v1/sync/plan', headers: bearer, payload: { taskId: task.id, ...payload } });
  const report = (applied) =>
    app.inject({
      method: 'POST',
      url: '/api/v1/sync/report',
      headers: bearer,
      payload: { taskId: task.id, applied },
    });

  // 首次：远端有 a.txt，本地同 size + mtime 差 1.5s（FAT 容差内）⇒ identical
  r = await plan({ local: [{ path: 'a.txt', size: 3, mtimeMs: aMtime + 1500 }] });
  check('plan_mtime_tolerance', r.statusCode === 200 && r.json().actions[0].kind === 'skip', JSON.stringify(r.json().stats));

  // 本地新增 ⇒ upload
  r = await plan({
    local: [
      { path: 'a.txt', size: 3, mtimeMs: aMtime },
      { path: 'new.txt', size: 5, mtimeMs: aMtime },
    ],
  });
  check(
    'plan_local_new_upload',
    r.json().stats.upload === 1 && r.json().actions.some((a) => a.path === 'new.txt' && a.kind === 'upload'),
    JSON.stringify(r.json().stats),
  );

  // 上报（远端此时仍只有 a.txt）⇒ 基线 1 条
  r = await report([{ path: 'a.txt', kind: 'skip', ok: true }]);
  check('report_baseline', r.statusCode === 200 && r.json().baseline === 1, JSON.stringify(r.json()));

  // 基线已建立：本地新增仍然要上传
  r = await plan({
    local: [
      { path: 'a.txt', size: 3, mtimeMs: aMtime },
      { path: 'new.txt', size: 5, mtimeMs: aMtime },
    ],
  });
  check('plan_after_baseline_upload', r.json().stats.upload === 1 && r.json().stats.skip === 1, JSON.stringify(r.json().stats));

  // 模拟客户端完成上传
  fs.writeFileSync(path.join(remoteDir, 'new.txt'), '12345');
  fs.utimesSync(path.join(remoteDir, 'new.txt'), t0, t0);
  await report([{ path: 'new.txt', kind: 'upload', ok: true }]);

  // 远端改 a.txt ⇒ download
  fs.writeFileSync(path.join(remoteDir, 'a.txt'), 'aaaa');
  const aMtime2 = aMtime + 60_000;
  fs.utimesSync(path.join(remoteDir, 'a.txt'), new Date(aMtime2), new Date(aMtime2));
  r = await plan({
    local: [
      { path: 'a.txt', size: 3, mtimeMs: aMtime },
      { path: 'new.txt', size: 5, mtimeMs: aMtime },
    ],
  });
  check(
    'plan_remote_changed_download',
    r.json().stats.download === 1 && r.json().actions.some((a) => a.path === 'a.txt' && a.kind === 'download'),
    JSON.stringify(r.json().stats),
  );

  // 本地删除 new.txt ⇒ 双向模式删远端
  r = await plan({ local: [{ path: 'a.txt', size: 3, mtimeMs: aMtime }] });
  check(
    'plan_local_deleted_remote',
    r.json().actions.some((a) => a.path === 'new.txt' && a.kind === 'deleteRemote'),
    JSON.stringify(r.json().stats),
  );

  // 两边都改 ⇒ conflict（不猜）
  r = await plan({ local: [{ path: 'a.txt', size: 9, mtimeMs: aMtime2 + 60_000 }] });
  check(
    'plan_both_changed_conflict',
    r.json().stats.conflict === 1,
    JSON.stringify(r.json().stats),
  );

  // ---------------------------------------------------------------- 任务级策略
  const upsertTask = (payload) =>
    app.inject({ method: 'POST', url: '/api/v1/sync/tasks/upsert', headers: bearer, payload });
  r = await upsertTask({
    name: '策略任务',
    deviceId: 'machine-guid-3',
    deviceName: 'PC-C',
    mode: 'bidirectional',
    localDir: '/local3',
    remoteDir: '/remote',
    filterConfig: { excludeHidden: true },
    syncConfig: { conflictStrategy: 'prefer_local', deleteExtra: false },
  });
  const task3 = r.json();
  check(
    'task_config_roundtrip',
    task3.filterConfig?.excludeHidden === true &&
      task3.syncConfig?.conflictStrategy === 'prefer_local' &&
      task3.syncConfig?.deleteExtra === false,
    JSON.stringify({ f: task3.filterConfig, s: task3.syncConfig }).slice(0, 160),
  );

  const planOf = (taskId, payload) =>
    app.inject({ method: 'POST', url: '/api/v1/sync/plan', headers: bearer, payload: { taskId, ...payload } });
  const baselineA = [{ path: 'a.txt', size: 3, mtimeMs: aMtime }];
  const localA = [{ path: 'a.txt', size: 9, mtimeMs: aMtime2 + 60_000 }];

  r = await planOf(task3.id, { baseline: baselineA, local: localA });
  check(
    'plan_conflict_prefer_local',
    r.json().actions.some((a) => a.path === 'a.txt' && a.kind === 'upload'),
    JSON.stringify(r.json().stats),
  );

  // prefer_remote：同一冲突改判 download
  await upsertTask({
    id: task3.id,
    name: '策略任务',
    deviceId: 'machine-guid-3',
    deviceName: 'PC-C',
    mode: 'bidirectional',
    localDir: '/local3',
    remoteDir: '/remote',
    filterConfig: { excludeHidden: true },
    syncConfig: { conflictStrategy: 'prefer_remote', deleteExtra: false },
  });
  r = await planOf(task3.id, { baseline: baselineA, local: localA });
  check(
    'plan_conflict_prefer_remote',
    r.json().actions.some((a) => a.path === 'a.txt' && a.kind === 'download'),
    JSON.stringify(r.json().stats),
  );

  // prefer_newer：本地 mtime 更晚 ⇒ upload
  await upsertTask({
    id: task3.id,
    name: '策略任务',
    deviceId: 'machine-guid-3',
    deviceName: 'PC-C',
    mode: 'bidirectional',
    localDir: '/local3',
    remoteDir: '/remote',
    filterConfig: {
      excludeHidden: true,
      excludeExtensionEnabled: true,
      excludeExtensions: ['bin'],
    },
    syncConfig: { conflictStrategy: 'prefer_newer', deleteExtra: false },
  });
  r = await planOf(task3.id, { baseline: baselineA, local: localA });
  check(
    'plan_conflict_prefer_newer',
    r.json().actions.some((a) => a.path === 'a.txt' && a.kind === 'upload'),
    JSON.stringify(r.json().stats),
  );

  // deleteExtra=false：本地删除不再删远端
  r = await planOf(task3.id, {
    baseline: [{ path: 'new.txt', size: 5, mtimeMs: aMtime }],
    local: [],
  });
  check(
    'plan_delete_extra_off',
    r.json().actions.some((a) => a.path === 'new.txt' && a.kind === 'skip') &&
      !r.json().actions.some((a) => a.path === 'new.txt' && a.kind === 'deleteRemote'),
    JSON.stringify(r.json().stats),
  );

  // 结构化过滤：隐藏文件与扩展名在远端扫描阶段就被排除
  fs.writeFileSync(path.join(remoteDir, '.hidden.txt'), 'h');
  fs.writeFileSync(path.join(remoteDir, 'clip.bin'), 'bb');
  r = await planOf(task3.id, { baseline: [], local: [] });
  check(
    'plan_filter_hidden_ext',
    !r.json().actions.some((a) => a.path === '.hidden.txt') &&
      !r.json().actions.some((a) => a.path === 'clip.bin'),
    JSON.stringify(r.json().actions.map((a) => a.path)).slice(0, 160),
  );

  // 探测 / 汇总 / 状态
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/sync/probe',
    headers: bearer,
    payload: { remoteDir: '/remote' },
  });
  check(
    'probe_ok',
    r.statusCode === 200 && r.json().exists === true && r.json().allowed === true,
    JSON.stringify(r.json()),
  );
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/sync/probe',
    headers: bearer,
    payload: { remoteDir: '../../etc' },
  });
  check(
    'probe_escape',
    r.statusCode === 200 && r.json().allowed === false,
    JSON.stringify(r.json()),
  );

  r = await app.inject({ method: 'POST', url: '/api/v1/sync/summary', headers: bearer, payload: {} });
  check(
    'summary_by_device',
    r.statusCode === 200 && r.json().tasks >= 2 && r.json().byDevice.length >= 2,
    JSON.stringify({ tasks: r.json().tasks, devices: r.json().byDevice.length }),
  );

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/sync/status',
    headers: bearer,
    payload: { id: task3.id, status: 'paused' },
  });
  check('status_paused', r.statusCode === 200 && r.json().ok === true, JSON.stringify(r.json()));

  // download_only：本地新增不动作
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/sync/tasks/upsert',
    headers: bearer,
    payload: {
      deviceId: 'machine-guid-2',
      deviceName: 'PC-B',
      mode: 'download_only',
      localDir: '/local2',
      remoteDir: '/remote',
    },
  });
  const task2 = r.json();
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/sync/plan',
    headers: bearer,
    payload: { taskId: task2.id, local: [{ path: 'only-local.txt', size: 1, mtimeMs: aMtime }] },
  });
  check(
    'plan_download_only_skip_local',
    r.json().stats.upload === 0 && r.json().actions.some((a) => a.kind === 'skip'),
    JSON.stringify(r.json().stats),
  );

  // 路径越界
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/sync/tasks/upsert',
    headers: bearer,
    payload: { deviceId: 'x', localDir: '/l', remoteDir: '../../etc' },
  });
  check('task_path_escape_400', r.statusCode === 400, 'status=' + r.statusCode);

  // 任务隔离：另一个用户看不到 u1 的任务
  const t2 = await app.inject({
    method: 'POST',
    url: '/api/v1/auth/dev-token',
    payload: { sub: 'u2', scopes: ['sync:read', 'sync:write'] },
  });
  const bearer2 = { authorization: 'Bearer ' + (t2.json().token || '') };
  r = await app.inject({ method: 'GET', url: '/api/v1/sync/tasks', headers: bearer2 });
  check('task_isolation_list', r.statusCode === 200 && r.json().items.length === 0, 'items=' + r.json().items.length);
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/sync/plan',
    headers: bearer2,
    payload: { taskId: task.id, local: [] },
  });
  check('task_isolation_plan_404', r.statusCode === 404, 'status=' + r.statusCode);

  // 运行记录
  r = await app.inject({ method: 'GET', url: '/api/v1/sync/runs?taskId=' + task.id, headers: bearer });
  check('runs_list', r.statusCode === 200 && r.json().items.length >= 2, 'items=' + r.json().items.length);

  await app.close();
  try { fs.rmSync(dataDir, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 }); } catch { /* 句柄释放有延迟 */ }

  let failed = 0;
  for (const x of results) {
    console.log(`${x.ok ? '[OK]  ' : '[FAIL]'} ${x.name.padEnd(22)} ${x.detail}`);
    if (!x.ok) failed++;
  }
  console.log(`[summary] ${results.length - failed}/${results.length} passed`);
  process.exit(failed ? 1 : 0);
})().catch((e) => {
  console.error('[FATAL]', e);
  process.exit(1);
});