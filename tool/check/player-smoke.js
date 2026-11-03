#!/usr/bin/env node
/**
 * videoPlayer 验收：HLS 转码会话 / 字幕烧录入参校验 / 分片访问 / 权限。
 *
 * 用 ffmpeg 的 lavfi 现造 2 s 测试视频（不依赖外部素材）；没有 ffmpeg 时只验证 503 与鉴权。
 *
 * 用法：node tool/check/player-smoke.js（Electron 自举）
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
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-player-'));
  const filesRoot = path.join(dataDir, 'files');
  fs.mkdirSync(path.join(filesRoot, 'media'), { recursive: true });

  const ffmpeg = findFfmpeg();
  if (ffmpeg) {
    process.env.COLANAS_FFMPEG = ffmpeg;
    const made = spawnSync(ffmpeg, [
      '-hide_banner',
      '-loglevel',
      'error',
      '-y',
      '-f',
      'lavfi',
      '-i',
      'testsrc=size=320x240:rate=24',
      '-t',
      '2',
      '-pix_fmt',
      'yuv420p',
      path.join(filesRoot, 'media', 'demo.mp4'),
    ]);
    if (made.status !== 0) console.error('[warn] lavfi 生成测试视频失败');
  }
  // 外挂字幕（烧录用）
  fs.writeFileSync(
    path.join(filesRoot, 'media', 'demo.srt'),
    '1\n00:00:00,000 --> 00:00:01,000\nhello burn-in\n\n',
  );

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

  const admin = await devToken(
    ['player:read', 'player:write', 'video:read', 'video:write'],
    'admin',
  );
  const reader = await devToken(['player:read', 'video:read'], 'reader');
  const mediaReady = k.media.available();

  // ---- 建库 + 扫描（拿到 video_items 行） ----
  await inject('POST', '/api/v1/video/libraries', admin, { name: 'demo', path: 'media' });
  await inject('POST', '/api/v1/video/scan', admin, {});
  let list = await inject('GET', '/api/v1/video/list?limit=10', admin);
  const items = list.json().items || [];
  check('scan_has_item', items.length >= 1, 'items=' + items.length);
  const itemId = items[0] && items[0].id;

  // ---- 鉴权与入参 ----
  let r = await inject('POST', '/api/v1/player/sessions', '', { id: itemId });
  check('session_anonymous_401', r.statusCode === 401, 'status=' + r.statusCode);

  r = await inject('POST', '/api/v1/player/sessions', reader, { id: itemId });
  check('session_reader_403', r.statusCode === 403, 'status=' + r.statusCode);

  r = await inject('POST', '/api/v1/player/sessions', admin, { id: 'nope' });
  check(
    'session_unknown_404',
    r.statusCode === 404,
    'status=' + r.statusCode + ' ' + r.body.slice(0, 160),
  );

  r = await inject('POST', '/api/v1/player/sessions', admin, {
    id: itemId,
    subtitle: '../evil.srt',
  });
  check(
    'session_bad_subtitle_400',
    r.statusCode === 400,
    'status=' + r.statusCode + ' ' + r.body.slice(0, 160),
  );

  // ---- 建会话并等完成 ----
  r = await inject('POST', '/api/v1/player/sessions', admin, { id: itemId, subtitle: 'demo.srt' });
  if (r.statusCode === 503) {
    check('session_create', true, 'skipped: media unavailable');
  } else {
    check(
      'session_create',
      r.statusCode === 200 && r.json().id,
      'status=' + r.statusCode + ' ' + r.body.slice(0, 160),
    );
    if (r.statusCode === 200) {
      const id = r.json().id;
      let job;
      const t0 = Date.now();
      for (;;) {
        const s = await inject(
          'GET',
          `/api/v1/player/sessions?id=${encodeURIComponent(id)}`,
          admin,
        );
        job = s.json();
        if (job.status === 'done' || job.status === 'failed') break;
        if (Date.now() - t0 > 120_000) break;
        await new Promise((res) => setTimeout(res, 300));
      }
      check(
        'session_done',
        job && job.status === 'done',
        `status=${job && job.status} err=${job && job.error}`,
      );
      if (job && job.status === 'done') {
        check('session_segments', job.segments >= 1, 'segments=' + job.segments);
        check('session_url', job.url.startsWith(`/api/v1/player/hls/${id}/index.m3u8?t=`), job.url);

        // 响度归一：库开关打开后转码仍必须成功 —— 滤镜名或参数写错会直接 failed，
        // 所以这条同时验证了「库开关 → pump → sidecar → ffmpeg -af」这条链是通的
        const libs = (await inject('GET', '/api/v1/video/libraries', admin)).json().items || [];
        const libId = libs[0] && libs[0].id;
        if (libId) {
          await inject('POST', '/api/v1/video/libraries/flags', admin, {
            id: libId,
            audioNormalize: true,
          });
          const rNorm = await inject('POST', '/api/v1/player/sessions', admin, { id: itemId });
          const idNorm = rNorm.json().id;
          let jobNorm = null;
          for (let i = 0; i < 120; i += 1) {
            const q = await inject('GET', '/api/v1/player/sessions?id=' + idNorm, admin);
            jobNorm = q.json();
            if (jobNorm.status === 'done' || jobNorm.status === 'failed') break;
            await new Promise((res) => setTimeout(res, 300));
          }
          check(
            'session_audio_normalize',
            Boolean(jobNorm) && jobNorm.status === 'done',
            `status=${jobNorm && jobNorm.status} err=${jobNorm && jobNorm.error}`,
          );
          await inject('POST', '/api/v1/video/libraries/flags', admin, {
            id: libId,
            audioNormalize: false,
          });
        }

        // 按编码分档：h265 应产出 fMP4（带 EXT-X-MAP）；编码不可用时自动降级 h264
        r = await inject('POST', '/api/v1/player/sessions', admin, {
          id: itemId,
          preset: 'web1080',
          codec: 'h265',
        });
        const id2 = r.json().id;
        let job2 = null;
        for (let i = 0; i < 120; i += 1) {
          const q = await inject('GET', '/api/v1/player/sessions?id=' + id2, admin);
          job2 = q.json();
          if (job2.status === 'done' || job2.status === 'failed') break;
          await new Promise((res) => setTimeout(res, 300));
        }
        check(
          'session_codec',
          Boolean(job2) && job2.status === 'done' && ['h265', 'h264'].includes(job2.codec),
          `codec=${job2 && job2.codec} container=${job2 && job2.container} err=${job2 && job2.error}`,
        );
        if (job2 && job2.container === 'fmp4') {
          const pl = await inject('GET', `/api/v1/player/hls/${id2}/index.m3u8`);
          check(
            'fmp4_ext_x_map',
            pl.statusCode === 200 && pl.body.includes('#EXT-X-MAP'),
            'map=' + pl.body.includes('#EXT-X-MAP'),
          );
          const init = await inject('GET', `/api/v1/player/hls/${id2}/init.mp4`);
          check('fmp4_init_mp4', init.statusCode === 200, 'status=' + init.statusCode);
        } else {
          // 降级路径也是正确行为：编码器不可用时回 H.264 / MPEG-TS
          check('fmp4_init_mp4', true, 'degraded to mpegts/h264');
        }

        // 无令牌一律 401（不再依赖裸会话 UUID）
        const noToken = await inject('GET', `/api/v1/player/hls/${id}/index.m3u8`);
        check('hls_m3u8_requires_token', noToken.statusCode === 401, 'status=' + noToken.statusCode);

        // 带令牌：m3u8 可读，且播放列表里的分片被改写成同一令牌
        const m3u8 = await inject('GET', job.url);
        check(
          'hls_m3u8_with_token',
          m3u8.statusCode === 200 && m3u8.body.includes('#EXTM3U') && /\?t=/.test(m3u8.body),
          'status=' + m3u8.statusCode,
        );

        const token = new URL('http://local' + job.url).searchParams.get('t');
        const segLine = m3u8.body.split('\n').find((l) => l && !l.startsWith('#'));
        const seg = await inject('GET', `/api/v1/player/hls/${id}/${segLine || 'seg00000.ts'}`);
        check(
          'hls_segment_with_token',
          seg.statusCode === 200 && seg.rawPayload.length > 0,
          'status=' + seg.statusCode,
        );

        // 带令牌但路径穿越 → 仍由文件名校验挡成 404
        const bad = await inject(
          'GET',
          `/api/v1/player/hls/${id}/..%2F..%2Fsecret?t=${encodeURIComponent(token)}`,
        );
        check('hls_path_guard_404', bad.statusCode === 404, 'status=' + bad.statusCode);
      } else {
        check('session_segments', true, 'skipped');
        check('session_url', true, 'skipped');
        check('hls_m3u8_requires_token', true, 'skipped');
        check('hls_m3u8_with_token', true, 'skipped');
        check('hls_segment_with_token', true, 'skipped');
        check('hls_path_guard_404', true, 'skipped');
      }
    }
  }

  // 未知会话 / 未就绪会话
  r = await inject('GET', '/api/v1/player/hls/00000000-0000-0000-0000-000000000000/index.m3u8');
  check('hls_unknown_session_401', r.statusCode === 401, 'status=' + r.statusCode);

  r = await inject('GET', '/api/v1/player/sessions?id=nope', admin);
  check('session_get_unknown_404', r.statusCode === 404, 'status=' + r.statusCode);

  await app.close();
  try { fs.rmSync(dataDir, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 }); } catch { /* ffmpeg 句柄释放有延迟，临时目录留给系统清理 */ }

  let failed = 0;
  for (const x of results) {
    console.log(`${x.ok ? '[OK]  ' : '[FAIL]'} ${x.name.padEnd(26)} ${x.detail}`);
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
