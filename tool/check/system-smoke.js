#!/usr/bin/env node
/**
 * SP3-10（system 部分）验收：monitor / process 列表 / 受限终止。
 *
 * 需 Electron 运行时（better-sqlite3 为 Electron ABI），脚本自动自举。
 * 用法：node tool/check/system-smoke.js
 */
'use strict';

const path = require('node:path');
const fs = require('node:fs');
const os = require('node:os');
const { spawnSync, spawn } = require('node:child_process');

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

const alive = (pid) => {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
};

(async () => {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-system-'));
  process.env.COLANAS_DEV_TOKEN = '1';
  process.env.COLANAS_JWT_SECRET = 'test-secret-0123456789abcdef';

  const k = await startKernel({ dataDir, port: 0, listen: false });
  const app = k.app;

  const results = [];
  const check = (name, ok, detail) => results.push({ name, ok, detail: detail || '' });

  const t = await app.inject({
    method: 'POST',
    url: '/api/v1/auth/dev-token',
    payload: { sub: 'u1', scopes: ['system:read', 'system:write'] },
  });
  const bearer = { authorization: 'Bearer ' + (t.json().token || '') };

  let r = await app.inject({ method: 'GET', url: '/api/v1/system/monitor', headers: bearer });
  const m = r.json();
  check(
    'monitor_shape',
    r.statusCode === 200 &&
      m.cpu && m.cpu.cores > 0 &&
      m.mem && m.mem.total > 0 &&
      typeof m.cpu.usagePercent === 'number' &&
      m.cpu.usagePercent >= 0 && m.cpu.usagePercent <= 100,
    `cores=${m.cpu && m.cpu.cores} cpu=${m.cpu && m.cpu.usagePercent}% mem=${m.mem && m.mem.total}`,
  );
  check('monitor_disk', m.disk && m.disk.total >= 0, JSON.stringify(m.disk));

  // GPU：Windows 走后台性能计数器探针，首个请求可能还没出值（返回 null）。
  // 形状断言在任何平台都成立；只在本机能起探针时才断言真实读数，虚拟机/无显卡的 CI 不失败。
  const gpu1 = m.gpu;
  check(
    'monitor_gpu_shape',
    gpu1 === null ||
      (typeof gpu1.name === 'string' &&
        typeof gpu1.driverVersion === 'string' &&
        typeof gpu1.usagePercent === 'number' &&
        gpu1.usagePercent >= 0 &&
        gpu1.usagePercent <= 100 &&
        Number.isInteger(gpu1.memUsed) &&
        Number.isInteger(gpu1.memTotal)),
    JSON.stringify(gpu1),
  );
  if (process.platform === 'win32') {
    await new Promise((res) => setTimeout(res, 5000));
    const r2 = await app.inject({ method: 'GET', url: '/api/v1/system/monitor', headers: bearer });
    const gpu2 = r2.json().gpu;
    check(
      'monitor_gpu_probe',
      gpu2 === null ||
        (gpu2.usagePercent >= 0 && gpu2.usagePercent <= 100 && typeof gpu2.driverVersion === 'string'),
      gpu2
        ? `${gpu2.name} ${gpu2.usagePercent}% mem=${gpu2.memUsed}/${gpu2.memTotal} drv=${gpu2.driverVersion}`
        : 'skip: 本机 GPU 计数器不可用',
    );
  }

  r = await app.inject({ method: 'GET', url: '/api/v1/system/processes?limit=1000', headers: bearer });
  const pl = r.json();
  check(
    'process_list',
    r.statusCode === 200 && Array.isArray(pl.items) && pl.items.length > 0 && pl.total >= pl.items.length,
    `items=${pl.items && pl.items.length} total=${pl.total}`,
  );
  check(
    'process_contains_self',
    (pl.items || []).some((x) => x.pid === process.pid),
    'self=' + process.pid,
  );

  r = await app.inject({ method: 'GET', url: '/api/v1/system/processes?filter=electron&limit=5', headers: bearer });
  const filtered = r.json();
  check(
    'process_filter',
    r.statusCode === 200 && Array.isArray(filtered.items) && filtered.items.every((x) => x.name.toLowerCase().includes('electron')),
    'items=' + (filtered.items || []).length,
  );

  r = await app.inject({ method: 'POST', url: '/api/v1/system/processes/kill', headers: bearer, payload: { pid: 999999 } });
  check('kill_missing_404', r.statusCode === 404, 'status=' + r.statusCode);

  r = await app.inject({ method: 'POST', url: '/api/v1/system/processes/kill', headers: bearer, payload: { pid: process.pid } });
  check('kill_self_400', r.statusCode === 400, 'status=' + r.statusCode);

  r = await app.inject({ method: 'POST', url: '/api/v1/system/processes/kill', headers: bearer, payload: { pid: 2 } });
  check('kill_low_pid_400', r.statusCode === 400, 'status=' + r.statusCode);

  // 真实终止一个临时子进程
  const child = spawn(process.execPath, ['-e', 'setTimeout(()=>{}, 30000)'], {
    env: Object.assign({}, process.env, { ELECTRON_RUN_AS_NODE: '1' }),
    stdio: 'ignore',
    windowsHide: true,
  });
  await new Promise((r2) => setTimeout(r2, 400));
  const before = alive(child.pid);
  r = await app.inject({ method: 'POST', url: '/api/v1/system/processes/kill', headers: bearer, payload: { pid: child.pid } });
  await new Promise((r2) => setTimeout(r2, 400));
  check('kill_child', before && r.statusCode === 200 && !alive(child.pid), `pid=${child.pid} status=${r.statusCode}`);

  // ---- 配置中心：设置 / 缓存 / 更新检查 ----
  r = await app.inject({ method: 'GET', url: '/api/v1/system/settings', headers: bearer });
  const got = r.json().settings || {};
  check(
    'settings_get',
    r.statusCode === 200 && got.httpPort === 7788 && got.apiConcurrency >= 1,
    JSON.stringify(got),
  );

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/system/settings',
    headers: bearer,
    payload: {
      httpPort: 7788,
      apiConcurrency: 2,
      hostname: 'nas-01',
      welcome: '欢迎回来',
      proxy: 'http://127.0.0.1:7890',
    },
  });
  const saved = r.json().settings || {};
  check(
    'settings_set_roundtrip',
    r.statusCode === 200 &&
      saved.hostname === 'nas-01' &&
      saved.welcome === '欢迎回来' &&
      saved.apiConcurrency === 2 &&
      r.json().activeProxy === 'http://127.0.0.1:7890',
    JSON.stringify(saved),
  );

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/system/settings',
    headers: bearer,
    payload: { proxy: 'not-a-url' },
  });
  check('settings_bad_proxy_400', r.statusCode === 400, 'status=' + r.statusCode);

  // 代理恢复直连，避免影响同进程后续请求
  await app.inject({
    method: 'POST',
    url: '/api/v1/system/settings',
    headers: bearer,
    payload: { proxy: '' },
  });

  r = await app.inject({ method: 'GET', url: '/api/v1/system/cache/info', headers: bearer });
  check(
    'cache_info',
    r.statusCode === 200 && typeof r.json().bytes === 'number' && typeof r.json().files === 'number',
    JSON.stringify(r.json()),
  );

  r = await app.inject({ method: 'POST', url: '/api/v1/system/cache/clear', headers: bearer });
  check(
    'cache_clear',
    r.statusCode === 200 && r.json().ok === true && typeof r.json().freedBytes === 'number',
    JSON.stringify(r.json()),
  );

  // 数据库碎片整理：SQLite 不允许在事务里 VACUUM，这里正好验证独立执行
  r = await app.inject({ method: 'POST', url: '/api/v1/system/db/compact', headers: bearer });
  check(
    'db_compact',
    r.statusCode === 200 && r.json().ok === true && typeof r.json().freedBytes === 'number',
    JSON.stringify(r.json()),
  );

  r = await app.inject({ method: 'GET', url: '/api/v1/system/update/check', headers: bearer });
  check(
    'update_check',
    r.statusCode === 200 && typeof r.json().hasUpdate === 'boolean' && typeof r.json().versions === 'number',
    JSON.stringify(r.json()),
  );

  // HTTPS 证书（用户上传方案）：空态 / 非法 PEM 400 / 删除
  r = await app.inject({ method: 'GET', url: '/api/v1/system/tls', headers: bearer });
  check(
    'tls_info_empty',
    r.statusCode === 200 && r.json().hasCert === false && typeof r.json().port === 'number',
    JSON.stringify(r.json()),
  );

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/system/tls',
    headers: bearer,
    payload: { cert: 'not-a-cert', key: 'not-a-key' },
  });
  check('tls_upload_bad', r.statusCode === 400, 'status=' + r.statusCode);

  r = await app.inject({ method: 'POST', url: '/api/v1/system/tls/clear', headers: bearer });
  check('tls_clear', r.statusCode === 200 && r.json().ok === true, 'status=' + r.statusCode);

  r = await app.inject({ method: 'GET', url: '/health' });
  check(
    'health_hostname',
    r.statusCode === 200 && r.json().hostname === 'nas-01' && r.json().welcome === '欢迎回来',
    JSON.stringify(r.json()),
  );

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