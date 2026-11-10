#!/usr/bin/env node
/**
 * 传输中心验收：
 * - 上传会话随 check / chunk / merge 自动建立、推进、收口；
 * - 下载也会落一条会话，且内联预览 / 中段 Range 不记（否则播放器会把面板刷爆）；
 * - 列表能看到别的人、别的端的会话（这是这轮补的核心）；
 * - 暂停 / 恢复 / 取消 的状态机；
 * - 分页是真分页（limit/offset 生效）。
 *
 * 需 Electron 运行时（better-sqlite3 为 Electron ABI），脚本自动自举。
 * 用法：node tool/check/transfer-smoke.js
 */
'use strict';

const path = require('node:path');
const fs = require('node:fs');
const os = require('node:os');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');

function exeName() {
  return process.platform === 'win32' ? 'electron.exe' : 'electron';
}

function resolveElectronExe() {
  const candidates = [
    path.join(process.cwd(), 'node_modules', 'electron', 'dist', exeName()),
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
  const r = spawnSync(exe, [__filename], {
    stdio: 'inherit',
    env: Object.assign({}, process.env, { ELECTRON_RUN_AS_NODE: '1' }),
  });
  process.exit(typeof r.status === 'number' ? r.status : 1);
}

const root = path.join(__dirname, '..', '..');
const { startKernel } = require(path.join(root, 'dist', 'kernel', 'index'));

process.env.COLANAS_LOG_FILE = '0';
process.chdir(root);

const sha256 = (buf) => crypto.createHash('sha256').update(buf).digest('hex');

(async () => {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-transfer-'));
  const filesRoot = path.join(dataDir, 'files');
  fs.mkdirSync(filesRoot, { recursive: true });

  process.env.COLANAS_DEV_TOKEN = '1';
  process.env.COLANAS_FILES_ROOT = filesRoot;
  process.env.COLANAS_JWT_SECRET = 'transfer-smoke-secret-0123456789';

  const k = await startKernel({ dataDir, port: 0, listen: false });
  const app = k.app;

  const results = [];
  const check = (name, ok, detail) => results.push({ name, ok, detail: detail || '' });

  const tokenFor = async (scopes, sub = 'u1') => {
    const r = await app.inject({
      method: 'POST',
      url: '/api/v1/auth/dev-token',
      payload: { sub, scopes },
    });
    return { authorization: 'Bearer ' + r.json().token };
  };

  const full = await tokenFor(['files:read', 'files:write'], 'u1');
  const other = await tokenFor(['files:read', 'files:write'], 'u2');
  const readOnly = await tokenFor(['files:read'], 'u3');

  const content = Buffer.from('transfer-center-probe'.repeat(2048)); // ~40 KiB
  const hash = sha256(content);
  const parts = [
    content.subarray(0, 16000),
    content.subarray(16000, 32000),
    content.subarray(32000),
  ];

  // ---- 1. check 自动建会话 ----
  let r = await app.inject({
    method: 'POST',
    url: '/api/v1/files/check',
    headers: { ...full, 'x-colanas-client': 'android', 'x-colanas-device': 'Pixel%207' },
    payload: { path: 'up/report.bin', size: content.length },
  });
  const c0 = r.json();
  check(
    'check_creates_session',
    r.statusCode === 200 && typeof c0.sessionId === 'string' && c0.sessionId.length > 0,
    'sessionId=' + c0.sessionId,
  );
  const sid = c0.sessionId;

  // ---- 2. 会话出现在列表里，且带端与设备 ----
  r = await app.inject({ method: 'GET', url: '/api/v1/transfer/sessions', headers: full });
  const list0 = r.json();
  const row0 = (list0.items || []).find((x) => x.id === sid);
  check(
    'session_listed',
    r.statusCode === 200 && !!row0 && row0.state === 'active',
    row0 ? `state=${row0.state} origin=${row0.origin} device=${row0.device}` : 'not found',
  );
  check(
    'session_origin_kept',
    !!row0 && row0.origin === 'android' && row0.device === 'Pixel 7',
    row0 ? `${row0.origin}/${row0.device}` : 'n/a',
  );

  // ---- 3. 分片推进：transferred 跟着涨 ----
  for (let i = 0; i < 3; i++) {
    r = await app.inject({
      method: 'POST',
      url: `/api/v1/files/chunk?path=up/report.bin&index=${i}&total=3&sid=${sid}`,
      headers: { ...full, 'content-type': 'application/octet-stream' },
      payload: parts[i],
    });
    check(`chunk_${i}`, r.statusCode === 200, 'status=' + r.statusCode);
  }

  r = await app.inject({ method: 'GET', url: `/api/v1/transfer/sessions/${sid}`, headers: full });
  const mid = r.json();
  check(
    'progress_accumulated',
    r.statusCode === 200 && mid.transferred === content.length,
    `transferred=${mid.transferred}/${content.length}`,
  );
  check(
    'chunks_recorded',
    Array.isArray(mid.doneChunks) && mid.doneChunks.length === 3,
    JSON.stringify(mid.doneChunks),
  );

  // ---- 4. merge 收口为 done ----
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/files/merge',
    headers: full,
    payload: { path: 'up/report.bin', total: 3, size: content.length, hash },
  });
  check('merge_ok', r.statusCode === 200 && r.json().size === content.length, 'status=' + r.statusCode);

  r = await app.inject({ method: 'GET', url: `/api/v1/transfer/sessions/${sid}`, headers: full });
  const after = r.json();
  check(
    'session_done_after_merge',
    r.statusCode === 200 && after.state === 'done' && after.transferred === content.length,
    `state=${after.state} transferred=${after.transferred}`,
  );

  // ---- 5. 别的用户 / 别的端也能看到这条 ----
  r = await app.inject({ method: 'GET', url: '/api/v1/transfer/sessions', headers: other });
  const seenByOther = (r.json().items || []).some((x) => x.id === sid);
  check('visible_to_other_user', r.statusCode === 200 && seenByOther, 'ok=' + seenByOther);

  // ---- 6. 只读账号也能看（面板不该要求写权限） ----
  r = await app.inject({ method: 'GET', url: '/api/v1/transfer/sessions', headers: readOnly });
  check('readonly_can_list', r.statusCode === 200, 'status=' + r.statusCode);
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/transfer/cancel',
    headers: readOnly,
    payload: { id: sid },
  });
  check('readonly_cannot_control', r.statusCode === 403, 'status=' + r.statusCode);

  // ---- 7. 下载：用户点下载记一条；内联预览 / 中段 Range 不记 ----
  const beforeDownloads = (await app.inject({
    method: 'GET',
    url: '/api/v1/transfer/sessions?direction=download',
    headers: full,
  })).json().total;

  r = await app.inject({ method: 'GET', url: '/api/v1/files/download?path=up/report.bin', headers: full });
  check('download_ok', r.statusCode === 200 && r.rawPayload.length === content.length, 'len=' + r.rawPayload.length);
  // 连接在 inject 里是同步完成的，onEnd 回调跟着事件循环跑：让出一拍再查
  await new Promise((res) => setTimeout(res, 120));

  r = await app.inject({
    method: 'GET',
    url: '/api/v1/transfer/sessions?direction=download',
    headers: full,
  });
  const afterDownloads = r.json().total;
  check('download_recorded', afterDownloads === beforeDownloads + 1, `${beforeDownloads} -> ${afterDownloads}`);

  const beforeInline = afterDownloads;
  await app.inject({
    method: 'GET',
    url: '/api/v1/files/download?path=up/report.bin&inline=1',
    headers: full,
  });
  await new Promise((res) => setTimeout(res, 120));
  r = await app.inject({
    method: 'GET',
    url: '/api/v1/transfer/sessions?direction=download',
    headers: full,
  });
  check('inline_not_recorded', r.json().total === beforeInline, `${beforeInline} -> ${r.json().total}`);

  // 中段 Range（播放器 seek）也不该产生新会话
  await app.inject({
    method: 'GET',
    url: '/api/v1/files/download?path=up/report.bin',
    headers: { ...full, range: 'bytes=1000-' },
  });
  await new Promise((res) => setTimeout(res, 120));
  r = await app.inject({
    method: 'GET',
    url: '/api/v1/transfer/sessions?direction=download',
    headers: full,
  });
  check('mid_range_not_recorded', r.json().total === beforeInline, `${beforeInline} -> ${r.json().total}`);

  // ---- 8. 暂停 / 恢复 / 取消 状态机 ----
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/files/check',
    headers: full,
    payload: { path: 'up/pause.bin', size: 1024 },
  });
  const pauseSid = r.json().sessionId;

  r = await app.inject({ method: 'POST', url: '/api/v1/transfer/pause', headers: full, payload: { id: pauseSid } });
  check('pause_ok', r.statusCode === 200, 'status=' + r.statusCode);
  r = await app.inject({ method: 'GET', url: `/api/v1/transfer/sessions/${pauseSid}`, headers: full });
  check('state_paused', r.json().state === 'paused', r.json().state);

  r = await app.inject({ method: 'POST', url: '/api/v1/transfer/resume', headers: full, payload: { id: pauseSid } });
  check('resume_ok', r.statusCode === 200, 'status=' + r.statusCode);
  r = await app.inject({ method: 'GET', url: `/api/v1/transfer/sessions/${pauseSid}`, headers: full });
  check('state_active', r.json().state === 'active', r.json().state);

  r = await app.inject({ method: 'POST', url: '/api/v1/transfer/cancel', headers: full, payload: { id: pauseSid } });
  check('cancel_ok', r.statusCode === 200, 'status=' + r.statusCode);
  r = await app.inject({ method: 'GET', url: `/api/v1/transfer/sessions/${pauseSid}`, headers: full });
  check('state_canceled', r.json().state === 'canceled', r.json().state);

  // 取消后同路径再传：不会复用那条已取消的会话，会另开一条
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/files/check',
    headers: full,
    payload: { path: 'up/pause.bin', size: 1024 },
  });
  check(
    'new_session_after_cancel',
    r.json().sessionId && r.json().sessionId !== pauseSid,
    `${pauseSid} -> ${r.json().sessionId}`,
  );

  // ---- 9. 分页是真分页 ----
  r = await app.inject({ method: 'GET', url: '/api/v1/transfer/sessions?limit=1&offset=0', headers: full });
  const page1 = r.json();
  check('paging_limit', Array.isArray(page1.items) && page1.items.length <= 1, 'len=' + page1.items.length);
  check('paging_total', page1.total >= 3, 'total=' + page1.total);

  r = await app.inject({ method: 'GET', url: '/api/v1/transfer/sessions?state=done', headers: full });
  const doneList = r.json();
  check(
    'filter_by_state',
    doneList.items.every((x) => x.state === 'done'),
    'len=' + doneList.items.length,
  );

  // ---- 10. stats 小结 ----
  r = await app.inject({ method: 'GET', url: '/api/v1/transfer/sessions', headers: full });
  const stats = r.json().stats;
  check(
    'stats_shape',
    stats && typeof stats.active === 'number' && typeof stats.speedBps === 'number',
    JSON.stringify(stats),
  );

  await app.close();
  try {
    fs.rmSync(dataDir, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
  } catch {
    /* 句柄释放有延迟 */
  }

  let failed = 0;
  for (const x of results) {
    console.log(`${x.ok ? '[OK]  ' : '[FAIL]'} ${x.name.padEnd(28)} ${x.detail}`);
    if (!x.ok) failed++;
  }
  console.log(`[summary] ${results.length - failed}/${results.length} passed`);
  process.exit(failed ? 1 : 0);
})().catch((e) => {
  console.error('[FATAL]', e);
  process.exit(1);
});
