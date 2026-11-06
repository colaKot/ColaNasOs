#!/usr/bin/env node
/**
 * 语音合成模型下载器（Qwen3-TTS GGUF + llama-tts）。单平台：Windows NAS。
 *
 * 为什么不做进安装包：talker 1.0GB + mmproj 0.4GB，塞进 NSIS 会让安装包翻倍，
 * 而且大部分用户不用播客。所以模型按需下载，仓库里只留下载脚本和校验。
 *
 *   npm run tts:model          # 下全部（二进制 + 两个 GGUF）
 *   npm run tts:check          # 只体检，不下载
 *   node tool/tts-model.js --json                 # 机器可读进度（NDJSON，给内核用）
 *   node tool/tts-model.js --json --dest=<dir>   # 下到自定义根目录（装机版写用户数据目录）
 *   npm run tts:model -- --bin-only / --models-only
 *
 * 镜像策略（国内直连 GitHub / HuggingFace 都不通，实测）：
 *   - GitHub release：gh-proxy.com > ghproxy.net
 *   - 模型：ModelScope（实测 24MB/s）> hf-mirror.com（约 0.5MB/s）
 * 两个 GGUF 的 sha256 从 ModelScope 的仓库元数据现取，不写死，避免上游换文件后校验假红。
 *
 * --json 时 stdout 只输出 NDJSON（一行一个事件），所有人类文本一律走 stderr：
 *   {"type":"phase","index":1,"total":3,"task":"bin","label":"推理程序"}
 *   {"type":"progress","percent":12.3,"task":"model1","label":"主模型","bytes":...,"totalBytes":...}
 *   {"type":"done","installed":true,"dir":"..."}
 *   {"type":"error","message":"..."}
 */

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const ARGV = process.argv.slice(2);
const JSON_OUT = ARGV.includes('--json');
const DEST_ARG = ARGV.find((a) => a.startsWith('--dest='));
const DEST_ROOT = DEST_ARG ? path.resolve(DEST_ARG.slice(7)) : null;

const ROOT = path.join(__dirname, '..');
const PLATFORM = `${process.platform}-${process.arch}`;

const BIN_TAG = process.env.COLANAS_TTS_BIN_TAG || 'b12138';
const GH_MIRRORS = ['https://gh-proxy.com/', 'https://ghproxy.net/'];

const MODEL_REPO = 'ggml-org/Qwen3-TTS-12Hz-1.7B-Base-GGUF';
const MODEL_FILES = [
  'Qwen3-TTS-12Hz-1.7B-Base-Q4_K_M.gguf',
  'mmproj-Qwen3-TTS-12Hz-1.7B-Base-Q8_0.gguf',
];
const MS_REPO_API = `https://modelscope.cn/api/v1/models/${MODEL_REPO}/repo/files?Revision=master&Root=`;
const MS_RESOLVE = `https://modelscope.cn/models/${MODEL_REPO}/resolve/master/`;
const HF_RESOLVE = `https://hf-mirror.com/${MODEL_REPO}/resolve/main/`;

// 默认落在仓库 vendor/；装机版由内核传 --dest=<dataDir>/tts（可写、升级不丢）。
const BASE = DEST_ROOT || ROOT;
const BIN_DIR = DEST_ROOT
  ? path.join(DEST_ROOT, 'llama', PLATFORM)
  : path.join(ROOT, 'vendor', 'llama', PLATFORM);
const MODEL_DIR = DEST_ROOT
  ? path.join(DEST_ROOT, 'models', 'qwen3-tts')
  : path.join(ROOT, 'vendor', 'models', 'qwen3-tts');
const BIN_NAME = process.platform === 'win32' ? 'llama-tts.exe' : 'llama-tts';

/**
 * 装机版脚本位于 resources/tool/，所以 ROOT = resources。
 * 二进制随包放在 resources/llama/<平台>/，音色放在 resources/voices/；
 * 源码态则分别在 vendor/llama/<平台>/ 与 vendor/voices/。
 * 两处都认，避免装机版为了 36MB 的现成二进制再走一遍 GitHub 镜像。
 */
const BIN_CANDIDATES = [
  path.join(BIN_DIR, BIN_NAME),
  path.join(ROOT, 'llama', PLATFORM, BIN_NAME),
  path.join(ROOT, 'llama', BIN_NAME),
  path.join(ROOT, 'vendor', 'llama', PLATFORM, BIN_NAME),
];
const VOICE_CANDIDATES = [
  path.join(ROOT, 'voices', 'default.wav'),
  path.join(ROOT, 'vendor', 'voices', 'default.wav'),
];
const firstExisting = (list) => list.find((p) => fs.existsSync(p));

/** 三个任务按体积分配进度权重（36MB / 988MB / 426MB ≈ 3 / 67 / 30） */
const TASKS = [
  { id: 'bin', label: '推理程序', weight: 3 },
  { id: 'model1', label: '主模型', weight: 67 },
  { id: 'model2', label: '声码器', weight: 30 },
];

/** llama.cpp 各平台的 Vulkan 包名（本项目只验证 Windows） */
function binAsset() {
  const map = {
    'win32-x64': 'bin-win-vulkan-x64.zip',
    'win32-arm64': 'bin-win-vulkan-arm64.zip',
  };
  const suffix = map[PLATFORM];
  if (!suffix) throw new Error(`一键下载目前只支持 Windows NAS（当前 ${PLATFORM}）`);
  return `llama-${BIN_TAG}-${suffix}`;
}

function human(n) {
  const units = ['B', 'KB', 'MB', 'GB'];
  let v = n;
  let i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i += 1;
  }
  return `${v.toFixed(v >= 100 || i === 0 ? 0 : 1)}${units[i]}`;
}

/** --json 模式：stdout 只走 NDJSON，人类文本一律 stderr，避免污染事件流 */
function report(line) {
  (JSON_OUT ? process.stderr : process.stdout).write(`${line}\n`);
}

function emit(obj) {
  if (JSON_OUT) process.stdout.write(`${JSON.stringify(obj)}\n`);
}

let doneWeight = 0;
function progress(task, got, total) {
  const inner = total > 0 ? Math.min(1, got / total) : 0;
  const percent = Math.min(99.9, Math.round((doneWeight + inner * task.weight) * 10) / 10);
  emit({
    type: 'progress',
    percent,
    task: task.id,
    label: task.label,
    bytes: got,
    totalBytes: total,
  });
}

/** 单文件下载：跟随跳转、断点续传（Range）、进度回调、可选 sha256 校验 */
function download(url, dest, opts = {}) {
  return new Promise((resolve, reject) => {
    const https = require('node:https');
    const http = require('node:http');
    fs.mkdirSync(path.dirname(dest), { recursive: true });

    let start = 0;
    if (!opts.force && fs.existsSync(dest)) start = fs.statSync(dest).size;

    const req = (u, redirects = 0) => {
      const mod = u.startsWith('https') ? https : http;
      const headers = { 'User-Agent': 'ColaNasOs-tts-model/1.0' };
      if (start > 0) headers.Range = `bytes=${start}-`;
      const r = mod.get(u, { headers }, (res) => {
        const code = res.statusCode || 0;
        if (code >= 300 && code < 400 && res.headers.location) {
          res.resume();
          if (redirects > 8) return reject(new Error('跳转次数过多'));
          const next = new URL(res.headers.location, u).toString();
          return req(next, redirects + 1);
        }
        if (code === 416) {
          res.resume();
          return resolve(dest);
        }
        if (code !== 200 && code !== 206) {
          res.resume();
          return reject(new Error(`HTTP ${code}：${u}`));
        }
        if (code === 200 && start > 0) start = 0; // 服务器不支持续传，重头写
        const total = Number(res.headers['content-length'] || 0) + start;
        let got = start;
        const ws = fs.createWriteStream(dest, { flags: start > 0 ? 'a' : 'w' });
        let last = 0;
        res.on('data', (chunk) => {
          got += chunk.length;
          const now = Date.now();
          if (now - last > 250) {
            last = now;
            if (opts.onProgress) opts.onProgress(got, total);
            else if (total > 0 && !JSON_OUT) {
              process.stdout.write(`\r    ${((got / total) * 100).toFixed(1)}%  ${human(got)} / ${human(total)}`);
            }
          }
        });
        res.pipe(ws);
        ws.on('finish', () => {
          if (!opts.onProgress && !JSON_OUT) process.stdout.write(' '.repeat(48) + '\r');
          if (opts.onProgress) opts.onProgress(total, total);
          ws.close(() => resolve(dest));
        });
        ws.on('error', reject);
        res.on('error', reject);
      });
      r.on('error', reject);
      r.setTimeout(120000, () => r.destroy(new Error('连接超时')));
    };
    req(url);
  });
}

function sha256(file) {
  return new Promise((resolve, reject) => {
    const h = crypto.createHash('sha256');
    const s = fs.createReadStream(file);
    s.on('data', (d) => h.update(d));
    s.on('end', () => resolve(h.digest('hex')));
    s.on('error', reject);
  });
}

function unzip(zip, destDir) {
  fs.mkdirSync(destDir, { recursive: true });
  // Windows 10+ 自带 bsdtar，能直接解 zip；失败再退 PowerShell
  let r = spawnSync('tar', ['-xf', zip, '-C', destDir], { stdio: 'pipe' });
  if (r.status === 0) return;
  if (process.platform === 'win32') {
    r = spawnSync(
      'powershell',
      [
        '-NoProfile',
        '-Command',
        `Expand-Archive -LiteralPath '${zip}' -DestinationPath '${destDir}' -Force`,
      ],
      { stdio: 'pipe' },
    );
    if (r.status === 0) return;
  }
  throw new Error(`解压失败：${(r.stderr || '').toString().slice(-300)}`);
}

function phase(task, index) {
  emit({
    type: 'phase',
    index,
    total: TASKS.length,
    task: task.id,
    label: task.label,
  });
}

async function ensureBinary(task, index) {
  const exe = path.join(BIN_DIR, BIN_NAME);
  const existing = firstExisting(BIN_CANDIDATES);
  if (existing) {
    report(`[二进制] 已存在：${existing}`);
    doneWeight += task.weight;
    return true;
  }
  phase(task, index);
  const asset = binAsset();
  const zip = path.join(BASE, '.cache', asset);
  report(`[二进制] 下载 ${asset}`);
  let ok = false;
  for (const mirror of GH_MIRRORS) {
    const url = `${mirror}https://github.com/ggml-org/llama.cpp/releases/download/${BIN_TAG}/${asset}`;
    try {
      await download(url, zip, { force: !fs.existsSync(zip), onProgress: (g, t) => progress(task, g, t) });
      if (fs.existsSync(zip) && fs.statSync(zip).size > 1e6) {
        ok = true;
        break;
      }
    } catch (e) {
      report(`    镜像失败（${mirror.replace('https://', '').replace(/\/$/, '')}）：${e.message}`);
    }
  }
  if (!ok) throw new Error('所有 GitHub 镜像都失败，请检查网络后重试');
  unzip(zip, BIN_DIR);
  fs.rmSync(zip, { force: true });
  if (!fs.existsSync(exe)) throw new Error('解压后没找到 llama-tts，包结构可能变了');
  report(`[二进制] 就绪：${path.relative(BASE, exe)}`);
  doneWeight += task.weight;
  progress(task, 1, 1);
  return true;
}

/** 从 ModelScope 元数据取 sha256（取不到就跳过校验，不让上游故障挡住下载） */
async function modelHashes() {
  try {
    const res = await fetch(MS_REPO_API, { headers: { 'User-Agent': 'ColaNasOs-tts-model/1.0' } });
    const json = await res.json();
    const files = json?.Data?.Files || [];
    const out = {};
    for (const f of files) if (f.Sha256 && f.Path) out[f.Path] = String(f.Sha256).toLowerCase();
    return out;
  } catch {
    return {};
  }
}

async function ensureModels(startIndex) {
  const hashes = await modelHashes();
  for (let i = 0; i < MODEL_FILES.length; i += 1) {
    const name = MODEL_FILES[i];
    const task = TASKS[startIndex + i];
    const dest = path.join(MODEL_DIR, name);
    if (fs.existsSync(dest) && fs.statSync(dest).size > 10 * 1024 * 1024) {
      report(`[模型] 已存在：${name}（${human(fs.statSync(dest).size)}）`);
      doneWeight += task.weight;
      continue;
    }
    phase(task, startIndex + i + 1);
    report(`[模型] 下载 ${name}`);
    let ok = false;
    for (const base of [MS_RESOLVE, HF_RESOLVE]) {
      try {
        await download(base + name, dest, { onProgress: (g, t) => progress(task, g, t) });
        ok = fs.existsSync(dest) && fs.statSync(dest).size > 10 * 1024 * 1024;
        if (ok) break;
      } catch (e) {
        report(`    源失败（${base.split('/')[2]}）：${e.message}`);
      }
    }
    if (!ok) throw new Error(`${name} 下载失败`);
    const want = hashes[name];
    if (want) {
      emit({ type: 'phase', index: startIndex + i + 1, total: TASKS.length, task: task.id, label: `校验 ${task.label}` });
      const got = await sha256(dest);
      if (got !== want) {
        fs.rmSync(dest, { force: true });
        throw new Error(`${name} 校验失败（sha256 不符），已删除损坏文件，请重试`);
      }
      report(`    校验通过（sha256 ${got.slice(0, 12)}…）`);
    }
    doneWeight += task.weight;
    progress(task, 1, 1);
  }
}

function fileState() {
  const rows = [
    ['llama-tts 二进制', firstExisting(BIN_CANDIDATES) || BIN_CANDIDATES[0]],
    ...MODEL_FILES.map((n) => [n, path.join(MODEL_DIR, n)]),
    ['内置音色 default.wav', firstExisting(VOICE_CANDIDATES) || VOICE_CANDIDATES[1]],
  ];
  let miss = 0;
  const detail = [];
  for (const [label, file] of rows) {
    const ok = fs.existsSync(file);
    if (!ok) miss += 1;
    detail.push({ label, path: file, size: ok ? fs.statSync(file).size : 0, ok });
  }
  return { miss, detail };
}

function check() {
  const { miss, detail } = fileState();
  for (const d of detail) {
    report(`${d.ok ? '✓' : '✗'} ${d.label}  ${d.ok ? human(d.size) : '缺失'}`);
  }
  if (miss) {
    report(`\n缺 ${miss} 项，执行 npm run tts:model 补齐。`);
    return false;
  }
  report('\n语音合成就绪。');
  return true;
}

async function main() {
  if (ARGV.includes('--check')) {
    const ok = check();
    if (JSON_OUT) emit({ type: 'done', installed: ok, dir: BASE, checkedOnly: true });
    else if (!ok) process.exitCode = 1;
    return;
  }
  const binOnly = ARGV.includes('--bin-only');
  const modelsOnly = ARGV.includes('--models-only');
  if (!modelsOnly) await ensureBinary(TASKS[0], 1);
  if (!binOnly) await ensureModels(1);

  const { miss, detail } = fileState();
  if (miss) {
    if (JSON_OUT) emit({ type: 'error', message: `下载后仍缺 ${miss} 项`, detail });
    else process.exitCode = 1;
    return;
  }
  if (JSON_OUT) emit({ type: 'done', installed: true, dir: BASE, detail });
  else check();
}

main().catch((e) => {
  report(`\n[失败] ${e.message}`);
  // 不要用 process.exit()：stdout 走管道时是异步的，立刻退出会把 error 事件丢掉
  emit({ type: 'error', message: String(e.message || e) });
  process.exitCode = 1;
});
