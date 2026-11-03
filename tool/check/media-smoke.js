#!/usr/bin/env node
/**
 * media 验收（SP2-03）：
 *  1. 缩略图生成成功且尺寸正确
 *  2. 500 张基准跑完并给出吞吐
 *  3. 转码会话复用：同一任务并发请求只启动一次 ffmpeg
 *
 * 找不到 ffmpeg 时打印 SKIP 并以 0 退出（CI 不阻断）。
 * 用法：node tool/check/media-smoke.js [--count 500]
 */
'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const root = path.join(__dirname, '..', '..');

function existsp(p) {
  try {
    return fs.existsSync(p);
  } catch {
    return false;
  }
}

function probeFfmpeg() {
  const cands = [];
  if (process.env.COLANAS_FFMPEG) cands.push(process.env.COLANAS_FFMPEG);
  cands.push(process.platform === 'win32' ? 'ffmpeg.exe' : 'ffmpeg');
  for (const prefix of ['C:/Program Files', 'C:/Program Files (x86)']) {
    try {
      for (const d of fs.readdirSync(prefix)) {
        if (/imagemagick/i.test(d)) cands.push(path.join(prefix, d, 'ffmpeg.exe'));
      }
    } catch {
      /* 目录不存在 */
    }
  }
  for (const c of cands) {
    const r = spawnSync(c, ['-version'], { encoding: 'utf8', windowsHide: true });
    if (r.status === 0 && /ffmpeg version/i.test(r.stdout || '')) return c;
  }
  return null;
}

const ffmpeg = probeFfmpeg();
if (!ffmpeg) {
  console.log('[SKIP] ffmpeg 不可用（设置 COLANAS_FFMPEG 后可跑缩略图/转码验收）');
  process.exit(0);
}

const { SidecarSupervisor } = require(path.join(root, 'dist', 'kernel', 'sidecar', 'supervisor'));

const results = [];
const check = (name, ok, detail) => results.push({ name, ok, detail: detail || '' });
const COUNT = Number((process.argv.find((a) => a.startsWith('--count=')) || '').split('=')[1]) || 500;

function ff(args) {
  const r = spawnSync(ffmpeg, args, { encoding: 'utf8', windowsHide: true });
  if (r.status !== 0) throw new Error('ffmpeg 素材生成失败: ' + (r.stderr || '').slice(-300));
}

(async () => {
  const work = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-media-'));
  const srcImg = path.join(work, 'src.jpg');
  const srcVideo = path.join(work, 'src.mp4');
  const thumbDir = path.join(work, 'thumbs');

  ff(['-hide_banner', '-loglevel', 'error', '-y', '-f', 'lavfi', '-i', 'testsrc=size=1920x1080:rate=1', '-frames:v', '1', '-q:v', '2', srcImg]);
  ff(['-hide_banner', '-loglevel', 'error', '-y', '-f', 'lavfi', '-i', 'testsrc=size=640x360:rate=30', '-t', '2', '-c:v', 'libx264', '-preset', 'ultrafast', srcVideo]);

  const sup = new SidecarSupervisor({
    name: 'media',
    command: process.env.COLANAS_SIDECAR_NODE || process.execPath,
    args: [path.join(root, 'sidecars', 'media', 'main.js')],
    requestTimeoutMs: 180_000,
    heartbeatMs: 10_000,
    maxRestarts: 2,
    startTimeoutMs: 15_000,
    stopGraceMs: 3_000,
    log: () => {},
    env: { COLANAS_FFMPEG: ffmpeg },
  });

  await sup.start();
  check('start_ready', sup.state === 'ready', 'pid=' + sup.pid + ' ffmpeg=' + ffmpeg);

  const one = await sup.request('thumb', { src: srcImg, dst: path.join(work, 'one.jpg'), size: 256 });
  const dims = spawnSync(ffmpeg, ['-hide_banner', '-i', path.join(work, 'one.jpg')], { encoding: 'utf8', windowsHide: true });
  const m = /(\d{2,5})x(\d{2,5})/.exec(dims.stderr || '');
  check(
    'thumb_single',
    existsp(one.dst) && m && Number(m[1]) === 256,
    `dst=${one.dst} ${m ? m[1] + 'x' + m[2] : 'dims?'} ${one.ms.toFixed(0)}ms`,
  );

  const bench = await sup.request('bench', { src: srcImg, dir: thumbDir, count: COUNT, size: 256 });
  check(
    'thumb_bench',
    bench.count === COUNT && bench.throughput > 0,
    `count=${bench.count} ms=${bench.ms.toFixed(0)} throughput=${bench.throughput.toFixed(1)}/s conc=${bench.concurrency}`,
  );

  const outA = path.join(work, 'out-a.mp4');
  const [t1, t2] = await Promise.all([
    sup.request('transcode', { src: srcVideo, dst: outA, preset: 'web720' }),
    sup.request('transcode', { src: srcVideo, dst: outA, preset: 'web720' }),
  ]);
  const st = await sup.request('stats');
  check(
    'transcode_reuse',
    existsp(outA) && st.transcodes === 1 && st.reused >= 1 && (t1.reused || t2.reused),
    `transcodes=${st.transcodes} reused=${st.reused}`,
  );

  const bad = await sup
    .request('transcode', { src: path.join(work, 'nope.mp4'), dst: path.join(work, 'x.mp4') })
    .then(() => null)
    .catch((e) => e.code);
  check('missing_src', bad === 'E_NO_SRC', 'code=' + bad);

  await sup.stop();
  fs.rmSync(work, { recursive: true, force: true });

  let failed = 0;
  for (const x of results) {
    console.log(`${x.ok ? '[OK]  ' : '[FAIL]'} ${x.name.padEnd(20)} ${x.detail}`);
    if (!x.ok) failed++;
  }
  console.log(`[bench] ${JSON.stringify({ thumb500: bench })}`);
  console.log(`[summary] ${results.length - failed}/${results.length} passed`);
  process.exit(failed ? 1 : 0);
})().catch((e) => {
  console.error('[FATAL]', e);
  process.exit(1);
});