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

function runFfmpeg(args, timeoutMs = 120_000) {
  return new Promise((resolve, reject) => {
    const child = spawn(FFMPEG, args, { windowsHide: true, stdio: ['ignore', 'ignore', 'pipe'] });
    let err = '';
    const timer = setTimeout(() => {
      try {
        child.kill('SIGKILL');
      } catch {
        /* 忽略 */
      }
      reject(Object.assign(new Error('ffmpeg timeout'), { code: 'E_TIMEOUT' }));
    }, timeoutMs);

    child.stderr.on('data', (c) => {
      err += String(c);
      if (err.length > 8192) err = err.slice(-4096);
    });
    child.on('error', (e) => {
      clearTimeout(timer);
      reject(
        Object.assign(new Error(`ffmpeg spawn failed: ${e.message}`), { code: 'E_NO_FFMPEG' }),
      );
    });
    child.on('exit', (code) => {
      clearTimeout(timer);
      if (code === 0) resolve();
      else
        reject(
          Object.assign(new Error(`ffmpeg exited ${code}: ${err.slice(-400)}`), {
            code: 'E_FFMPEG',
          }),
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
let hwEncoders = null;
function detectHwEncoders() {
  if (hwEncoders) return hwEncoders;
  const found = { h264: null, h265: null, av1: null };
  let listing = '';
  try {
    const r = require('node:child_process').spawnSync(findFfmpeg(), ['-hide_banner', '-encoders'], {
      encoding: 'utf8',
      timeout: 15000,
    });
    listing = String(r.stdout || '');
  } catch {
    listing = '';
  }
  const pick = (names) => {
    for (const name of names) {
      if (listing.includes(name)) return name;
    }
    return null;
  };
  // 优先顺序按「画质 / 兼容性」排：nvenc 参数最稳，qsv 次之，amf 最后
  found.h264 = pick(['h264_nvenc', 'h264_qsv', 'h264_amf']);
  found.h265 = pick(['hevc_nvenc', 'hevc_qsv', 'hevc_amf']);
  found.av1 = pick(['av1_nvenc', 'av1_qsv', 'av1_amf']);
  hwEncoders = found;
  return found;
}

/** 按 codec 给出编码器参数（不含 `-c:v`）。`allowHw=false` 时强制 CPU。 */
function videoCodecArgs(codec, allowHw) {
  const kind = codec === 'h265' ? 'h265' : codec === 'av1' ? 'av1' : 'h264';
  const enc = allowHw ? detectHwEncoders()[kind] : null;
  if (enc) {
    if (enc.endsWith('_nvenc')) {
      // p4 = 均衡档；-cq 是恒定质量（数值语义接近 crf）
      return { args: [enc, '-preset', 'p4', '-cq', kind === 'h264' ? '23' : '28'], encoder: enc };
    }
    if (enc.endsWith('_qsv')) {
      return { args: [enc, '-global_quality', kind === 'h264' ? '23' : '28'], encoder: enc };
    }
    return { args: [enc, '-quality', 'balanced', '-qp_i', kind === 'h264' ? '23' : '28'], encoder: enc };
  }
  if (kind === 'h265') return { args: ['libx265', '-crf', '28', '-tag:v', 'hvc1'], encoder: 'libx265' };
  if (kind === 'av1') return { args: ['libsvtav1', '-crf', '32'], encoder: 'libsvtav1' };
  return { args: ['libx264', '-preset', 'veryfast', '-crf', '23'], encoder: 'libx264' };
}

async function hls(params) {
  const { src, dir } = params || {};
  if (!src || !dir) throw Object.assign(new Error('src/dir required'), { code: 'E_PARAM' });
  if (!fs.existsSync(src))
    throw Object.assign(new Error('src not found: ' + src), { code: 'E_NO_SRC' });

  fs.mkdirSync(dir, { recursive: true });
  const presetRow =
    PLAY_QUALITY.presets.find((p) => p.key === params.preset) ||
    PLAY_QUALITY.presets.find((p) => p.key === PLAY_QUALITY.defaultPreset) ||
    PLAY_QUALITY.presets[0];
  const height = presetRow.height;
  const scale = `scale=-2:${height}`;
  const vf = params.subtitle
    ? scale + ",subtitles='" + escapeFilterPath(params.subtitle) + "'"
    : scale;
  const wantCodec = PLAY_QUALITY.codecs.some((c) => c.key === params.codec)
    ? params.codec
    : PLAY_QUALITY.defaultCodec;
  const timeoutMs = Math.max(Number(params.timeoutMs) || 0, 30 * 60 * 1000);
  // 响度归一：由库级开关决定（video_libraries.audio_normalize），这里只负责把它变成 ffmpeg 参数。
  // 用 dynaudnorm 而不是 loudnorm：单遍、实时友好，适合边转边播。
  const audioFilter = String(params.audioFilter || '').trim();

  const attempt = async (codec, allowHw = true) => {
    // 封装由契约决定：h265 / av1 → fMP4（带 EXT-X-MAP），h264 → MPEG-TS
    const container =
      (PLAY_QUALITY.codecs.find((c) => c.key === codec) || {}).container || 'mpegts';
    const fmp4 = container === 'fmp4';
    // 硬件编码能探测到就用（参数见 videoCodecArgs），否则原样走 CPU
    const vc = videoCodecArgs(codec, allowHw);
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
      '-vf',
      vf,
      '-c:v',
      ...vCodec,
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
      '-hls_playlist_type',
      'vod',
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
    await limit(() => runFfmpeg(args, timeoutMs));

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
  const wantHw = detectHwEncoders()[wantCodec === 'h265' ? 'h265' : wantCodec === 'av1' ? 'av1' : 'h264'];
  try {
    result = await attempt(wantCodec, true);
  } catch (err) {
    // 探测到了硬件、但这次真的编不动（驱动版本、显存、参数组合）→ 同一 codec 回退 CPU。
    // 不能直接跳到 h264：那会牺牲画质来换「硬件」，而用户要的是「别卡」。
    if (wantHw) {
      console.error(
        `[media] hls ${wantCodec} failed on ${wantHw}, retry on CPU: ${String((err && err.message) || err)}`,
      );
      try {
        result = await attempt(wantCodec, false);
      } catch (cpuErr) {
        if (wantCodec === 'h264') throw cpuErr;
        console.error(
          `[media] hls ${wantCodec} failed on CPU, fallback to h264: ${String((cpuErr && cpuErr.message) || cpuErr)}`,
        );
        result = await attempt('h264', false);
      }
    } else {
      if (wantCodec === 'h264') throw err;
      console.error(
        `[media] hls ${wantCodec} failed, fallback to h264: ${String((err && err.message) || err)}`,
      );
      result = await attempt('h264', false);
    }
  }

  stats.transcodes += 1;
  return { dir, ...result };
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
