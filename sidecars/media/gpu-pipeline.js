#!/usr/bin/env node
/**
 * 硬件转码链路决策（纯函数，可被 smoke 直接 require）。
 *
 * 实测基线（jellyfin-ffmpeg 8.1.3，Radeon 780M，4K HEVC / DV P5，30s 片段）：
 *   软解 + scale + AMF                    8951 ms（且 DV 片源颜色错）
 *   d3d11va（默认 hwdownload）+ AMF       7634 ms（来回拷贝吃掉收益）
 *   d3d11 零拷贝 + tonemap_d3d11 + AMF   5328 ms（1.68x，颜色正确）
 *   Vulkan libplacebo + AMF             14000 ms（颜色正确但慢，只做回退）
 * 结论：解码 / 缩放 / tonemap 必须全留在显存里，编码器直接吃硬件帧才有收益。
 *
 * 三家厂商的硬件滤镜名不同，但链路同构：
 *   AMD    d3d11va → d3d11 帧 → tonemap_d3d11 / scale_d3d11 → *_amf
 *   NVIDIA cuda    → cuda 帧  → tonemap_cuda  / scale_cuda  → *_nvenc
 *   Intel  qsv     → qsv 帧   → vpp_qsv(tonemap) / scale_qsv → *_qsv
 * 只有 AMD 在本机实测通过；NVIDIA / Intel 走「滤镜能力探测 + 自动回退」，
 * 不在没有对应硬件的机器上假装验证过。
 *
 * Dolby Vision 特别注意：`tonemap_d3d11` / `tonemap_cuda` 的 `apply_dovi` 默认开启，
 * 能自己吃 DV RPU。实测手动指定 `transfer=smpte2084:matrix=bt2020` 反而把画面压到全黑，
 * 所以这里一律不覆盖输入色彩参数，交给滤镜自动识别。
 */
'use strict';

const { spawnSync } = require('node:child_process');
const { EMPTY_SOURCE, parseSource } = require('./source-probe');

/** `-hwaccels` / `-filters` 各探一次：单次几十毫秒，进程内结果不变。 */
let hwaccelsCache = null;
let filtersCache = null;

function detectHwaccels(ffmpeg) {
  if (hwaccelsCache !== null) return hwaccelsCache;
  try {
    const r = spawnSync(ffmpeg, ['-hide_banner', '-hwaccels'], {
      encoding: 'utf8', timeout: 10000, windowsHide: true,
    });
    hwaccelsCache = String(r.stdout || '').toLowerCase();
  } catch {
    hwaccelsCache = '';
  }
  return hwaccelsCache;
}

function detectFilters(ffmpeg) {
  if (filtersCache !== null) return filtersCache;
  try {
    const r = spawnSync(ffmpeg, ['-hide_banner', '-filters'], {
      encoding: 'utf8', timeout: 15000, windowsHide: true,
    });
    filtersCache = String(r.stdout || '').toLowerCase();
  } catch {
    filtersCache = '';
  }
  return filtersCache;
}

/** 仅供测试重置缓存 */
function resetHwaccelsCacheForTest() {
  hwaccelsCache = null;
  filtersCache = null;
}
const resetFiltersCacheForTest = resetHwaccelsCacheForTest;

function hasCap(text, name) {
  return String(text || '').toLowerCase().includes(String(name).toLowerCase());
}

function vendorOf(encoder) {
  const e = String(encoder || '');
  if (/_amf$/.test(e)) return 'amd';
  if (/_nvenc$/.test(e)) return 'nvidia';
  if (/_qsv$/.test(e)) return 'intel';
  return 'cpu';
}

const CPU_PLAN = Object.freeze({
  decoder: 'cpu',
  pipeline: 'cpu',
  inputArgs: Object.freeze([]),
  gpu: false,
  vendor: 'cpu',
});

/** CPU 的 HDR→SDR 链：只在片源带标准色彩元数据时才可用。 */
const TONEMAP_CHAIN = Object.freeze([
  'zscale=t=linear:npl=100',
  'format=gbrpf32le',
  'tonemap=tonemap=hable:desat=0',
  'zscale=p=bt709:t=bt709:m=bt709:r=tv',
  'format=yuv420p',
]);

/** DV / 无标记 HDR 片源：先补成 BT.2020 PQ，再交给 GPU 滤镜。 */
const PQ_MARK = 'setparams=color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc:range=pc';

function sizeExpr(ctx) {
  return Number(ctx.height) > 0
    ? { w: '-2', h: String(Number(ctx.height)) }
    : { w: 'iw', h: 'ih' };
}

/**
 * CPU `zscale=t=linear` 依赖帧上的标准色彩标记。DV P5 / 无标记 10-bit 片源
 * 实测直接 `-22 Invalid argument`；项目旧逻辑会关掉 tonemap 重跑，输出偏紫的错色画面。
 */
function cpuTonemapUsable(ctx) {
  const s = ctx.source || EMPTY_SOURCE;
  return Boolean(s.hasHdrMeta) && !s.dvProfile;
}

/** Vulkan / libplacebo：跨厂商的正确回退（实测画面正常，但比零拷贝慢 2.6x）。 */
function placeboFilter(ctx, tonemapOn) {
  const tail = ctx.tailParts || [];
  if (!(tonemapOn && ctx.hdrToSdr)) return tail.join(',');
  const { w, h } = sizeExpr(ctx);
  const parts = [
    PQ_MARK,
    `libplacebo=w=${w}:h=${h}:format=yuv420p:color_primaries=bt709:` +
      'color_trc=bt709:colorspace=bt709:tonemapping=5',
  ];
  if (ctx.subtitleFilter) parts.push(ctx.subtitleFilter);
  parts.push('format=yuv420p');
  return parts.join(',');
}

/**
 * CPU / 普通硬解链用的滤镜：软件帧，含缩放、字幕烧录与 8-bit 输出。
 * `subtitles` 是软件滤镜，吃不了硬件帧，所以只在软件帧链里出现。
 */
function cpuFilter(ctx, tonemapOn) {
  const tail = ctx.tailParts || [];
  if (tonemapOn && ctx.hdrToSdr) {
    if (cpuTonemapUsable(ctx)) return [...TONEMAP_CHAIN, ...tail].join(',');
    if (hasCap(ctx.filters, 'libplacebo')) return placeboFilter(ctx, true);
    // 没有 libplacebo 的构建：补标后仍走 zscale，至少不会输出完全未映射的 PQ 画面。
    return [PQ_MARK, ...TONEMAP_CHAIN, ...tail].join(',');
  }
  return tail.join(',');
}

/** 硬件帧链：tonemap → scale 全在显存；有字幕时只下载一次给 libass 烧录。 */
function gpuFilter(ctx, tonemapOn) {
  const v = vendorOf(ctx.encoder);
  const { w, h } = sizeExpr(ctx);
  const hdr = Boolean(tonemapOn && ctx.hdrToSdr);
  const parts = [];
  if (v === 'amd') {
    if (hdr) parts.push('tonemap_d3d11=tonemap=hable');
    parts.push(`scale_d3d11=w=${w}:h=${h}:format=nv12`);
  } else if (v === 'nvidia') {
    if (hdr) parts.push('tonemap_cuda=tonemap=bt2390:apply_dovi=1:format=nv12');
    parts.push(`scale_cuda=w=${w}:h=${h}:format=nv12`);
  } else if (v === 'intel') {
    // vpp_qsv 的 w=-1 表示保持宽高比（与 scale 的 -2 语义不同）；
    // tonemap=1 只在输入带 HDR10 元数据时生效 —— 它**不吃杜比视界 RPU**，
    // DV P5 的 IPTPQc2 会被当成普通 PQ 处理，出来一片偏绿偏紫。
    // 所以 DV 片源不会走到这里：canUseGpuZeroCopy 对 intel + DV 直接返回 false，
    // 退到「硬解 + libplacebo」那条链（见 cpuFilter）。
    if (hdr) {
      parts.push(
        `vpp_qsv=tonemap=1:w=-1:h=${h}:format=nv12:` +
          'out_color_matrix=bt709:out_color_primaries=bt709:out_color_transfer=bt709',
      );
    } else {
      parts.push(`scale_qsv=w=-1:h=${h}:format=nv12`);
    }
  }
  if (ctx.subtitleFilter) {
    parts.push('hwdownload', 'format=nv12', ctx.subtitleFilter, 'format=nv12');
  }
  return parts.join(',');
}

/** H.264 10-bit 三家硬解都不支持；遇到就整条退回软解。 */
function hardwareDecodeAllowed(ctx) {
  return !(ctx.source || EMPTY_SOURCE).hi10p;
}

function canUseGpuZeroCopy(ctx) {
  if (ctx.prefer === 'cpu' || ctx.copyVideo || !hardwareDecodeAllowed(ctx)) return false;
  const v = vendorOf(ctx.encoder);
  if (v === 'amd') {
    return ctx.platform === 'win32' &&
      hasCap(ctx.hwaccels, 'd3d11va') && hasCap(ctx.filters, 'scale_d3d11');
  }
  if (v === 'nvidia') {
    return hasCap(ctx.hwaccels, 'cuda') && hasCap(ctx.filters, 'scale_cuda');
  }
  if (v === 'intel') {
    // DV 的 RPU 只有 libplacebo / tonemap_cuda 认，vpp_qsv 认不出来 → 不让它上零拷贝，
    // 退到「qsv 硬解 + libplacebo 软件 tonemap」，慢一点但颜色是对的。
    if ((ctx.source || EMPTY_SOURCE).dvProfile) return false;
    return hasCap(ctx.hwaccels, 'qsv') && hasCap(ctx.filters, 'scale_qsv');
  }
  return false;
}

/** CPU 编码器：解码上 GPU、下载一次给编码器，实测约 1.16x，值得开。 */
function canUseHwDecode(ctx) {
  if (ctx.prefer === 'cpu' || ctx.copyVideo || !hardwareDecodeAllowed(ctx)) return false;
  if (!/^lib(?:x264|x265|svtav1)/.test(String(ctx.encoder || ''))) return false;
  if (ctx.platform === 'win32' && hasCap(ctx.hwaccels, 'd3d11va')) return true;
  return hasCap(ctx.hwaccels, 'cuda') || hasCap(ctx.hwaccels, 'qsv');
}

function hardwarePlan(ctx) {
  const v = vendorOf(ctx.encoder);
  const method = v === 'amd' ? 'd3d11va' : v === 'nvidia' ? 'cuda' : 'qsv';
  const frames = v === 'amd' ? 'd3d11' : v === 'nvidia' ? 'cuda' : 'qsv';
  return {
    decoder: method,
    vendor: v,
    pipeline: ctx.subtitleFilter ? 'gpu-hybrid' : 'gpu-zero-copy',
    inputArgs: ['-hwaccel', method, '-hwaccel_output_format', frames],
    gpu: true,
    filter: (tonemapOn) => gpuFilter(ctx, tonemapOn),
  };
}

function hwDecodePlan(ctx) {
  let method = 'd3d11va';
  if (!(ctx.platform === 'win32' && hasCap(ctx.hwaccels, 'd3d11va'))) {
    method = hasCap(ctx.hwaccels, 'cuda') ? 'cuda' : 'qsv';
  }
  return {
    decoder: method,
    vendor: method === 'cuda' ? 'nvidia' : method === 'qsv' ? 'intel' : 'amd',
    pipeline: 'hw-decode',
    inputArgs: ['-hwaccel', method],
    gpu: false,
  };
}

/**
 * 按优先级给出解码方案，调用方逐个尝试、失败自动回退：
 *   硬件零拷贝（或字幕混合链）→ 普通硬解 → CPU 软解（永远保底）
 * CPU 软解这一级的滤镜由 `cpuFilter()` 给出，对 DV / 无标记片源会自动换成
 * libplacebo，避免 legacy `zscale` 失败后输出错色画面。
 */
function buildPlans(ctx) {
  const plans = [];
  if (canUseGpuZeroCopy(ctx)) plans.push(hardwarePlan(ctx));
  else if (canUseHwDecode(ctx)) plans.push(hwDecodePlan(ctx));
  plans.push(CPU_PLAN);
  return plans;
}

module.exports = {
  CPU_PLAN,
  TONEMAP_CHAIN,
  PQ_MARK,
  EMPTY_SOURCE,
  parseSource,
  detectHwaccels,
  detectFilters,
  resetHwaccelsCacheForTest,
  resetFiltersCacheForTest,
  vendorOf,
  hasCap,
  cpuTonemapUsable,
  cpuFilter,
  placeboFilter,
  gpuFilter,
  canUseGpuZeroCopy,
  canUseHwDecode,
  hardwarePlan,
  hwDecodePlan,
  buildPlans,
  /** 兼容旧调用 / 旧 smoke 断言 */
  decodePlans: buildPlans,
};
