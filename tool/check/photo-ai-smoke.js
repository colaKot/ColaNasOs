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

  // 2026-11-06 回归：识别完成标记 + 暂停/恢复重新入队。
  // 以前「恢复」只改 paused 配置，任务在暂停时已 break 成 done，队列彻底空掉，
  // 重启也不会重新入队 —— 表现就是任务栏一直显示空闲。
  const maskCol = await sql`select ai_done_mask from photo_items limit 1`
    .execute(k.db)
    .then(() => true)
    .catch(() => false);
  check('ai_done_mask_column', maskCol, 'photo_items.ai_done_mask');

  // 模型可用时前面的 analyze 已经把 a/b 标成完成，这里留一张待办，
  // 保证「恢复」确实有活可入队（不受模型是否安装影响）。
  await sql`
    update photo_items set ai_done_mask = 0, ai_skip_at = 0 where rel_path like '%a.jpg'
  `.execute(k.db);

  const paused = await inject('POST', '/api/v1/photo/ai/queue/pause', admin, { paused: true });
  check(
    'ai_queue_pause',
    paused.statusCode === 200 && paused.json().paused === true,
    'status=' + paused.statusCode,
  );
  // 模拟暂停时任务检测 paused 后 break（任务变 done、队列不再有活）
  await sql`
    update tasks set state='done' where type='photo.ai.scan' and state in ('pending','running')
  `.execute(k.db);
  const resumed = await inject('POST', '/api/v1/photo/ai/queue/pause', admin, { paused: false });
  const active = (
    await sql`
      select count(*) as n from tasks
       where type='photo.ai.scan' and state in ('pending','running')
    `.execute(k.db)
  ).rows[0];
  check(
    'ai_queue_resume_requeues',
    resumed.statusCode === 200 && Number(active?.n || 0) > 0,
    `status=${resumed.statusCode} active=${Number(active?.n || 0)}`,
  );

  const cfg = await inject('GET', '/api/v1/photo/ai/config', admin);
  const jobs = cfg.statusCode === 200 ? cfg.json().queue.jobs : [];
  check(
    'ai_config_shows_running',
    cfg.statusCode === 200 && jobs.some((j) => j.status === 'running'),
    'jobs=' + JSON.stringify(jobs.map((j) => j.status)),
  );

  // 2026-11-06 回归：人脸认领护栏。
  // 这一组是纯计算，不依赖模型是否安装 —— 真机上「几百张假人物组」就是这些门缺失导致的。
  const faceMod = require(path.join(root, 'dist', 'src', 'modules', 'photo', 'ai', 'face.js'));
  const { EMB_DIM } = require(path.join(root, 'dist', 'src', 'modules', 'photo', 'ai', 'schemas.js'));
  let seed = 20261106;
  const rnd = () => { seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0; return seed / 4294967296; };
  const unit = (v) => {
    let n = 0;
    for (const x of v) n += x * x;
    n = Math.sqrt(n) || 1;
    return Float32Array.from(v, (x) => x / n);
  };
  const baseVec = () => unit(Array.from({ length: EMB_DIM }, () => rnd() - 0.5));
  const near = (b, eps) => unit(Array.from(b, (x) => x + (rnd() - 0.5) * eps));
  const mix = (a, b, wa, wb) => unit(Array.from(a, (x, i) => x * wa + b[i] * wb));

  const eng = new faceMod.FaceVectorIndex();
  eng.markLoaded();
  const P = faceMod.claimParams();
  let fid = 0;
  const claim = (vec, quality, opts = {}) => {
    const d = eng.claim(vec, {
      quality,
      params: P,
      usedClusterIds: opts.used,
      poseYaw: opts.yaw,
      shortlist: 0,
    });
    if (d.clusterId) {
      fid += 1;
      eng.add('f' + fid, d.clusterId, vec, quality, 'p' + fid);
    }
    return d;
  };

  const A = baseVec();
  const B = baseVec();
  const C = baseVec();
  const D = baseVec();

  const ga = claim(near(A, 0.04), 90).clusterId;
  check('claim_first_creates_group', !!ga, 'group=' + String(ga).slice(0, 8));
  check('claim_cold_start', claim(near(A, 0.04), 90).clusterId === ga, 'cold start -> same group');
  check('claim_votes', claim(near(A, 0.04), 90).clusterId === ga, '2+ votes -> same group');

  const held = claim(near(A, 0.04), 60);
  const held2 = claim(near(A, 0.04), 60);
  check(
    'claim_low_quality_hold',
    held.reason === 'low_quality_hold' && held2.clusterId !== held.clusterId,
    `held=${held.reason} second=${held2.reason}`,
  );
  const posed = claim(near(A, 0.04), 95, { yaw: 0.8 });
  check('claim_pose_hold', posed.reason === 'pose_hold', 'reason=' + posed.reason);
  const dropped = claim(near(A, 0.04), 40);
  check('claim_min_quality_drop', dropped.clusterId === null, 'reason=' + dropped.reason);
  const samePhoto = claim(near(A, 0.04), 90, { used: new Set([ga]) });
  check('claim_same_photo_mutex', samePhoto.clusterId !== ga, 'cluster=' + String(samePhoto.clusterId).slice(0, 8));

  // 低质量邻居不投票：3 张低分 + 1 张高分同组，新脸若让低分投票就会误认领
  const gq = 'low-vote-group';
  eng.add('q1', gq, near(C, 0.04), 60, 'pq1');
  eng.add('q2', gq, near(C, 0.04), 60, 'pq2');
  eng.add('q3', gq, near(C, 0.04), 60, 'pq3');
  eng.add('q4', gq, near(C, 0.04), 90, 'pq4');
  const voteTest = claim(near(C, 0.04), 90);
  check('claim_low_quality_no_vote', voteTest.clusterId !== gq, 'reason=' + voteTest.reason);

  // 组中心一致性门：与成员都有 0.5 相似度（够投票），但离组中心 < 0.58 ⇒ 拒绝
  const gh = 'consistency-group';
  eng.add('h1', gh, near(D, 0.02), 90, 'ph1');
  eng.add('h2', gh, near(D, 0.02), 90, 'ph2');
  eng.add('h3', gh, near(D, 0.02), 90, 'ph3');
  const outlier = claim(mix(D, B, 0.5, 0.866), 90);
  check('claim_consistency_gate', outlier.reason === 'rejected', 'reason=' + outlier.reason);

  // 全局平均脸分量：两个只有「公共分量」相同的向量，原始余弦接近 1，
  // 去掉公共分量后必须变成负相关 —— 否则大簇质心会变成吸附一切的黑洞。
  const hubEng = new faceMod.FaceVectorIndex();
  hubEng.markLoaded();
  const common = unit(Array.from({ length: EMB_DIM }, () => 1));
  const ortho = unit(Array.from({ length: EMB_DIM }, (_, i) => (i % 2 ? 1 : -1)));
  const v1 = unit(Array.from(common, (x, i) => x * 0.9 + ortho[i] * 0.1));
  const v2 = unit(Array.from(common, (x, i) => x * 0.9 - ortho[i] * 0.1));
  const rawSim = Array.from(v1).reduce((s, x, i) => s + x * v2[i], 0);
  hubEng.setMean(common);
  const centeredSim = hubEng.dotVec(hubEng.centerVec(v1), hubEng.centerVec(v2));
  check(
    'claim_center_removes_hub',
    rawSim > 0.6 && centeredSim < 0.1,
    `raw=${rawSim.toFixed(3)} centered=${centeredSim.toFixed(3)}`,
  );

  const guardCols = (
    await sql`pragma table_info(photo_faces)`.execute(k.db)
  ).rows.map((x) => x.name);
  check(
    'face_guard_columns',
    ['quality', 'pose_yaw', 'pose_roll', 'pose_iod'].every((c) => guardCols.includes(c)),
    'cols=' + guardCols.filter((c) => c.startsWith('pose_') || c === 'quality').join(','),
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
