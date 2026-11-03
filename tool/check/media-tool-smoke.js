#!/usr/bin/env node
/**
 * SP3-10 mediaTool 验收：批量缩略图 / 转码 / 任务状态机 / 权限 / 路径约束。
 *
 * 依赖 media sidecar 与 ffmpeg：本机就绪时断言产物真的生成；
 * 未就绪时只断言「明确 503」，不让 CI 因缺 ffmpeg 失败。
 *
 * 用法：node tool/check/media-tool-smoke.js（Electron 自举）
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

// 1x1 PNG：够 ffmpeg 解码，测试不依赖外部素材
const PNG = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  'base64',
);

process.chdir(root);

(async () => {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-mt-'));
  const filesRoot = path.join(dataDir, 'files');
  fs.mkdirSync(path.join(filesRoot, 'src'), { recursive: true });
  fs.writeFileSync(path.join(filesRoot, 'src', 'a.png'), PNG);
  fs.writeFileSync(path.join(filesRoot, 'src', 'b.png'), PNG);
  fs.writeFileSync(path.join(filesRoot, 'src', 'notes.txt'), 'not an image');

  process.env.COLANAS_DEV_TOKEN = '1';
  process.env.COLANAS_JWT_SECRET = 'test-secret-0123456789abcdef';
  process.env.COLANAS_FILES_ROOT = filesRoot;

  const k = await startKernel({ dataDir, port: 0, listen: false });
  const app = k.app;

  const results = [];
  const check = (name, ok, detail) => results.push({ name, ok, detail: detail || '' });

  const inject = (method, url, token, payload) =>
    app.inject({
      method,
      url,
      headers: token ? { authorization: 'Bearer ' + token } : undefined,
      payload,
    });

  const devToken = async (scopes, sub = 'admin') =>
    (await inject('POST', '/api/v1/auth/dev-token', '', { sub, scopes })).json().token;

  const admin = await devToken(['*'], 'admin');
  const writer = await devToken(['mediatool:read', 'mediatool:write'], 'writer');
  const reader = await devToken(['mediatool:read'], 'reader');

  const waitJob = async (id, timeoutMs = 90_000) => {
    const t0 = Date.now();
    for (;;) {
      const r = await inject('GET', '/api/v1/media-tool/jobs?limit=50', admin);
      const job = (r.json().items || []).find((x) => x.id === id);
      if (!job) throw new Error('job vanished: ' + id);
      if (['done', 'failed', 'canceled'].includes(job.status)) return job;
      if (Date.now() - t0 > timeoutMs) throw new Error('job timeout: ' + job.status);
      await new Promise((res) => setTimeout(res, 200));
    }
  };

  const mediaReady = k.media.available();

  const waitTask = async (id, token = admin, timeoutMs = 90_000) => {
    const t0 = Date.now();
    for (;;) {
      const res = await inject('GET', '/api/v1/media-tool/tasks/get?id=' + id, token);
      if (res.statusCode !== 200) throw new Error('task get failed: ' + res.statusCode);
      const task = res.json();
      if (['done', 'failed', 'stopped', 'canceled'].includes(task.status)) return task;
      if (Date.now() - t0 > timeoutMs) throw new Error('task timeout: ' + task.status);
      await new Promise((res2) => setTimeout(res2, 200));
    }
  };

  // ---- 鉴权 ----
  let r = await inject('GET', '/api/v1/media-tool/jobs');
  check('jobs_anonymous_401', r.statusCode === 401, 'status=' + r.statusCode);

  r = await inject('POST', '/api/v1/media-tool/thumbnails', reader, { source: 'src' });
  check('thumbnails_reader_403', r.statusCode === 403, 'status=' + r.statusCode);

  // ---- 路径与入参约束 ----
  r = await inject('POST', '/api/v1/media-tool/thumbnails', admin, { source: '../../etc' });
  check('source_escape_403', r.statusCode === 403, 'status=' + r.statusCode);

  r = await inject('POST', '/api/v1/media-tool/thumbnails', admin, { source: 'src/a.png' });
  check('source_not_dir_400', r.statusCode === 400, 'status=' + r.statusCode);

  r = await inject('POST', '/api/v1/media-tool/transcode', admin, {
    source: 'src/a.png',
    target: 'src/a.png',
  });
  check('transcode_same_target_400', r.statusCode === 400, 'status=' + r.statusCode);

  r = await inject('POST', '/api/v1/media-tool/transcode', admin, {
    source: 'src/missing.png',
    target: 'out/missing.jpg',
  });
  check('transcode_missing_400', r.statusCode === 400, 'status=' + r.statusCode);

  // ---- 批量缩略图 ----
  r = await inject('POST', '/api/v1/media-tool/thumbnails', admin, { source: 'src', size: 64 });
  const thumbJob = r.json();

  check(
    'thumbnails_enqueue',
    r.statusCode === 200 && typeof thumbJob.id === 'string',
    r.statusCode === 200 ? 'id=' + thumbJob.id : 'status=' + r.statusCode,
  );

  if (r.statusCode === 200) {
    const job = await waitJob(thumbJob.id);
    if (mediaReady) {
      const out = path.join(filesRoot, 'media-thumbnails', thumbJob.id, 'a.jpg');
      const outB = path.join(filesRoot, 'media-thumbnails', thumbJob.id, 'b.jpg');
      check(
        'thumbnails_done',
        job.status === 'done' && job.total === 2 && job.done === 2 && job.failed === 0,
        `status=${job.status} total=${job.total} done=${job.done} failed=${job.failed}`,
      );
      check('thumbnails_output', fs.existsSync(out) && fs.existsSync(outB), 'jpg written');
      // txt 不在图片白名单内，不会被处理
      check('thumbnails_skip_non_image', job.total === 2, 'total=' + job.total);
    } else {
      check('thumbnails_no_ffmpeg_failed', job.status === 'failed', 'status=' + job.status);
    }
  }

  // ---- 取消 ----
  r = await inject('POST', '/api/v1/media-tool/thumbnails', admin, { source: 'src' });
  if (r.statusCode === 200) {
    const id = r.json().id;

    const cancel = await inject('POST', '/api/v1/media-tool/jobs/cancel', admin, { id });
    const job = await waitJob(id);
    check(
      'cancel_job',
      cancel.statusCode === 200 && job.status === 'canceled',
      'status=' + job.status,
    );
  } else if (r.statusCode === 503) {
    check('cancel_job', true, 'skipped: media unavailable');
  } else {
    check('cancel_job', false, 'status=' + r.statusCode);
  }

  r = await inject('POST', '/api/v1/media-tool/jobs/cancel', admin, { id: 'nope' });
  check('cancel_unknown_404', r.statusCode === 404, 'status=' + r.statusCode);

  // ---- 转码 ----
  r = await inject('POST', '/api/v1/media-tool/transcode', admin, {
    source: 'src/a.png',
    target: 'out/a.jpg',
    preset: 'copy',
  });
  if (r.statusCode === 200) {
    const job = await waitJob(r.json().id);
    if (mediaReady) {
      check(
        'transcode_job',
        job.status === 'done' &&
          job.total === 1 &&
          fs.existsSync(path.join(filesRoot, 'out', 'a.jpg')),
        'status=' + job.status,
      );
    } else {
      check('transcode_job', job.status === 'failed', 'status=' + job.status);
    }
  } else if (r.statusCode === 503) {
    check('transcode_job', true, 'skipped: media unavailable');
  } else {
    check('transcode_job', false, 'status=' + r.statusCode);
  }

  // ---- 列表 / 过滤 ----
  r = await inject('GET', '/api/v1/media-tool/jobs?status=done', admin);
  const doneItems = r.json().items || [];
  check(
    'jobs_filter_status',
    r.statusCode === 200 && doneItems.every((x) => x.status === 'done'),
    'items=' + doneItems.length,
  );

  r = await inject('GET', '/api/v1/media-tool/jobs', reader);
  check('jobs_reader_can_read', r.statusCode === 200, 'status=' + r.statusCode);

  // ---- 统一任务表（M1/M7）：管理员门槛 + 账号隔离 + 启停/删除 ----
  r = await inject('POST', '/api/v1/media-tool/tasks/upsert', writer, {
    kind: 'video',
    source: 'src/a.png',
    target: 'out2',
  });
  check('writer_video_403', r.statusCode === 403, 'status=' + r.statusCode);

  r = await inject('POST', '/api/v1/media-tool/tasks/upsert', writer, {
    kind: 'image',
    source: 'src/a.png',
    target: 'imgout',
    config: { format: 'png', quality: 80, size: 0, policy: 'skip' },
  });
  const writerTask = r.statusCode === 200 ? await waitTask(r.json().id, writer) : null;
  check(
    'writer_image_allowed',
    r.statusCode === 200 &&
      (mediaReady ? writerTask.status === 'done' && writerTask.processed === 1 : writerTask.status === 'failed'),
    r.statusCode === 200 ? `status=${writerTask.status} processed=${writerTask.processed}` : 'status=' + r.statusCode,
  );
  if (mediaReady) {
    check(
      'image_output',
      fs.existsSync(path.join(filesRoot, 'imgout', 'a.png')),
      'imgout/a.png',
    );
  }

  // ---- M6 图片压缩：输出打包 zip ----
  fs.mkdirSync(path.join(filesRoot, 'imgzip-src'), { recursive: true });
  fs.writeFileSync(path.join(filesRoot, 'imgzip-src', 'z.png'), PNG);
  r = await inject('POST', '/api/v1/media-tool/tasks/upsert', admin, {
    kind: 'image',
    source: 'imgzip-src',
    target: 'imgzip-out',
    config: { format: 'png', quality: 80, size: 0, policy: 'skip', zip: true },
  });
  check('image_zip_upsert', r.statusCode === 200, 'status=' + r.statusCode);
  if (r.statusCode === 200) {
    const task = await waitTask(r.json().id, admin);
    const zipPath = path.join(filesRoot, 'imgzip-out.zip');
    const hasZip = fs.existsSync(zipPath);
    const head = hasZip ? fs.readFileSync(zipPath).subarray(0, 4).toString('hex') : '';
    check(
      'image_zip',
      mediaReady
        ? task.status === 'done' && hasZip && head === '504b0304'
        : ['done', 'failed'].includes(task.status),
      `status=${task.status} zip=${hasZip} head=${head}`,
    );
  } else {
    check('image_zip', false, 'no task');
  }

  r = await inject('POST', '/api/v1/media-tool/tasks/upsert', admin, {
    kind: 'image',
    source: 'imgzip-src',
    target: '.',
    config: { zip: true },
  });
  check('image_zip_root_400', r.statusCode === 400, 'status=' + r.statusCode);

  // ---- M6 上传：分块通道可落到 media-uploads/ ----
  const upPath = 'media-uploads/smoke/z.png';
  r = await inject('POST', '/api/v1/files/check', admin, { path: upPath, size: PNG.length });
  const chunkSize = r.statusCode === 200 ? r.json().chunkSize : 0;
  const chunkRes = await app.inject({
    method: 'POST',
    url: '/api/v1/files/chunk?path=' + encodeURIComponent(upPath) + '&index=0&total=1',
    headers: {
      authorization: 'Bearer ' + admin,
      'content-type': 'application/octet-stream',
    },
    payload: PNG,
  });
  const mergeRes = await inject('POST', '/api/v1/files/merge', admin, {
    path: upPath,
    total: 1,
    size: PNG.length,
  });
  const upAbs = path.join(filesRoot, 'media-uploads', 'smoke', 'z.png');
  check(
    'upload_chunked',
    r.statusCode === 200 &&
      chunkSize > 0 &&
      chunkRes.statusCode === 200 &&
      mergeRes.statusCode === 200 &&
      fs.existsSync(upAbs) &&
      fs.statSync(upAbs).size === PNG.length,
    `check=${r.statusCode} chunk=${chunkRes.statusCode} merge=${mergeRes.statusCode} size=${
      fs.existsSync(upAbs) ? fs.statSync(upAbs).size : -1
    }`,
  );

  r = await inject('GET', '/api/v1/media-tool/tasks', reader);
  check(
    'task_uid_isolation',
    r.statusCode === 200 && (r.json().items || []).length === 0,
    'items=' + (r.json().items || []).length,
  );

  r = await inject('POST', '/api/v1/media-tool/tasks/upsert', admin, {
    kind: 'thumbnails',
    source: 'src',
    target: 'thumb-tasks',
    config: { size: 64 },
  });
  const adminTaskId = r.statusCode === 200 ? r.json().id : '';
  check('task_upsert_admin', r.statusCode === 200, 'status=' + r.statusCode);
  if (adminTaskId) {
    const task = await waitTask(adminTaskId);
    check(
      'task_done_stats',
      task.status === 'done' && task.total === 2 && task.processed === 2 && task.progress === 1,
      `status=${task.status} total=${task.total} processed=${task.processed}`,
    );
    r = await inject('POST', '/api/v1/media-tool/tasks/delete', admin, { id: adminTaskId });
    check('task_delete', r.statusCode === 200 && r.json().ok === true, 'status=' + r.statusCode);
    r = await inject('GET', '/api/v1/media-tool/tasks/get?id=' + adminTaskId, admin);
    check('task_deleted_404', r.statusCode === 404, 'status=' + r.statusCode);
  }

  // ---- 媒体整理：按年归档 ----
  fs.mkdirSync(path.join(filesRoot, 'arrange-src'), { recursive: true });
  fs.writeFileSync(path.join(filesRoot, 'arrange-src', 'one.txt'), 'x');
  fs.mkdirSync(path.join(filesRoot, 'arrange-dst'), { recursive: true });
  r = await inject('POST', '/api/v1/media-tool/tasks/upsert', admin, {
    kind: 'arrange',
    source: 'arrange-src',
    target: 'arrange-dst',
    config: { by: 'year', sameName: 'skip' },
  });
  if (r.statusCode === 200) {
    const task = await waitTask(r.json().id);
    const y = String(new Date().getFullYear());
    check(
      'arrange_by_year',
      task.status === 'done' &&
        fs.existsSync(path.join(filesRoot, 'arrange-dst', y, 'one.txt')),
      `status=${task.status} year=${y}`,
    );
  } else {
    check('arrange_by_year', false, 'status=' + r.statusCode);
  }

  await app.close();
  try { fs.rmSync(dataDir, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 }); } catch { /* 句柄释放有延迟 */ }

  let failed = 0;
  for (const x of results) {
    console.log(`${x.ok ? '[OK]  ' : '[FAIL]'} ${x.name.padEnd(30)} ${x.detail}`);
    if (!x.ok) failed++;
  }
  console.log(
    `[summary] ${results.length - failed}/${results.length} passed (media ready=${mediaReady})`,
  );
  process.exit(failed ? 1 : 0);
})().catch((e) => {
  console.error('[FATAL]', e);
  process.exit(1);
});
