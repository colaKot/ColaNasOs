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

  // ---- 片源能力解析 + 三家硬件转码链路：决策纯函数（模拟 ctx，跨平台可测） ----
  const gpu = require(path.join(root, 'sidecars', 'media', 'gpu-pipeline.js'));
  const CAPS = 'cuda dxva2 qsv d3d11va opencl vulkan d3d12va amf';
  const FILTERS =
    'scale_d3d11 tonemap_d3d11 scale_cuda tonemap_cuda scale_qsv vpp_qsv ' +
    'libplacebo zscale tonemap hwdownload hwupload';
  const gpuCtx = (over = {}) => ({
    platform: 'win32',
    hwaccels: CAPS,
    filters: FILTERS,
    encoder: 'h264_amf',
    prefer: 'auto',
    copyVideo: false,
    subtitle: undefined,
    subtitleFilter: undefined,
    hdrToSdr: true,
    height: 1080,
    source: gpu.EMPTY_SOURCE,
    tailParts: ['scale=-2:1080', 'format=yuv420p'],
    ...over,
  });
  const gp = gpu.decodePlans(gpuCtx());
  check('gpu_plan_preferred', gp[0].pipeline === 'gpu-zero-copy', gp[0].pipeline);
  check(
    'gpu_plan_hwaccel',
    gp[0].inputArgs.includes('d3d11va') && gp[0].inputArgs.includes('-hwaccel_output_format'),
    gp[0].inputArgs.join(' '),
  );
  check('gpu_plan_tonemap', gp[0].filter(true).includes('tonemap_d3d11'), gp[0].filter(true));
  check(
    'gpu_plan_scale_nv12',
    gp[0].filter(false).includes('scale_d3d11=w=-2:h=1080:format=nv12'),
    gp[0].filter(false),
  );
  check('gpu_plan_tonemap_off', !gp[0].filter(false).includes('tonemap_d3d11'), gp[0].filter(false));
  // 实测：手动指定 PQ/BT2020 输入色彩会破坏 apply_dovi，画面压到全黑，绝不能加。
  check(
    'gpu_plan_no_manual_pq',
    !/smpte2084|matrix=bt2020|primaries=bt2020/.test(gp[0].filter(true)),
    gp[0].filter(true),
  );
  check(
    'gpu_plan_original',
    gpu.decodePlans(gpuCtx({ height: 0 }))[0].filter(false).includes('h=ih'),
    'height=0',
  );
  check('gpu_off_copy', gpu.decodePlans(gpuCtx({ copyVideo: true }))[0].pipeline === 'cpu', 'copy');
  check('gpu_off_cpu_only', gpu.decodePlans(gpuCtx({ prefer: 'cpu' }))[0].pipeline === 'cpu', 'cpu');
  check('gpu_off_platform', gpu.decodePlans(gpuCtx({ platform: 'linux' }))[0].pipeline === 'cpu', 'linux');
  check(
    'gpu_off_no_d3d11va',
    gpu.decodePlans(gpuCtx({ hwaccels: 'cuda\nqsv\n' }))[0].pipeline === 'cpu',
    'caps',
  );
  check(
    'gpu_hwdecode_cpu_enc',
    gpu.decodePlans(gpuCtx({ encoder: 'libx264' }))[0].pipeline === 'hw-decode',
    'libx264',
  );
  check('gpu_cpu_fallback', gp[gp.length - 1].pipeline === 'cpu', 'fallback always present');

  // 字幕烧录不再整条退回 CPU：硬件 tonemap/scale 后只 hwdownload 一次给 libass。
  const burn = gpu.decodePlans(gpuCtx({ subtitle: 'a.srt', subtitleFilter: "subtitles='a.srt'" }))[0];
  check('gpu_hybrid_subtitle', burn.pipeline === 'gpu-hybrid', burn.pipeline);
  check(
    'gpu_hybrid_download_once',
    burn.filter(true).includes('hwdownload') && burn.filter(true).includes("subtitles='a.srt'") &&
      burn.filter(true).includes('tonemap_d3d11'),
    burn.filter(true),
  );

  // 三家厂商：编码器后缀决定硬解方式与显存内滤镜名。
  check(
    'gpu_vendor_detect',
    gpu.vendorOf('h264_amf') === 'amd' && gpu.vendorOf('h264_nvenc') === 'nvidia' &&
      gpu.vendorOf('h264_qsv') === 'intel' && gpu.vendorOf('libx264') === 'cpu',
    'amf/nvenc/qsv/cpu',
  );
  const nv = gpu.decodePlans(gpuCtx({ encoder: 'h264_nvenc' }))[0];
  check('gpu_vendor_nvidia', nv.decoder === 'cuda' && nv.pipeline === 'gpu-zero-copy', nv.decoder + '/' + nv.pipeline);
  check(
    'gpu_nvidia_filters',
    nv.filter(true).includes('tonemap_cuda') && nv.filter(true).includes('scale_cuda'),
    nv.filter(true),
  );
  const qsv = gpu.decodePlans(gpuCtx({ encoder: 'h264_qsv' }))[0];
  check('gpu_vendor_intel', qsv.decoder === 'qsv' && qsv.pipeline === 'gpu-zero-copy', qsv.decoder + '/' + qsv.pipeline);
  check(
    'gpu_intel_filters',
    qsv.filter(true).includes('vpp_qsv=tonemap=1') && qsv.filter(false).includes('scale_qsv'),
    qsv.filter(true),
  );

  // 片源解析：DV P5 / Hi10P / HDR10 的三种典型 `ffmpeg -i` 输出。
  const DV5 = [
    "Input #0, matroska,webm,from 'x.mkv':",
    '  Stream #0:0: Video: hevc (Main 10), yuv420p10le(pc, progressive), 3840x2080, 24 fps',
    '      DOVI configuration record: version: 1.0, profile: 5, level: 6, rpu flag: 1',
  ].join('\n');
  const HI10P =
    '  Stream #0:0: Video: h264 (High 10), yuv420p10le(tv, progressive), 1920x1080, 24 fps';
  const HDR10 =
    '  Stream #0:0: Video: hevc (Main 10), yuv420p10le(tv, bt2020nc/bt2020/smpte2084, progressive), 3840x2160';
  const dvSrc = gpu.parseSource(DV5);
  const hiSrc = gpu.parseSource(HI10P);
  const hdrSrc = gpu.parseSource(HDR10);
  check(
    'source_parse_dv5',
    dvSrc.dvProfile === 5 && dvSrc.hdrKind === 'dv' && !dvSrc.hasHdrMeta && dvSrc.tenBit,
    JSON.stringify(dvSrc),
  );
  check('source_parse_hi10p', hiSrc.hi10p === true && hiSrc.codec === 'h264', JSON.stringify(hiSrc));
  check(
    'source_parse_hdr10',
    hdrSrc.hdrKind === 'hdr10' && hdrSrc.hasHdrMeta && !hdrSrc.hi10p,
    JSON.stringify(hdrSrc),
  );
  check(
    'gpu_off_hi10p',
    gpu.decodePlans(gpuCtx({ source: hiSrc }))[0].pipeline === 'cpu',
    'Hi10P has no hardware decoder',
  );
  check(
    'gpu_dv5_still_zero_copy',
    gpu.decodePlans(gpuCtx({ source: dvSrc }))[0].pipeline === 'gpu-zero-copy',
    'apply_dovi handles DV P5',
  );
  // Intel 是例外：`vpp_qsv=tonemap=1` 只认 HDR10 元数据，**不吃 DV RPU**，
  // 让它上零拷贝就是一片偏绿偏紫。DV 只能退回软件帧链（libplacebo），
  // 宁可慢也不能给错色 —— 硬编解码器下没有「硬解 + 软件滤镜」这一档，
  // 所以整条落到 CPU 保底项。真机上的 Intel 混合链还没验证过，不写死在里面。
  const intelDv = gpu.decodePlans(gpuCtx({ encoder: 'h264_qsv', source: dvSrc }))[0];
  check('gpu_intel_dv_no_zero_copy', intelDv.pipeline !== 'gpu-zero-copy', intelDv.pipeline);
  check(
    'gpu_intel_dv_placebo',
    gpu.cpuFilter(gpuCtx({ encoder: 'h264_qsv', source: dvSrc }), true).includes('libplacebo'),
    'intel DV -> libplacebo',
  );

  // CPU / 普通硬解回退链：DV 片源不能用会 -22 失败的 zscale，必须换 libplacebo。
  const dvCtx = gpuCtx({ source: dvSrc });
  const dvCpu = gpu.cpuFilter(dvCtx, true);
  check('cpu_tonemap_dv_placebo', dvCpu.includes('libplacebo') && !dvCpu.includes('zscale=t=linear'), dvCpu.slice(0, 120));
  check('cpu_tonemap_usable_dv', gpu.cpuTonemapUsable(dvCtx) === false, 'dv');
  const hdrCpu = gpu.cpuFilter(gpuCtx({ source: hdrSrc }), true);
  check('cpu_tonemap_hdr10_zscale', hdrCpu.includes('zscale=t=linear:npl=100'), hdrCpu.slice(0, 120));
  check('cpu_tonemap_usable_hdr10', gpu.cpuTonemapUsable(gpuCtx({ source: hdrSrc })) === true, 'hdr10');
  check(
    'cpu_filter_sdr',
    gpu.cpuFilter(gpuCtx({ hdrToSdr: false }), true) === 'scale=-2:1080,format=yuv420p',
    'sdr passthrough',
  );
  check(
    'placebo_no_manual_scale',
    gpu.placeboFilter(dvCtx, true).includes('libplacebo=w=-2:h=1080'),
    'vulkan scale',
  );

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
  // 下面这一整组是「整片一次转完」的旧路径：默认已经改成 3 分钟分段，
  // 所以必须显式传 0，否则 .session.json 会落到 p0/ 子目录，断言全部跑偏。
  r = await inject('POST', '/api/v1/player/sessions', admin, {
    id: itemId,
    subtitle: 'demo.srt',
    leadMinutes: 0,
  });
  if (r.statusCode === 503) {
    check('session_create', true, 'skipped: media unavailable');
    check('session_default_lead_3min', true, 'skipped: media unavailable');
    check('session_default_lead_part_dir', true, 'skipped: media unavailable');
    check('session_default_lead_playlist_part', true, 'skipped: media unavailable');
  } else {
    check(
      'session_create',
      r.statusCode === 200 && r.json().id,
      'status=' + r.statusCode + ' ' + r.body.slice(0, 160),
    );
    if (r.statusCode === 200) {
      const id = r.json().id;
      // 边转边播：会话还没 done 时播放列表就必须可读（EVENT 或空 EVENT 占位）。
      // 以前这里返回 404「session not ready」，客户端只能等全片转完才起播。
      const early = await inject('GET', r.json().url);
      check(
        'session_playlist_while_running',
        early.statusCode === 200 && early.body.includes('#EXTM3U'),
        'status=' + early.statusCode + ' ' + String(early.body).slice(0, 80),
      );
      let job;
      // sidecar 在首片落盘 / 正常退出时会写 <hls>/<id>/.session.json（这一轮真正
      // 用上的编码 + 编码器）。用户选了 AV1 但编码器起不来时会被静默降级成
      // H.264，会话接口必须把这个文件读出来回显，否则界面一直显示 AV1。
      const metaFile = path.join(dataDir, 'hls', id, '.session.json');
      const echoes = [];
      const t0 = Date.now();
      for (;;) {
        const s = await inject(
          'GET',
          `/api/v1/player/sessions?id=${encodeURIComponent(id)}`,
          admin,
        );
        job = s.json();
        try {
          const meta = JSON.parse(fs.readFileSync(metaFile, 'utf8'));
          echoes.push({ file: String(meta.codec || ''), api: String(job.codec || '') });
        } catch {
          /* 还没写（或正在写）*/
        }
        if (job.status === 'done' || job.status === 'failed') break;
        if (Date.now() - t0 > 120_000) break;
        await new Promise((res) => setTimeout(res, 300));
      }
      check(
        'session_done',
        job && job.status === 'done',
        `status=${job && job.status} err=${job && job.error}`,
      );
      // 显式传 0 仍然整片转（老行为不能被默认值改动弄丢）
      check(
        'session_explicit_full_lead_0',
        job && job.leadMs === 0,
        `leadMs=${job && job.leadMs}`,
      );
      check(
        'session_actual_codec',
        echoes.length > 0 && echoes.every((x) => x.file === x.api),
        echoes.length
          ? `sidecar=${echoes[0].file} api=${echoes[0].api} n=${echoes.length}`
          : 'no .session.json',
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
          const rNorm = await inject('POST', '/api/v1/player/sessions', admin, {
            id: itemId,
            leadMinutes: 0,
          });
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
          preset: '1080p_3m',
          codec: 'h265',
          leadMinutes: 0,
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
          // 播放地址必须带会话令牌：下面「无令牌一律 401」那条正是这个约定，
          // 这里以前直接请求裸路径 → 恒 401，而 codec 没接通时永远走 mpegts 分支所以没人发现。
          const pl = await inject('GET', job2.url);
          check(
            'fmp4_ext_x_map',
            pl.statusCode === 200 && pl.body.includes('#EXT-X-MAP'),
            `status=${pl.statusCode} map=${pl.body.includes('#EXT-X-MAP')}`,
          );
          const init = await inject('GET', job2.url.replace('/index.m3u8', '/init.mp4'));
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

    // ---- 默认提前转码时长：不传 leadMinutes 时所有端统一 3 分钟 ----
    // 上面整组用例都显式传 0 走整片旧路径；这里专测「不传」的默认语义：
    // SDK / 直接 API / 漏传参数的客户端都不能偷偷退回整片。
    // 放在最后是因为建会话会取消同片 pending/running 的旧会话，前面几组都已等到 done。
    r = await inject('POST', '/api/v1/player/sessions', admin, { id: itemId });
    if (r.statusCode === 200) {
      const idDef = r.json().id;
      let jobDef = null;
      for (let i = 0; i < 120; i += 1) {
        const q = await inject(
          'GET',
          `/api/v1/player/sessions?id=${encodeURIComponent(idDef)}`,
          admin,
        );
        jobDef = q.json();
        // 2 s 测试片一段就到片尾：正常是 done，片长元数据缺失时也可能是 paused
        if (['done', 'paused', 'failed'].includes(jobDef.status)) break;
        await new Promise((res) => setTimeout(res, 300));
      }
      check(
        'session_default_lead_3min',
        Boolean(jobDef) && jobDef.leadMs === 180000,
        `leadMs=${jobDef && jobDef.leadMs} status=${jobDef && jobDef.status}`,
      );
      // 分段产物落在 p0/ 而不是会话根目录，这是「默认不是整片」最直接的证据
      const partIndex = path.join(dataDir, 'hls', idDef, 'p0', 'index.m3u8');
      check(
        'session_default_lead_part_dir',
        fs.existsSync(partIndex) &&
          Boolean(jobDef) && ['done', 'paused'].includes(jobDef.status),
        `p0=${fs.existsSync(partIndex)} status=${jobDef && jobDef.status}`,
      );
      const plDef = await inject('GET', r.json().url);
      check(
        'session_default_lead_playlist_part',
        plDef.statusCode === 200 && String(plDef.body).includes('part=p0'),
        `status=${plDef.statusCode} part=${String(plDef.body).includes('part=p0')}`,
      );
    } else {
      check('session_default_lead_3min', true, 'skipped: create failed');
      check('session_default_lead_part_dir', true, 'skipped: create failed');
      check('session_default_lead_playlist_part', true, 'skipped: create failed');
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
