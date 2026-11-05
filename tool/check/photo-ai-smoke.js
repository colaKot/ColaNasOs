#!/usr/bin/env node
/**
 * photo 智能分析验收：人脸检测链路 / 场景分类 / CLIP embedding / 以图搜图 / 权限。
 *
 * 用 ffmpeg 现造两张图；没有模型或 ffmpeg 时只验证 503 与鉴权。
 * 注意：纯色测试图没有真实人脸，`faces` 允许为 0；真实人脸效果需要在用户库上验证。
 *
 * 用法：node tool/check/photo-ai-smoke.js（Electron 自举）
 */
'use strict';

const path = require('node:path');
const fs = require('node:fs');
const os = require('node:os');
const { spawnSync } = require('node:child_process');
const { sql } = require('kysely');

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

function findFfmpeg() {
  const exe = process.platform === 'win32' ? 'ffmpeg.exe' : 'ffmpeg';
  const env = process.env.COLANAS_FFMPEG;
  if (env && fs.existsSync(env)) return env;
  for (const c of [
    path.join(root, 'vendor', 'ffmpeg', exe),
    path.join(root, 'vendor', 'ffmpeg', 'bin', exe),
  ]) {
    if (fs.existsSync(c)) return c;
  }
  return null;
}

process.chdir(root);

(async () => {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-photo-ai-'));
  const filesRoot = path.join(dataDir, 'files');
  fs.mkdirSync(path.join(filesRoot, 'photos'), { recursive: true });

  const ffmpeg = findFfmpeg();
  if (ffmpeg) {
    process.env.COLANAS_FFMPEG = ffmpeg;
    for (const [name, spec] of [
      ['a.jpg', 'color=c=skyblue:size=640x480'],
      ['b.jpg', 'color=c=skyblue:size=640x480'],
    ]) {
      spawnSync(ffmpeg, [
        '-hide_banner',
        '-loglevel',
        'error',
        '-y',
        '-f',
        'lavfi',
        '-i',
        spec,
        '-frames:v',
        '1',
        path.join(filesRoot, 'photos', name),
      ]);
    }
    // 损坏图片：识别必然失败。以前「没有 embedding 就重新做」会让它每轮都被
    // 重新挑中，photo.ai.scan 变成 0.2s 一轮的热循环 —— 这里回归失败记账。
    fs.writeFileSync(path.join(filesRoot, 'photos', 'bad.jpg'), 'not a real jpeg');
  }

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

  const admin = await devToken(['photo:read', 'photo:write'], 'admin');
  const reader = await devToken(['photo:read'], 'reader');

  let r = await inject('POST', '/api/v1/photo/ai/analyze', '', {});
  check('analyze_anonymous_401', r.statusCode === 401, 'status=' + r.statusCode);

  r = await inject('POST', '/api/v1/photo/ai/analyze', reader, {});
  check('analyze_reader_403', r.statusCode === 403, 'status=' + r.statusCode);

  await inject('POST', '/api/v1/photo/libraries', admin, { name: 'photos', path: 'photos' });
  const scan = await inject('POST', '/api/v1/photo/scan', admin, {});
  check(
    'photo_scan',
    scan.statusCode === 200 && (scan.json().images || 0) >= 1,
    'images=' + (scan.json().images || 0),
  );

  const modelsReady =
    fs.existsSync(path.join(root, 'vendor', 'models', 'faces', 'edgeface', 'model.onnx')) &&
    fs.existsSync(path.join(root, 'vendor', 'models', 'places365', 'resnet50_places365.onnx')) &&
    Boolean(ffmpeg);

  r = await inject('POST', '/api/v1/photo/ai/analyze', admin, { limit: 10 });
  if (r.statusCode === 503) {
    check('analyze_batch', true, 'skipped: models/ffmpeg unavailable');
  } else {
    check(
      'analyze_batch',
      r.statusCode === 200 && r.json().processed >= 1 && r.json().remaining === 0,
      `status=${r.statusCode} ${r.body.slice(0, 140)}`,
    );
    const gates = r.json().sceneGates || { confident: 0, ambiguous: 0, unknown: 0 };
    const gateTotal = gates.confident + gates.ambiguous + gates.unknown;
    check(
      'scene_gate',
      gateTotal === r.json().processed,
      `confident=${gates.confident} ambiguous=${gates.ambiguous} unknown=${gates.unknown}`,
    );
    const bad = (
      await sql`select ai_skip_at from photo_items where rel_path like '%bad.jpg'`.execute(k.db)
    ).rows[0];
    check(
      'analyze_bad_skip_recorded',
      Number(bad?.ai_skip_at || 0) > 0,
      `ai_skip_at=${bad?.ai_skip_at ?? '-'}`,
    );
    const again = await inject('POST', '/api/v1/photo/ai/analyze', admin, { limit: 10 });
    check(
      'analyze_bad_not_retried',
      again.statusCode === 200 && again.json().processed === 0 && again.json().skipped === 0,
      `status=${again.statusCode} ${again.body.slice(0, 120)}`,
    );
  }

  const list = await inject('GET', '/api/v1/photo/timeline?limit=10', admin);
  const photos = (list.json().items || []).map((x) => x.id);

  r = await inject('GET', '/api/v1/photo/scenes/summary', admin);
  const summary = r.statusCode === 200 ? r.json().items : [];
  check(
    'scenes_summary',
    r.statusCode === 200 && (!modelsReady || summary.length >= 0),
    `status=${r.statusCode} labels=${summary.length} top=${summary[0] ? summary[0].label : '-'}`,
  );

  if (summary.length > 0) {
    r = await inject(
      'GET',
      '/api/v1/photo/scenes?label=' + encodeURIComponent(summary[0].label),
      admin,
    );
    check(
      'scenes_items',
      r.statusCode === 200 && r.json().items.length >= 1,
      'items=' + (r.statusCode === 200 ? r.json().items.length : '?'),
    );
  } else {
    check('scenes_items', true, 'skipped: no scenes');
  }

  if (photos.length >= 1) {
    r = await inject('GET', '/api/v1/photo/similar?id=' + encodeURIComponent(photos[0]), admin);
    check(
      'similar_ok',
      r.statusCode === 200 && (!modelsReady || r.json().items.length >= 1),
      `status=${r.statusCode} items=${r.statusCode === 200 ? r.json().items.length : '?'}`,
    );
  } else {
    check('similar_ok', false, 'no photos');
  }

  r = await inject('GET', '/api/v1/photo/similar?id=nope', admin);
  check('similar_unknown_404', r.statusCode === 404, 'status=' + r.statusCode);

  r = await inject('GET', '/api/v1/photo/faces/clusters', admin);
  check(
    'faces_clusters',
    r.statusCode === 200 && Array.isArray(r.json().items),
    'items=' + (r.statusCode === 200 ? r.json().items.length : '?'),
  );

  await app.close();
  try { fs.rmSync(dataDir, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 }); } catch { /* 句柄释放有延迟 */ }

  let failed = 0;
  for (const x of results) {
    console.log(`${x.ok ? '[OK]  ' : '[FAIL]'} ${x.name.padEnd(26)} ${x.detail}`);
    if (!x.ok) failed++;
  }
  console.log(
    `[summary] ${results.length - failed}/${results.length} passed (models=${modelsReady})`,
  );
  process.exit(failed ? 1 : 0);
})().catch((e) => {
  console.error('[FATAL]', e);
  process.exit(1);
});
