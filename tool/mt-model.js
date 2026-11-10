#!/usr/bin/env node
/**
 * 本地翻译模型下载器（Qwen3 GGUF，给 AI 新闻做英转中）。
 *
 * 为什么不进安装包：Q4_K_M 约 1.0GB，塞进 NSIS 会让安装包翻倍，而它只服务于
 * 「AI 新闻」这一个功能。所以按需下载，仓库里只留脚本（`electron-builder.js`
 * 里用 `!mt/**` 把它排除）。
 *
 *   npm run mt:model                 # 下 1.7B Q4_K_M（默认，质量可用）
 *   npm run mt:model -- --model=0.6b # 下 0.6B（378MB，速度快但专名常错）
 *   npm run mt:model -- --check      # 只体检
 *   npm run mt:model -- --to=D:\models\mt
 *   node tool/mt-model.js --json --dest=<dir>    # 内核用：NDJSON 事件流
 *
 * 多源自动适配（国内优先，失败逐个换）：
 *   ModelScope（国内直连 20MB/s）→ hf-mirror.com（国内可用镜像）→ huggingface.co
 * 三个都失败才报错，由内核转成界面提示。
 */

const fs = require('node:fs');
const path = require('node:path');
const https = require('node:https');
const http = require('node:http');

const ROOT = path.join(__dirname, '..');
const ARGV = process.argv.slice(2);
const JSON_OUT = ARGV.includes('--json');
const MODELS = {
  '0.6b': { repo: 'unsloth/Qwen3-0.6B-GGUF', file: 'Qwen3-0.6B-Q4_K_M.gguf', mb: 378 },
  '1.7b': { repo: 'unsloth/Qwen3-1.7B-GGUF', file: 'Qwen3-1.7B-Q4_K_M.gguf', mb: 1056 },
};

/** 逐个尝试，前一个失败自动换下一个；顺序按国内可达性排 */
const SOURCES = [
  {
    id: 'modelscope',
    label: 'ModelScope',
    url: (m) => `https://modelscope.cn/models/${m.repo}/resolve/master/${m.file}`,
  },
  {
    id: 'hf-mirror',
    label: 'HF 镜像',
    url: (m) => `https://hf-mirror.com/${m.repo}/resolve/main/${m.file}`,
  },
  {
    id: 'huggingface',
    label: 'HuggingFace',
    url: (m) => `https://huggingface.co/${m.repo}/resolve/main/${m.file}`,
  },
];

/** --json 时 stdout 只走 NDJSON，人类文本一律 stderr，避免污染事件流 */
function report(line) {
  (JSON_OUT ? process.stderr : process.stdout).write(`${line}\n`);
}

function emit(obj) {
  if (JSON_OUT) process.stdout.write(`${JSON.stringify(obj)}\n`);
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

/** 带跳转跟随、断点续传与进度回调的下载（ModelScope 会 302 到 OSS） */
function download(url, dest, onProgress) {
  return new Promise((resolve, reject) => {
    fs.mkdirSync(path.dirname(dest), { recursive: true });
    let start = fs.existsSync(dest) ? fs.statSync(dest).size : 0;

    const req = (u, redirects = 0) => {
      const mod = u.startsWith('https') ? https : http;
      const headers = { 'User-Agent': 'ColaNasOs-mt-model/1.0' };
      if (start > 0) headers.Range = `bytes=${start}-`;
      const r = mod.get(u, { headers }, (res) => {
        const code = res.statusCode || 0;
        if (code >= 300 && code < 400 && res.headers.location) {
          res.resume();
          if (redirects > 8) return reject(new Error('跳转次数过多'));
          return req(new URL(res.headers.location, u).toString(), redirects + 1);
        }
        if (code === 416) {
          res.resume();
          return resolve(dest);
        }
        if (code !== 200 && code !== 206) {
          res.resume();
          return reject(new Error(`HTTP ${code}`));
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
            if (onProgress) onProgress(got, total);
            else if (total > 0) {
              process.stdout.write(
                `\r    ${((got / total) * 100).toFixed(1)}%  ${human(got)} / ${human(total)}`,
              );
            }
          }
        });
        res.pipe(ws);
        ws.on('finish', () => {
          if (!onProgress) process.stdout.write(`${' '.repeat(52)}\r`);
          if (onProgress) onProgress(total || got, total || got);
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

function targetDir(argv) {
  const hit = argv.find((a) => a.startsWith('--to=') || a.startsWith('--dest='));
  if (!hit) return path.join(ROOT, 'vendor', 'models', 'mt');
  return path.resolve(hit.slice(hit.indexOf('=') + 1));
}

function pickModel(argv) {
  const hit = argv.find((a) => a.startsWith('--model='));
  const key = hit ? hit.slice('--model='.length).toLowerCase() : '1.7b';
  const m = MODELS[key];
  if (!m) throw new Error(`不认识的模型档位：${key}（可选 ${Object.keys(MODELS).join(' / ')}）`);
  return m;
}

/** 完整 GGUF：大小达到标称的 80% 且文件头是 GGUF（防错误页/半截文件） */
function isGguf(file, mb) {
  try {
    if (!fs.existsSync(file)) return false;
    if (fs.statSync(file).size < mb * 1024 * 1024 * 0.8) return false;
    const magic = Buffer.alloc(4);
    const fd = fs.openSync(file, 'r');
    fs.readSync(fd, magic, 0, 4, 0);
    fs.closeSync(fd);
    return magic.toString('utf8') === 'GGUF';
  } catch {
    return false;
  }
}

function check(dir) {
  let found = 0;
  for (const [key, m] of Object.entries(MODELS)) {
    const file = path.join(dir, m.file);
    if (isGguf(file, m.mb)) {
      found += 1;
      report(`✓ ${key}  ${m.file}  ${human(fs.statSync(file).size)}`);
    } else {
      report(`- ${key}  未下载（可选档位）`);
    }
  }
  if (!found) {
    report('\n一个模型都没有，执行 npm run mt:model');
    process.exitCode = 1;
  } else {
    report('\n本地翻译模型就绪（llama-server 用 vendor/llama 里那份）。');
  }
}

async function main() {
  const dir = targetDir(ARGV);
  const m = pickModel(ARGV);
  const dest = path.join(dir, m.file);

  if (ARGV.includes('--check')) {
    check(dir);
    emit({ type: 'done', installed: isGguf(dest, m.mb), dir, file: dest });
    return;
  }
  if (isGguf(dest, m.mb)) {
    report(`[模型] 已存在：${dest}`);
    emit({ type: 'done', installed: true, dir, file: dest, reused: true });
    return;
  }

  emit({ type: 'phase', index: 1, total: 1, task: 'model', label: '翻译模型' });
  report(`[模型] 下载 ${m.file}（约 ${m.mb}MB）`);

  let lastErr = null;
  for (const src of SOURCES) {
    try {
      report(`[模型] 尝试 ${src.label}`);
      await download(src.url(m), dest, (got, total) => {
        const percent = total > 0 ? Math.min(99.9, (got / total) * 100) : 0;
        emit({
          type: 'progress',
          percent: Math.round(percent * 10) / 10,
          task: 'model',
          label: '翻译模型',
          bytes: got,
          totalBytes: total,
          source: src.id,
        });
      });
      if (!isGguf(dest, m.mb)) throw new Error('下载文件不是完整 GGUF（可能拿到错误页）');
      report(`[模型] 完成：${human(fs.statSync(dest).size)}（来自 ${src.label}）`);
      emit({ type: 'done', installed: true, dir, file: dest, source: src.id });
      check(dir);
      return;
    } catch (e) {
      lastErr = e;
      report(`    ${src.label} 失败：${e.message}`);
      // 只清理「明显是错误页」的碎片；正常半截文件留给下一个源续传
      try {
        if (fs.existsSync(dest) && fs.statSync(dest).size < 1024 * 1024) fs.rmSync(dest, { force: true });
      } catch {
        // 删不掉就算了，下一个源会从头覆盖
      }
      emit({
        type: 'phase',
        index: 1,
        total: 1,
        task: 'model',
        label: `切换下载源（${src.label} 不可用）`,
      });
    }
  }
  throw new Error(`所有下载源都失败：${lastErr ? lastErr.message : '未知错误'}`);
}

main().catch((e) => {
  report(`\n[失败] ${e.message}`);
  emit({ type: 'error', message: e.message });
  process.exit(1);
});
