#!/usr/bin/env node
/**
 * 拉取并校验 Jellyfin 定制版 ffmpeg 到 `vendor/ffmpeg/`（二进制不入库）。
 *
 * 为什么用 jellyfin-ffmpeg：它在上游 ffmpeg 之上带了一组媒体服务器场景的补丁
 * （HDR→SDR / 杜比视界 / QSV·VAAPI·NVENC 链路 / 字幕烧录），二期的转码直接受益。
 *
 * 用法：
 *   node tool/fetch-ffmpeg.js                 # 默认版本 v8.1.3-1，下载 + 校验 + 解压
 *   node tool/fetch-ffmpeg.js --check         # 只检查 vendor 是否就绪
 *   node tool/fetch-ffmpeg.js --version=v8.1.3-1
 *   node tool/fetch-ffmpeg.js --sha256=<hex>  # 跳过 GitHub API，用给定校验值
 *
 * 目录约定（与 src/modules/video/ffmpeg.ts 的探测顺序一致）：
 *   vendor/ffmpeg/ffmpeg(.exe)  或  vendor/ffmpeg/bin/ffmpeg(.exe)  以及同目录 ffprobe
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');
const { Readable } = require('node:stream');
const { pipeline } = require('node:stream/promises');

const ROOT = path.join(__dirname, '..');
const OUT_DIR = path.join(ROOT, 'vendor', 'ffmpeg');

const args = process.argv.slice(2);
const checkOnly = args.includes('--check');
const versionArg = args.find((a) => a.startsWith('--version='));
const shaArg = args.find((a) => a.startsWith('--sha256='));
const archiveArg = args.find((a) => a.startsWith('--archive='));
const LOCAL_ARCHIVE = archiveArg ? path.resolve(archiveArg.split('=')[1]) : null;
const VERSION = (versionArg ? versionArg.split('=')[1] : process.env.JELLYFIN_FFMPEG_VERSION || 'v8.1.3-1').replace(/^v/, '');
const EXPECTED_SHA = shaArg ? shaArg.split('=')[1].toLowerCase() : null;

const EXE = process.platform === 'win32' ? 'ffmpeg.exe' : 'ffmpeg';

function localBinary() {
  const cands = [path.join(OUT_DIR, EXE), path.join(OUT_DIR, 'bin', EXE)];
  return cands.find((p) => fs.existsSync(p)) || null;
}

function assetSuffix() {
  const p = process.platform;
  const a = process.arch;
  if (p === 'win32') return a === 'arm64' ? 'portable_winarm64-clang-gpl.zip' : 'portable_win64-clang-gpl.zip';
  if (p === 'linux') return a === 'arm64' ? 'portable_linuxarm64-gpl.tar.xz' : 'portable_linux64-gpl.tar.xz';
  if (p === 'darwin') return a === 'arm64' ? 'portable_macarm64-gpl.tar.xz' : 'portable_mac64-gpl.tar.xz';
  throw new Error(`unsupported platform: ${p}/${a}`);
}

function printVersion(bin) {
  const r = spawnSync(bin, ['-version'], { encoding: 'utf-8' });
  const first = (r.stdout || '').split('\n')[0].trim();
  console.log(`[ffmpeg] ${bin}`);
  console.log(`[ffmpeg] ${first || '(无法读取版本)'}`);
}

async function resolveAsset() {
  const suffix = assetSuffix();
  const name = `jellyfin-ffmpeg_${VERSION}_${suffix}`;
  const res = await fetch(`https://api.github.com/repos/jellyfin/jellyfin-ffmpeg/releases/tags/v${VERSION}`, {
    headers: { 'user-agent': 'ColaNasOs', accept: 'application/vnd.github+json' },
  });
  if (!res.ok) throw new Error(`GitHub API ${res.status}（可加 --sha256 跳过）`);
  const release = await res.json();
  const asset = (release.assets || []).find((a) => a.name === name);
  if (!asset) throw new Error(`release v${VERSION} 中没有 ${name}`);
  const digest = String(asset.digest || '');
  return {
    name,
    url: asset.browser_download_url,
    size: asset.size,
    sha256: EXPECTED_SHA || (digest.startsWith('sha256:') ? digest.slice(7) : null),
  };
}

async function sha256File(file) {
  const hash = crypto.createHash('sha256');
  await pipeline(fs.createReadStream(file), hash);
  return hash.digest('hex');
}

async function download(url, dest, expectedSize) {
  // GitHub Releases 在部分网络下需要代理：优先用系统 curl（支持 -x），避免给 Node fetch 引入代理依赖
  const proxy = process.env.COLANAS_FFMPEG_PROXY || process.env.HTTPS_PROXY || process.env.https_proxy;
  const hasCurl = spawnSync('curl', ['--version'], { encoding: 'utf-8' }).status === 0;
  if (hasCurl) {
    if (proxy) console.log(`[ffmpeg] 使用代理 ${proxy}`);
    for (let attempt = 1; attempt <= 5; attempt += 1) {
      const args = ['-sS', '-L', '--fail', '-C', '-', '--max-time', '600', '-o', dest, url];
      if (proxy) args.unshift('-x', proxy);
      const r = spawnSync('curl', args, { stdio: 'inherit' });
      const size = fs.existsSync(dest) ? fs.statSync(dest).size : 0;
      if (r.status === 0 && (!expectedSize || size >= expectedSize)) return;
      if (expectedSize && size >= expectedSize) return;
      console.log(`[ffmpeg] 下载未完成（exit ${r.status}，${size} 字节），续传第 ${attempt + 1} 次`);
    }
    throw new Error('curl 下载失败（多次续传后仍未完成）');
  }

  const res = await fetch(url, { redirect: 'follow', headers: { 'user-agent': 'ColaNasOs' } });
  if (!res.ok || !res.body) throw new Error(`下载失败: HTTP ${res.status}`);
  await pipeline(Readable.fromWeb(res.body), fs.createWriteStream(dest));
}

function extract(archive, dir) {
  // Windows 10+ / Linux / macOS 都自带 bsdtar，可解 zip 与 tar.xz
  const r = spawnSync('tar', ['-xf', archive, '-C', dir], { stdio: 'inherit' });
  if (r.status !== 0) throw new Error('解压失败：需要系统自带 tar（Windows 10+ 已内置）');
}

(async () => {
  const existing = localBinary();
  if (checkOnly) {
    if (!existing) {
      console.error('[ffmpeg] vendor/ffmpeg 未就绪，运行 node tool/fetch-ffmpeg.js');
      process.exit(1);
    }
    printVersion(existing);
    process.exit(0);
  }

  if (existing) {
    printVersion(existing);
    console.log('[ffmpeg] vendor/ffmpeg 已存在；如需升级请先删除该目录');
    process.exit(0);
  }

  const asset = LOCAL_ARCHIVE
    ? {
        name: path.basename(LOCAL_ARCHIVE),
        url: '',
        size: fs.statSync(LOCAL_ARCHIVE).size,
        sha256: EXPECTED_SHA,
      }
    : await resolveAsset();
  console.log(`[ffmpeg] ${LOCAL_ARCHIVE ? '本地包' : `release v${VERSION}`} → ${asset.name} (${(asset.size / 1024 / 1024).toFixed(1)} MB)`);

  fs.mkdirSync(path.join(ROOT, '.devdata'), { recursive: true });
  const tmpDir = fs.mkdtempSync(path.join(ROOT, '.devdata', 'ffmpeg-'));
  const archive = LOCAL_ARCHIVE || path.join(tmpDir, asset.name);

  try {
    if (!LOCAL_ARCHIVE) await download(asset.url, archive, asset.size);
    const actual = await sha256File(archive);
    if (asset.sha256 && actual !== asset.sha256) {
      throw new Error(`sha256 不匹配\n  期望 ${asset.sha256}\n  实际 ${actual}`);
    }
    console.log(`[ffmpeg] sha256 ${actual.slice(0, 16)}… ✓`);

    fs.rmSync(OUT_DIR, { recursive: true, force: true });
    fs.mkdirSync(OUT_DIR, { recursive: true });
    extract(archive, OUT_DIR);

    const bin = localBinary();
    if (!bin) throw new Error('解压后未找到 ffmpeg 可执行文件');
    printVersion(bin);

    const probe = path.join(path.dirname(bin), process.platform === 'win32' ? 'ffprobe.exe' : 'ffprobe');
    console.log(`[ffmpeg] ffprobe: ${fs.existsSync(probe) ? 'ok' : '缺失'}`);
    console.log(`[ffmpeg] 安装完成 → ${path.relative(ROOT, bin)}`);
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
})().catch((e) => {
  console.error('[ffmpeg] 失败：' + e.message);
  process.exit(1);
});