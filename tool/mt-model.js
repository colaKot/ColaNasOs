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
 *
 * 源只有 ModelScope：HuggingFace / hf-mirror 在国内实测都不通（2026-11-06），
 * ModelScope 直连 20MB/s 以上。
 */

const fs = require('node:fs');
const path = require('node:path');
const https = require('node:https');
const http = require('node:http');

const ROOT = path.join(__dirname, '..');
const MODELS = {
  '0.6b': { repo: 'unsloth/Qwen3-0.6B-GGUF', file: 'Qwen3-0.6B-Q4_K_M.gguf', mb: 378 },
  '1.7b': { repo: 'unsloth/Qwen3-1.7B-GGUF', file: 'Qwen3-1.7B-Q4_K_M.gguf', mb: 1056 },
};

function report(line) {
  process.stdout.write(`${line}\n`);
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

/** 带跳转跟随与续传的下载（ModelScope 会 302 到 OSS） */
function download(url, dest) {
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
          return reject(new Error(`HTTP ${code}：${u.slice(0, 120)}`));
        }
        if (code === 200 && start > 0) start = 0;
        const total = Number(res.headers['content-length'] || 0) + start;
        let got = start;
        const ws = fs.createWriteStream(dest, { flags: start > 0 ? 'a' : 'w' });
        let last = 0;
        res.on('data', (chunk) => {
          got += chunk.length;
          const now = Date.now();
          if (now - last > 500 && total > 0) {
            last = now;
            process.stdout.write(
              `\r    ${((got / total) * 100).toFixed(1)}%  ${human(got)} / ${human(total)}`,
            );
          }
        });
        res.pipe(ws);
        ws.on('finish', () => {
          process.stdout.write(`\r${' '.repeat(52)}\r`);
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
  const hit = argv.find((a) => a.startsWith('--to='));
  if (!hit) return path.join(ROOT, 'vendor', 'models', 'mt');
  return path.resolve(hit.slice('--to='.length));
}

function pickModel(argv) {
  const hit = argv.find((a) => a.startsWith('--model='));
  const key = hit ? hit.slice('--model='.length).toLowerCase() : '1.7b';
  const m = MODELS[key];
  if (!m) throw new Error(`不认识的模型档位：${key}（可选 ${Object.keys(MODELS).join(' / ')}）`);
  return m;
}

function check(dir) {
  let found = 0;
  for (const [key, m] of Object.entries(MODELS)) {
    const file = path.join(dir, m.file);
    const ok = fs.existsSync(file) && fs.statSync(file).size > m.mb * 1024 * 1024 * 0.8;
    if (ok) {
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
  const argv = process.argv.slice(2);
  const dir = targetDir(argv);
  if (argv.includes('--check')) return check(dir);
  const m = pickModel(argv);
  const dest = path.join(dir, m.file);
  if (fs.existsSync(dest) && fs.statSync(dest).size > m.mb * 1024 * 1024 * 0.8) {
    report(`[模型] 已存在：${path.relative(ROOT, dest)}（${human(fs.statSync(dest).size)}）`);
    return check(dir);
  }
  const url = `https://modelscope.cn/models/${m.repo}/resolve/master/${m.file}`;
  report(`[模型] 下载 ${m.file}（约 ${m.mb}MB）`);
  await download(url, dest);
  const size = fs.statSync(dest).size;
  const magic = Buffer.alloc(4);
  const fd = fs.openSync(dest, 'r');
  fs.readSync(fd, magic, 0, 4, 0);
  fs.closeSync(fd);
  if (magic.toString('utf8') !== 'GGUF') throw new Error('下载文件不是 GGUF（可能拿到的是错误页）');
  report(`[模型] 完成：${human(size)}`);
  check(dir);
}

main().catch((e) => {
  report(`\n[失败] ${e.message}`);
  process.exit(1);
});
