#!/usr/bin/env node
/**
 * media sidecar（SP2-03）：缩略图 / 转码。
 *
 * 协议：
 *   invoke('thumb', { src, dst, size?, quality? }) -> { dst, ms }
 *   invoke('transcode', { src, dst, preset? })     -> { dst, ms, reused }
 *   invoke('bench', { src, dir, count?, size?, concurrency? }) -> { count, ms, throughput }
 *   invoke('stats')                                -> 计数器
 *
 * 「转码会话复用」：同一 (src,dst,preset) 的并发/重复请求共享同一个进行中任务，
 * 只会真正启动一次 ffmpeg，后到的请求拿 reused=true。
 */
'use strict';

const fs = require('node:fs');
const nodePath = require('node:path');
const { spawn } = require('node:child_process');
const { cpus } = require('node:os');

/** 画质档位表（由 tool/gen-play-quality.js 从 contracts/play-quality.json 生成） */
const PLAY_QUALITY = require('./play-quality.generated.json');

process.stdin.setEncoding('utf8');
process.stdout.on('error', () => {
  /* 父进程已退出 */
});

let buf = '';
const send = (obj) => {
  if (process.stdout.writable) process.stdout.write(JSON.stringify(obj) + '\n');
};

function findFfmpeg() {
  const cands = [];
  if (process.env.COLANAS_FFMPEG) cands.push(process.env.COLANAS_FFMPEG);
  cands.push(process.platform === 'win32' ? 'ffmpeg.exe' : 'ffmpeg');
  return cands[0];
}

const FFMPEG = findFfmpeg();

const stats = { thumbs: 0, transcodes: 0, reused: 0, fails: 0 };
const inflight = new Map();
const CONCURRENCY = Math.max(1, Math.min(Number(process.env.COLANAS_MEDIA_CONCURRENCY) || 4, 16));

/** 正在跑的 HLS ffmpeg：dir → child。取消会话时按 dir 精确 kill，不误伤其它任务。 */
const activeHls = new Map();
/** 被主动取消的 dir（用于把「kill 导致的非零退出」标成 E_CANCELED，避免上层误判并重试） */
const canceledHls = new Set();

function runFfmpeg(args, timeoutMs = 120_000, opts = {}) {
  return new Promise((resolve, reject) => {
    // `cwd` 只给 HLS 用：ffmpeg 的 `-hls_fmp4_init_filename` 是相对**进程工作目录**解析的，
    // 不设就会把 init.mp4 丢到 sidecar 的启动目录（实测落在仓库根），播放器再请求 init.mp4 就 404。
    const child = spawn(FFMPEG, args, {
      windowsHide: true,
      stdio: ['ignore', 'ignore', 'pipe'],
      cwd: opts.cwd || undefined,
    });
    const hlsKey = opts.hlsKey || null;
    if (hlsKey) activeHls.set(hlsKey, child);
    let err = '';
    let settled = false;
    const finish = (fn, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      clearInterval(watchTimer);
      fn(value);
    };
    const timer = setTimeout(() => {
      try {
        child.kill('SIGKILL');
      } catch {
        /* 忽略 */
      }
      finish(reject, Object.assign(new Error('ffmpeg timeout'), { code: 'E_TIMEOUT' }));
    }, timeoutMs);

    // 进度看门狗：HLS 只要迟迟不出首片、或出片后长时间不再增长，就认为这家编码器
    // 卡死了（实测 h264_amf 在 4K 源上出了第一片后挂住，30 分钟超时才报错，
    // 用户对着黑屏等半小时）。杀掉换下一条路径，比等 30 分钟好。
    let watchTimer = null;
    const watch = opts.watch;
    if (watch && watch.dir) {
      const firstMs = Number(watch.firstMs) || 90000;
      const idleMs = Number(watch.idleMs) || 120000;
      const startedAt = Date.now();
      let lastCount = 0;
      let lastAt = startedAt;
      watchTimer = setInterval(() => {
        let count = 0;
        try {
          for (const f of fs.readdirSync(watch.dir)) {
            if (f.endsWith('.ts') || f.endsWith('.m4s')) count += 1;
          }
        } catch {
          count = -1; // 目录暂时读不到：先不判定
        }
        if (count < 0) return;
        if (count > lastCount) {
          lastCount = count;
          lastAt = Date.now();
          return;
        }
        const nowMs = Date.now();
        const stuck = lastCount === 0 ? nowMs - startedAt >= firstMs : nowMs - lastAt >= idleMs;
        if (!stuck) return;
        try {
          child.kill('SIGKILL');
        } catch {
          /* 已退出 */
        }
        finish(
          reject,
          Object.assign(
            new Error(lastCount === 0 ? 'ffmpeg 首片超时' : 'ffmpeg 转码停滞'),
            { code: 'E_STALL' },
          ),
        );
      }, 2000);
      if (watchTimer.unref) watchTimer.unref();
    }

    child.stderr.on('data', (c) => {
      err += String(c);
      if (err.length > 8192) err = err.slice(-4096);
    });
    child.on('error', (e) => {
      if (hlsKey && activeHls.get(hlsKey) === child) activeHls.delete(hlsKey);
      finish(
        reject,
        Object.assign(new Error(`ffmpeg spawn failed: ${e.message}`), { code: 'E_NO_FFMPEG' }),
      );
    });
    child.on('exit', (code) => {
      if (hlsKey && activeHls.get(hlsKey) === child) activeHls.delete(hlsKey);
      if (canceledHls.delete(hlsKey)) {
        finish(reject, Object.assign(new Error('ffmpeg canceled'), { code: 'E_CANCELED' }));
        return;
      }
      if (code === 0) {
        finish(resolve);
        return;
      }
      finish(
        reject,
        Object.assign(new Error(`ffmpeg exited ${code}: ${err.slice(-400)}`), { code: 'E_FFMPEG' }),
      );
    });
  });
}

/** 简易信号量：限制同时运行的 ffmpeg 数量 */
function createLimiter(n) {
  let active = 0;
  const queue = [];
  const next = () => {
    if (active >= n || queue.length === 0) return;
    active += 1;
    const { fn, resolve, reject } = queue.shift();
    fn()
      .then(resolve, reject)
      .finally(() => {
        active -= 1;
        next();
      });
  };
  return (fn) =>
    new Promise((resolve, reject) => {
      queue.push({ fn, resolve, reject });
      next();
    });
}

const limit = createLimiter(CONCURRENCY);

/**
 * 抓取 ffmpeg 输出（不因退出码非 0 抛错）。
 * 探测流信息只能靠 `ffmpeg -i`（本机只带 ffmpeg，没有 ffprobe），它必然以 1 退出。
 */
function runCapture(args, timeoutMs = 60_000) {
  return new Promise((resolve) => {
    let out = '';
    let err = '';
    let child;
    try {
      child = spawn(FFMPEG, args, { windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
    } catch (e) {
      resolve({ code: -1, stdout: '', stderr: String(e) });
      return;
    }
    const timer = setTimeout(() => {
      try {
        child.kill('SIGKILL');
      } catch {
        /* 已退出 */
      }
      resolve({ code: -1, stdout: out, stderr: err });
    }, timeoutMs);
    child.stdout.on('data', (c) => {
      out += String(c);
    });
    child.stderr.on('data', (c) => {
      err += String(c);
    });
    child.on('error', (e) => {
      clearTimeout(timer);
      resolve({ code: -1, stdout: out, stderr: err + String(e) });
    });
    child.on('exit', (code) => {
      clearTimeout(timer);
      resolve({ code, stdout: out, stderr: err });
    });
  });
}

/** 容器内的文本字幕编码器（图形字幕 PGS / DVD 无法转 WebVTT，不纳入列表） */
const TEXT_SUBTITLE_CODECS = new Set([
  'subrip',
  'srt',
  'ass',
  'ssa',
  'mov_text',
  'webvtt',
  'text',
  'microdvd',
  'subviewer',
  'subviewer1',
  'sami',
  'realtext',
  'jacosub',
  'vplayer',
]);

/**
 * 列出内嵌字幕轨（按 ffmpeg 的 `-i` 流信息解析）。
 * `index` 是该文件里第几条字幕流，直接可用于 `-map 0:s:<index>`。
 */
async function subtitleTracks(params) {
  const { src } = params || {};
  if (!src) throw Object.assign(new Error('src required'), { code: 'E_PARAM' });
  if (!fs.existsSync(src)) throw Object.assign(new Error('src not found: ' + src), { code: 'E_NO_SRC' });

  const r = await runCapture(['-hide_banner', '-loglevel', 'info', '-i', src]);
  const tracks = [];
  for (const line of String(r.stderr || '').split(/\r?\n/)) {
    // 例：Stream #0:2(eng): Subtitle: subrip (srt)
    const m = /Stream #\d+:(\d+)(?:\[[^\]]*\])?(?:\(([^)]+)\))?: Subtitle: ([^\s(]+)/.exec(line);
    if (!m) continue;
    const codec = String(m[3] || '').toLowerCase();
    tracks.push({
      index: tracks.length,
      lang: m[2] ? String(m[2]) : null,
      codec,
      text: TEXT_SUBTITLE_CODECS.has(codec),
    });
  }
  return { tracks };
}

/** 抽取一条字幕轨到文本文件（默认 srt；srt / webvtt 都支持，图形字幕会失败） */
async function extractSubtitle(params) {
  const { src, dst } = params || {};
  const index = Number(params && params.index);
  if (!src || !dst || !Number.isInteger(index) || index < 0) {
    throw Object.assign(new Error('src/dst/index required'), { code: 'E_PARAM' });
  }
  if (!fs.existsSync(src)) throw Object.assign(new Error('src not found: ' + src), { code: 'E_NO_SRC' });
  const format = String(params.format || 'srt').toLowerCase() === 'webvtt' ? 'webvtt' : 'srt';
  fs.mkdirSync(nodePath.dirname(dst), { recursive: true });
  await limit(() =>
    runFfmpeg(
      [
        '-hide_banner', '-loglevel', 'error', '-y',
        '-i', src,
        '-map', `0:s:${index}`,
        '-c:s', format,
        dst,
      ],
      120_000,
    ),
  );
  if (!fs.existsSync(dst)) throw Object.assign(new Error('subtitle output missing'), { code: 'E_FFMPEG' });
  return { dst, ms: 0 };
}

async function thumb(params) {
  const { src, dst } = params || {};
  if (!src || !dst) throw Object.assign(new Error('src/dst required'), { code: 'E_PARAM' });
  const size = Math.max(16, Math.min(Number(params.size) || 256, 4096));
  const quality = Math.max(1, Math.min(Number(params.quality) || 4, 31));

  const started = process.hrtime.bigint();
  await limit(() =>
    runFfmpeg([
      '-hide_banner',
      '-loglevel',
      'error',
      '-y',
      '-i',
      src,
      '-vf',
      `scale=${size}:-2:flags=lanczos`,
      '-frames:v',
      '1',
      '-q:v',
      String(quality),
      dst,
    ]),
  );
  stats.thumbs += 1;
  return { dst, ms: Number(process.hrtime.bigint() - started) / 1e6 };
}

function transcodeArgs(params) {
  const o = params.options || null;
  const args = ['-hide_banner', '-loglevel', 'error', '-y', '-i', params.src];

  // 兼容旧 preset（没有 options 时保持原行为）
  if (!o) {
    if (params.preset === 'web720') {
      args.push('-vf', 'scale=-2:720', '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '23');
    } else if (params.preset === 'audio') {
      args.push('-vn', '-c:a', 'aac', '-b:a', '192k');
    } else {
      args.push('-c', 'copy');
    }
    args.push(params.dst);
    return args;
  }

  const mode = o.mode === 'audio' ? 'audio' : o.mode === 'image' ? 'image' : 'video';

  if (mode === 'image') {
    const size = Number(o.size) || 0;
    if (size > 0) {
      args.push('-vf', `scale='min(${size},iw)':-2:flags=lanczos`);
    }
    const quality = Math.max(1, Math.min(100, Number(o.quality) || 80));
    const q = Math.max(2, Math.min(31, Math.round(31 - (quality / 100) * 29)));
    args.push('-frames:v', '1', '-q:v', String(q), '-map_metadata', '0', '-an');
    args.push(params.dst);
    return args;
  }

  if (mode === 'audio') {
    const codecMap = {
      mp3: 'libmp3lame',
      m4a: 'aac',
      aac: 'aac',
      flac: 'flac',
      ogg: 'libvorbis',
      wav: 'pcm_s16le',
      opus: 'libopus',
      wma: 'wmav2',
    };
    const codec = codecMap[String(o.format || 'mp3').toLowerCase()] || 'aac';
    args.push('-vn', '-c:a', codec);
    const sampleRate = Number(o.sampleRate) || 0;
    if (sampleRate > 0) args.push('-ar', String(sampleRate));
    if (o.channels === 'mono') args.push('-ac', '1');
    else if (o.channels === 'stereo') args.push('-ac', '2');
    const bitrate = Number(o.bitrateKbps) || 0;
    if (bitrate > 0) args.push('-b:a', `${bitrate}k`);
    const threads = Number(o.threads) || 0;
    if (threads > 0) args.push('-threads', String(threads));
    args.push(params.dst);
    return args;
  }

  // video
  const vcodecRaw = String(o.vcodec || 'h264');
  const vcodec =
    vcodecRaw === 'copy' ? 'copy' : vcodecRaw === 'h265' ? 'libx265' : 'libx264';
  const acodecRaw = String(o.acodec || 'aac');
  const acodec = acodecRaw === 'copy' ? 'copy' : acodecRaw === 'mp3' ? 'libmp3lame' : 'aac';

  const resolution = String(o.resolution || 'source');
  if (resolution !== 'source' && vcodec !== 'copy') {
    if (resolution === '8k') args.push('-vf', 'scale=7680:-2');
    else if (resolution === '4k') args.push('-vf', 'scale=3840:-2');
    else {
      const height = {
        '1080p': 1080,
        '720p': 720,
        '480p': 480,
        '320p': 320,
        '240p': 240,
      }[resolution];
      if (height) args.push('-vf', `scale=-2:${height}`);
    }
  }

  if (vcodec !== 'copy') {
    args.push('-c:v', vcodec);
    const vbitrate = Number(o.vbitrateKbps) || 0;
    if (vbitrate > 0) args.push('-b:v', `${vbitrate}k`);
  } else {
    args.push('-c:v', 'copy');
  }
  if (acodec !== 'copy') {
    args.push('-c:a', acodec);
    const abrate = Number(o.abrateKbps) || 0;
    if (abrate > 0) args.push('-b:a', `${abrate}k`);
  } else {
    args.push('-c:a', 'copy');
  }
  const fps = Number(o.fps) || 0;
  if (fps > 0) args.push('-r', String(fps));
  const threads = Number(o.threads) || 0;
  if (threads > 0) args.push('-threads', String(threads));
  const format = String(o.format || '').toLowerCase();
  if (format === 'gif') args.push('-loop', '0', '-an');
  if (format === 'webp') args.push('-an');
  args.push(params.dst);
  return args;
}

function transcodeOnce(params) {
  const key = `${params.src}|${params.dst}|${params.preset || 'default'}|${JSON.stringify(params.options || null)}`;
  const existing = inflight.get(key);
  if (existing) {
    stats.reused += 1;
    return existing.then((r) => ({ ...r, reused: true }));
  }

  const job = (async () => {
    const started = process.hrtime.bigint();
    const args = transcodeArgs(params);
    await limit(() => runFfmpeg(args));
    stats.transcodes += 1;
    return { dst: params.dst, ms: Number(process.hrtime.bigint() - started) / 1e6, reused: false };
  })();

  inflight.set(key, job);
  return job.finally(() => {
    inflight.delete(key);
  });
}

async function transcode(params) {
  if (!params || !params.src || !params.dst) {
    throw Object.assign(new Error('src/dst required'), { code: 'E_PARAM' });
  }
  if (!fs.existsSync(params.src)) {
    throw Object.assign(new Error('src not found: ' + params.src), { code: 'E_NO_SRC' });
  }
  return transcodeOnce(params);
}

/** ffmpeg filter 参数里的路径转义（Windows 盘符与反斜杠） */
function escapeFilterPath(p) {
  return p.replace(/\\/g, '/').replace(/:/g, '\\:').replace(/'/g, "\\'");
}

/** HLS 转码：`dir` 下产出 index.m3u8 + seg%05d.ts（6 s 一片，VOD 播放列表） */
/**
 * HLS 转码：h264 → MPEG-TS；h265 / av1 → fMP4（**必须带 EXT-X-MAP**）。
 *
 * 背景：AV1 in MPEG-TS 实测无法解析；H.265 没有初始化段时播放器起播会失败。
 * 失败自动降级回 h264（兼容性优先），并在返回值里带回实际使用的编码与容器，
 * 便于上层显示与排障（不静默假装成功）。
 */
/**
 * 硬件编码器探测（进程内缓存一次）。
 *
 * 为什么需要：转码此前写死 `libx264 / libx265 / libsvtav1` —— 纯 CPU。4K 源会把
 * 8 核打满、风扇起飞，而这正是 NAS 最典型的负载。项目本来就选了带 QSV / VAAPI /
 * NVENC 的 jellyfin-ffmpeg，却一直没用上。
 *
 * 只探 Windows/Linux 上常见的三家（nvenc / qsv / amf）。**vaapi 不自动启用**：
 * 它要先 `-vaapi_device /dev/dri/renderDxxx` 再用 `hwupload` 滤镜，设备节点因机器而异，
 * 猜错就是整个转码失败 —— 宁可不用，也不要在用户机器上"偶发失败"。
 *
 * 探测不到就返回 null，调用方走 CPU 原路径：**没有任何机器会因此变慢或变坏**。
 */
/**
 * 全部可用的硬件编码器（按「画质/兼容性」排序），供「首选解码器」按厂商挑。
 *
 * **必须异步探测**：sidecar 是单线程的，之前用 spawnSync 逐个试编码器会把事件循环
 * 卡住十几秒，supervisor 的 10s 心跳直接超时并把进程 SIGKILL（smoke:player 实测）。
 * `-encoders` 列表只说明「build 里编进来了」，不代表本机真有硬件，所以逐个真编一帧。
 */
let hwAllCache = null;
let hwAllPromise = null;

function encoderListing() {
  try {
    const r = require('node:child_process').spawnSync(findFfmpeg(), ['-hide_banner', '-encoders'], {
      encoding: 'utf8',
      timeout: 15000,
    });
    return String(r.stdout || '');
  } catch {
    return '';
  }
}

/** 实测某个硬件编码器能否用（1 帧 lavfi → null）。失败就当没有，绝不靠名字猜。 */
async function probeEncoder(name) {
  try {
    await runFfmpeg(
      [
        '-hide_banner', '-loglevel', 'error', '-y',
        '-f', 'lavfi', '-i', 'testsrc=size=320x240:rate=1',
        '-frames:v', '1', '-c:v', name, '-f', 'null', '-',
      ],
      15000,
    );
    return true;
  } catch {
    return false;
  }
}

async function detectHwAll() {
  if (hwAllCache) return hwAllCache;
  if (hwAllPromise) return hwAllPromise;
  hwAllPromise = (async () => {
    const out = { h264: [], h265: [], av1: [] };
    const listing = encoderListing();
    const map = { h264: 'h264_', h265: 'hevc_', av1: 'av1_' };
    const candidates = [];
    for (const kind of ['h264', 'h265', 'av1']) {
      for (const vendor of ['nvenc', 'qsv', 'amf']) {
        const name = map[kind] + vendor;
        if (listing.includes(name)) candidates.push([kind, name]);
      }
    }
    // 串行验证（并行 9 个 ffmpeg 会把弱机瞬间打满）；结果缓存，只付一次成本
    for (const [kind, name] of candidates) {
      if (await probeEncoder(name)) out[kind].push(name);
    }
    hwAllCache = out;
    return out;
  })();
  return hwAllPromise;
}

/** 按 codec 给出编码器参数（不含 `-c:v`）。`allowHw=false` 时强制 CPU；`prefer` 限定厂商。 */
function videoCodecArgs(codec, allowHw, prefer = 'auto', hw = null) {
  const kind = codec === 'h265' ? 'h265' : codec === 'av1' ? 'av1' : 'h264';
  let enc = null;
  if (allowHw) {
    const list = (hw || { h264: [], h265: [], av1: [] })[kind];
    if (prefer === 'cpu') enc = null;
    else if (prefer === 'auto' || !prefer) enc = list[0] || null;
    else enc = list.find((n) => n.endsWith('_' + prefer)) || null;
  }
  if (enc) {
    if (enc.endsWith('_nvenc')) {
      // p4 = 均衡档；-cq 是恒定质量（数值语义接近 crf）
      return { args: [enc, '-preset', 'p4', '-cq', kind === 'h264' ? '23' : '28'], encoder: enc };
    }
    if (enc.endsWith('_qsv')) {
      return {
        args: [enc, '-preset', 'veryfast', '-global_quality', kind === 'h264' ? '23' : '28'],
        encoder: enc,
      };
    }
    // AMF 的 balanced 在部分机器上慢得离谱（实测 4K 源只有 ~0.2x 实时），
    // 边转边播场景速度优先：speed 档 + 显式 qp，画质差异在 1080p/720p 档可接受。
    return {
      args: [enc, '-quality', 'speed', '-qp_i', kind === 'h264' ? '23' : '28'],
      encoder: enc,
    };
  }
  // CPU 路径同样按「边转边播」取舍：AV1 默认 preset=10 时 4K 源慢到 30 分钟都出不了片
  // （实测会话直接超时 1800000ms），这里取最快档；H.265 用 ultrafast 而不是 medium。
  if (kind === 'h265')
    return { args: ['libx265', '-preset', 'ultrafast', '-crf', '28', '-tag:v', 'hvc1'], encoder: 'libx265' };
  if (kind === 'av1') return { args: ['libsvtav1', '-preset', '12', '-crf', '32'], encoder: 'libsvtav1' };
  return { args: ['libx264', '-preset', 'veryfast', '-crf', '23'], encoder: 'libx264' };
}

/** HDR→SDR tonemap 链依赖 zscale + tonemap，进程内探测一次并缓存。
 *  缺任一个就退化成 format=yuv420p + 色彩标记，绝不让滤镜缺失拖垮整片转码。 */
let tonemapChainReady = null;
function hasTonemapChain() {
  if (tonemapChainReady !== null) return tonemapChainReady;
  let listing;
  try {
    const r = require('node:child_process').spawnSync(
      findFfmpeg(),
      ['-hide_banner', '-filters'],
      { encoding: 'utf8', timeout: 15000 },
    );
    listing = String(r.stdout || '');
  } catch {
    listing = '';
  }
  tonemapChainReady = /\bzscale\b/.test(listing) && /\btonemap\b/.test(listing);
  return tonemapChainReady;
}

async function hls(params) {
  const { src, dir } = params || {};
  if (!src || !dir) throw Object.assign(new Error('src/dir required'), { code: 'E_PARAM' });
  if (!fs.existsSync(src))
    throw Object.assign(new Error('src not found: ' + src), { code: 'E_NO_SRC' });

  fs.mkdirSync(dir, { recursive: true });
  // 新会话复用同一目录时先把「已取消」标记清掉；同一次 hls() 内部的重试不清，
  // 否则被抢占的旧会话会在重试里继续跑、和新会话抢 GPU。
  canceledHls.delete(dir);
  const presetRow =
    PLAY_QUALITY.presets.find((p) => p.key === params.preset) ||
    PLAY_QUALITY.presets.find((p) => p.key === PLAY_QUALITY.defaultPreset) ||
    PLAY_QUALITY.presets[0];
  const height = Number(presetRow.height) || 0;
  const hdrToSdr = params.hdrToSdr === true;
  // 片源视频编码：由上层从 video_items.video_codec 带下来。
  // 「原画（copy）」只有在片源本身就是 H.264 时才成立 —— 把 AV1 / HEVC 原样复制进
  // MPEG-TS 播放器根本解不出来（实测 hls.js 反复拉 init.mp4 后黑屏），
  // 所以非 H.264 片源即使选了原画也走转码（H.264）。
  const srcCodec = String(params.srcVideoCodec || '').toLowerCase();
  const srcH264 = /h264|avc/.test(srcCodec);
  const copyVideo = presetRow.copy === true && !params.subtitle && !hdrToSdr && srcH264;
  // 目标码率：按「这一档 × 当前编码」取，H.265 / AV1 同画质更省流量
  const targetKbps = copyVideo
    ? 0
    : Number((presetRow.bitrates || {})[params.codec] || presetRow.videoBitrateKbps || 0);
  // original 档 height=0：scale=-2:0 非法，改成保持原分辨率的合法滤镜
  const scale = height > 0 ? `scale=-2:${height}` : 'scale=iw:-2';
  // 非 copy 统一输出 8-bit yuv420p + BT.709 标记，避免 10-bit / 未标记色彩在浏览器发灰
  const tail = [scale];
  if (params.subtitle) tail.push("subtitles='" + escapeFilterPath(params.subtitle) + "'");
  if (!copyVideo) tail.push('format=yuv420p');
  const vfSdr = tail.join(',');
  // HDR→SDR：有 zscale/tonemap 才走完整 tonemap 链；片源无 HDR 元数据时链会报
  //「no path between colorspaces」，此时下面会退化成 vfSdr 重试，不让整片转码归零。
  const usedTonemap = hdrToSdr && !copyVideo && hasTonemapChain();
  const tonemapChain = [
    'zscale=t=linear:npl=100',
    'format=gbrpf32le',
    'tonemap=tonemap=hable:desat=0',
    'zscale=p=bt709:t=bt709:m=bt709:r=tv',
    'format=yuv420p',
  ];
  let vf = usedTonemap ? [...tonemapChain, ...tail].join(',') : vfSdr;
  const wantCodec = PLAY_QUALITY.codecs.some((c) => c.key === params.codec)
    ? params.codec
    : PLAY_QUALITY.defaultCodec;
  const timeoutMs = Math.max(Number(params.timeoutMs) || 0, 30 * 60 * 1000);
  // 首选解码器（auto / nvenc / qsv / amf / cpu）：只影响「用哪家硬件」，不影响编码格式
  const prefer = String(params.hwaccel || 'auto');
  // 响度归一：由库级开关决定（video_libraries.audio_normalize），这里只负责把它变成 ffmpeg 参数。
  // 用 dynaudnorm 而不是 loudnorm：单遍、实时友好，适合边转边播。
  const audioFilter = String(params.audioFilter || '').trim();
  // 音轨序号：默认 0；负数 / 非整数回落 0
  const an = Number(params.audioIndex);
  const audioIndex = Number.isInteger(an) && an >= 0 ? an : 0;
  // 硬件编码器探测（异步 + 缓存）：不阻塞心跳，结果供所有 attempt 复用
  const hw = await detectHwAll();

  const attempt = async (codec, allowHw = true) => {
    // 被抢占（换档 / 新会话）时立即收手：旧会话的重试链不能再起新 ffmpeg
    if (canceledHls.has(dir)) {
      throw Object.assign(new Error('ffmpeg canceled'), { code: 'E_CANCELED' });
    }
    // 封装由契约决定：h265 / av1 → fMP4（带 EXT-X-MAP），h264 → MPEG-TS
    const container =
      (PLAY_QUALITY.codecs.find((c) => c.key === codec) || {}).container || 'mpegts';
    const fmp4 = container === 'fmp4';
    // 硬件编码能探测到就用（参数见 videoCodecArgs），否则原样走 CPU
    const vc = videoCodecArgs(codec, allowHw, prefer, hw);
    const vCodec = vc.args;

    // 清掉上一次尝试的产物，避免残留 index.m3u8 让「降级」误判成功
    for (const f of fs.existsSync(dir) ? fs.readdirSync(dir) : []) {
      try {
        fs.unlinkSync(nodePath.join(dir, f));
      } catch {
        /* 忽略 */
      }
    }

    const args = [
      '-hide_banner',
      '-loglevel',
      'error',
      '-y',
      '-i',
      src,
      // 显式选流：视频第 0 条、指定音轨（`?` 让越界时不选音轨而非整片失败）
      '-map',
      '0:v:0',
      '-map',
      `0:a:${audioIndex}?`,
      ...(copyVideo ? ['-c:v', 'copy'] : ['-vf', vf, '-c:v', ...vCodec]),
      // 色彩标记：输出统一标为 BT.709 SDR，避免播放器按源元数据乱解
      ...(!copyVideo
        ? ['-color_primaries', 'bt709', '-color_trc', 'bt709', '-colorspace', 'bt709']
        : []),
      // CRF 定质量 + maxrate 兜住流量上限（原画直通不控码率）
      ...(!copyVideo && targetKbps > 0
        ? ['-maxrate', `${targetKbps}k`, '-bufsize', `${targetKbps * 2}k`]
        : []),
      ...(audioFilter ? ['-af', audioFilter] : []),
      '-g',
      '48',
      '-keyint_min',
      '48',
      '-sc_threshold',
      '0',
      '-c:a',
      'aac',
      '-b:a',
      String(PLAY_QUALITY.audioBitrateKbps) + 'k',
      '-ac',
      '2',
      '-f',
      'hls',
      '-hls_time',
      '6',
      // 首片更短（2s）：让播放列表更早出现、起播更快；后续仍按 6s 切。
      '-hls_init_time',
      '2',
      // VOD 要等全片转完才写 index.m3u8：4K HDR 整片几十分钟，期间一个分片
      // 都播不了。EVENT 在第一个分片落盘时就写出播放列表并持续追加，hls.js
      // 按 live 语义定时刷新 → 边转边播。list_size=0 保留全部分片，
      // 否则默认滚动窗口只有 5 片，用户没法拖回片头。
      '-hls_playlist_type',
      'event',
      '-hls_list_size',
      '0',
    ];
    if (fmp4) {
      args.push(
        '-hls_segment_type',
        'fmp4',
        '-hls_fmp4_init_filename',
        'init.mp4',
        '-hls_segment_filename',
        nodePath.join(dir, 'seg%05d.m4s'),
      );
    } else {
      args.push('-hls_segment_filename', nodePath.join(dir, 'seg%05d.ts'));
    }
    args.push(nodePath.join(dir, 'index.m3u8'));

    const started = process.hrtime.bigint();
    await limit(() =>
      runFfmpeg(args, timeoutMs, {
        cwd: dir,
        hlsKey: dir,
        watch: {
          dir,
          firstMs: Number(process.env.COLANAS_HLS_FIRST_SEGMENT_MS) || 90000,
          idleMs: Number(process.env.COLANAS_HLS_STALL_MS) || 120000,
        },
      }),
    );

    const playlist = nodePath.join(dir, 'index.m3u8');
    if (!fs.existsSync(playlist))
      throw Object.assign(new Error('hls output missing'), { code: 'E_FFMPEG' });
    const text = fs.readFileSync(playlist, 'utf8');
    if (fmp4 && !text.includes('#EXT-X-MAP')) {
      throw Object.assign(new Error('fmp4 playlist missing EXT-X-MAP'), { code: 'E_FFMPEG' });
    }
    const segments = fs.readdirSync(dir).filter((f) => f.endsWith('.ts') || f.endsWith('.m4s')).length;
    return {
      segments,
      ms: Number(process.hrtime.bigint() - started) / 1e6,
      codec,
      container: fmp4 ? 'fmp4' : 'mpegts',
      playlist,
      // 实际用的编码器：排障时能一眼看出「到底硬件跑了没有」
      encoder: vc.encoder,
    };
  };

  let result;
  // 原画复制只可能是 H.264 in MPEG-TS：容器/编码标签必须跟着实际输出走，
  // 否则会出现「界面显示 AV1、实际拷的是 H.264 却塞进 fMP4」的错位。
  const outputCodec = copyVideo ? 'h264' : wantCodec;
  const hwKind = outputCodec === 'h265' ? 'h265' : outputCodec === 'av1' ? 'av1' : 'h264';
  const wantHw = hw[hwKind][0] || null;
  const runAll = async () => {
    try {
      return await attempt(outputCodec, true);
    } catch (err) {
      // 主动取消（新会话抢占旧会话）不是故障：直接冒泡，别浪费时间换编码器重试。
      if (err && err.code === 'E_CANCELED') throw err;
      // 探测到了硬件、但这次真的编不动（驱动版本、显存、参数组合）→ 同一 codec 回退 CPU。
      // 不能直接跳到 h264：那会牺牲画质来换「硬件」，而用户要的是「别卡」。
      if (wantHw) {
        console.error(
          `[media] hls ${outputCodec} failed on ${wantHw}, retry on CPU: ${String((err && err.message) || err)}`,
        );
        try {
          return await attempt(outputCodec, false);
        } catch (cpuErr) {
          if (cpuErr && cpuErr.code === 'E_CANCELED') throw cpuErr;
          if (outputCodec === 'h264') throw cpuErr;
          console.error(
            `[media] hls ${outputCodec} failed on CPU, fallback to h264: ${String((cpuErr && cpuErr.message) || cpuErr)}`,
          );
          return await attempt('h264', false);
        }
      } else {
        if (outputCodec === 'h264') throw err;
        console.error(
          `[media] hls ${outputCodec} failed, fallback to h264: ${String((err && err.message) || err)}`,
        );
        return await attempt('h264', false);
      }
    }
  };
  try {
    result = await runAll();
  } catch (err) {
    if (err && err.code === 'E_CANCELED') throw err;
    // tonemap 链在片源上跑不通（无 HDR 元数据 / 色彩路径不通）→ 退化成纯 SDR 转换重试，
    // 绝不让滤镜失败拖垮整片转码。
    if (usedTonemap) {
      console.error(
        `[media] hls tonemap chain failed, fallback to SDR: ${String((err && err.message) || err)}`,
      );
      vf = vfSdr;
      result = await runAll();
    } else {
      throw err;
    }
  }

  stats.transcodes += 1;
  return { dir, ...result };
}
/**
 * 取消某个目录下正在跑的 HLS 转码（新会话抢占旧会话 / 用户换档时调用）。
 * 只 kill 精确匹配的 ffmpeg；取消标记让 runFfmpeg 抛 E_CANCELED，上层不重试。
 */
async function cancel(params) {
  const { dir } = params || {};
  if (!dir) throw Object.assign(new Error('dir required'), { code: 'E_PARAM' });
  // 先打标记再找 child：旧会话可能正好处在「上一次 attempt 已退出、下一次还没
  // 起来」的窗口里。只 kill 当前 child 的话，它接下来还会继续重试 —— 旧进程
  // 和新会话同时抢 GPU（实测两路 AMF 并发会把编码器卡死）。
  canceledHls.add(dir);
  const child = activeHls.get(dir);
  if (!child) return { canceled: true };
  try {
    child.kill('SIGKILL');
  } catch {
    /* 已退出 */
  }
  return { canceled: true };
}

async function bench(params) {
  const { src, dir } = params || {};
  if (!src || !dir) throw Object.assign(new Error('src/dir required'), { code: 'E_PARAM' });
  const count = Math.max(1, Math.min(Number(params.count) || 500, 5000));
  const size = Math.max(16, Math.min(Number(params.size) || 256, 4096));

  fs.mkdirSync(dir, { recursive: true });
  const started = process.hrtime.bigint();
  const tasks = [];
  for (let i = 0; i < count; i++) {
    tasks.push(thumb({ src, dst: nodePath.join(dir, `t${String(i).padStart(4, '0')}.jpg`), size }));
  }
  await Promise.all(tasks);
  const ms = Number(process.hrtime.bigint() - started) / 1e6;
  return { count, ms, throughput: (count / ms) * 1000, concurrency: CONCURRENCY };
}

async function handle(msg) {
  if (msg.type === 'ping') {
    send({ id: msg.id, ok: true, result: 'pong' });
    return;
  }
  if (msg.type === 'shutdown') {
    send({ id: msg.id, ok: true });
    setTimeout(() => process.exit(0), 5);
    return;
  }
  if (msg.type !== 'invoke') {
    send({ type: 'log', level: 'warn', message: `unknown message type: ${msg.type}` });
    return;
  }

  const handlers = {
    thumb,
    transcode,
    hls,
    cancel,
    subtitleTracks,
    extractSubtitle,
    bench,
    stats: async () => ({
      ...stats,
      ffmpeg: FFMPEG,
      concurrency: CONCURRENCY,
      cpus: cpus().length,
    }),
  };
  const fn = handlers[msg.method];
  if (!fn) {
    send({
      id: msg.id,
      ok: false,
      error: { code: 'E_METHOD', message: `unknown method: ${msg.method}` },
    });
    return;
  }

  try {
    const result = await fn(msg.params || {});
    send({ id: msg.id, ok: true, result });
  } catch (err) {
    stats.fails += 1;
    send({
      id: msg.id,
      ok: false,
      error: { code: err.code || 'E_MEDIA', message: String(err.message || err) },
    });
  }
}

process.stdin.on('data', (chunk) => {
  buf += chunk;
  let idx = buf.indexOf('\n');
  while (idx >= 0) {
    const line = buf.slice(0, idx).trim();
    buf = buf.slice(idx + 1);
    if (line) {
      try {
        handle(JSON.parse(line));
      } catch {
        send({ type: 'log', level: 'warn', message: 'bad ndjson line' });
      }
    }
    idx = buf.indexOf('\n');
  }
});

process.stdin.on('end', () => process.exit(0));
