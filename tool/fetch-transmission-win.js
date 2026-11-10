'use strict';

/**
 * 取出官方 transmission-daemon（Windows）。
 *
 * 为什么要脚本：二进制不进 git（10MB），但打包和开发都需要它在 `vendor/transmission-win/`。
 * 来源是 **Transmission 官方 MSI**（GitHub Releases），用 msiexec 的管理安装（/a）展开，
 * 只留 daemon + 它实际依赖的 4 个 DLL（Qt 那堆是 GUI 用的，daemon 不需要）。
 *
 * 用法：node tool/fetch-transmission-win.js [版本]
 *   TRANSMISSION_VERSION=4.1.4（默认）
 *   TRANSMISSION_MSI=<本地 msi 路径>（离线时用）
 */
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const https = require('node:https');

const VERSION = process.argv[2] || process.env.TRANSMISSION_VERSION || '4.1.4';
const OUT = path.resolve(__dirname, '..', 'vendor', 'transmission-win');
const KEEP = [
  'transmission-daemon.exe',
  'libcurl.dll',
  'libssl-3-x64.dll',
  'libcrypto-3-x64.dll',
  'z.dll',
];

function download(url, dest) {
  return new Promise((resolve, reject) => {
    const file = fs.createWriteStream(dest);
    const get = (u, redirects = 0) => {
      https
        .get(u, { headers: { 'user-agent': 'ColaNasOs-fetch' } }, (res) => {
          if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location && redirects < 5) {
            res.resume();
            return get(res.headers.location, redirects + 1);
          }
          if (res.statusCode !== 200) {
            res.resume();
            return reject(new Error(`HTTP ${res.statusCode} for ${u}`));
          }
          res.pipe(file);
          file.on('finish', () => file.close(() => resolve(dest)));
        })
        .on('error', reject);
    };
    get(url);
  });
}

(async () => {
  if (process.platform !== 'win32') {
    console.error('[transmission] 本项目只支持 Windows NAS，请在 Windows 上运行。');
    process.exit(1);
  }
  if (fs.existsSync(path.join(OUT, 'transmission-daemon.exe')) && !process.env.FORCE) {
    console.log(`[transmission] 已存在：${OUT}（要重下加 FORCE=1）`);
    return;
  }

  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'nas-td-'));
  const msi = process.env.TRANSMISSION_MSI || path.join(tmp, 'transmission.msi');
  if (!process.env.TRANSMISSION_MSI) {
    const url = `https://github.com/transmission/transmission/releases/download/${VERSION}/transmission-${VERSION}-x64.msi`;
    console.log(`[transmission] 下载 ${url}`);
    await download(url, msi);
  }

  const admin = path.join(tmp, 'admin');
  console.log('[transmission] 展开 MSI（msiexec /a）…');
  execFileSync('msiexec.exe', ['/a', msi, '/qn', `TARGETDIR=${admin}`], { stdio: 'inherit' });

  const src = path.join(admin, 'PFiles', 'Transmission');
  if (!fs.existsSync(src)) throw new Error(`MSI 里没找到 ${src}`);

  fs.mkdirSync(OUT, { recursive: true });
  for (const name of KEEP) {
    const from = path.join(src, name);
    if (!fs.existsSync(from)) throw new Error(`缺少文件：${name}`);
    fs.copyFileSync(from, path.join(OUT, name));
  }
  fs.writeFileSync(
    path.join(OUT, 'VERSION'),
    `Transmission ${VERSION}\n来源：https://github.com/transmission/transmission/releases/tag/${VERSION}\n文件：${KEEP.join(', ')}\n许可证：GPL-3.0（与 ColaNasOs 相同）\n`,
    'utf8',
  );
  fs.rmSync(tmp, { recursive: true, force: true });
  console.log(`[transmission] 完成 → ${OUT}`);
})().catch((err) => {
  console.error('[transmission] 失败：', err.message);
  process.exit(1);
});
