#!/usr/bin/env node
/**
 * HTTPS 入口冒烟（用户上传证书方案）。
 *
 * 流程：openssl 生成自签证书 → 写入 <dataDir>/tls → 预写 system.settings
 * （httpsEnabled + httpsPort）→ 真启动内核 → 分别请求 HTTP 与 HTTPS /health。
 *
 * 本机没有 openssl 时跳过（exit 0，打印 skip），避免污染其他平台门禁。
 */
'use strict';

const path = require('node:path');
const fs = require('node:fs');
const os = require('node:os');
const net = require('node:net');
const http = require('node:http');
const https = require('node:https');
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
const { saveTls } = require(path.join(root, 'dist', 'kernel', 'tls'));

process.env.COLANAS_LOG_FILE = '0';
process.chdir(root);

const freePort = () =>
  new Promise((resolve, reject) => {
    const server = net.createServer();
    server.on('error', reject);
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address();
      server.close(() => resolve(port));
    });
  });

const get = (mod, port) =>
  new Promise((resolve, reject) => {
    const req = mod.get(
      { host: '127.0.0.1', port, path: '/health', rejectUnauthorized: false, timeout: 8000 },
      (res) => {
        let body = '';
        res.on('data', (d) => (body += d));
        res.on('end', () => resolve({ status: res.statusCode, body }));
      },
    );
    req.on('error', reject);
    req.on('timeout', () => req.destroy(new Error('timeout')));
  });

(async () => {
  const openssl = spawnSync('openssl', ['version'], { stdio: 'ignore' });
  if (openssl.status !== 0) {
    console.log('[SKIP] 本机没有 openssl，跳过 HTTPS 冒烟');
    process.exit(0);
  }

  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-https-'));
  const certPath = path.join(dataDir, 'cert.pem');
  const keyPath = path.join(dataDir, 'key.pem');
  const gen = spawnSync(
    'openssl',
    [
      'req',
      '-x509',
      '-newkey',
      'rsa:2048',
      '-nodes',
      '-keyout',
      keyPath,
      '-out',
      certPath,
      '-days',
      '1',
      '-subj',
      '/CN=127.0.0.1',
    ],
    { stdio: 'ignore' },
  );
  if (gen.status !== 0) {
    console.log('[SKIP] openssl 生成证书失败，跳过 HTTPS 冒烟');
    process.exit(0);
  }

  const results = [];
  const check = (name, ok, detail) => results.push({ name, ok, detail: detail || '' });

  process.env.COLANAS_DEV_TOKEN = '1';
  process.env.COLANAS_JWT_SECRET = 'test-secret-0123456789abcdef';

  const httpPort = await freePort();
  const httpsPort = await freePort();

  // 证书落到 dataDir/tls（与服务端上传后的落点一致）
  saveTls(dataDir, fs.readFileSync(certPath, 'utf-8'), fs.readFileSync(keyPath, 'utf-8'));

  // 先不监听启动一次，仅为了写 config；再真启动让启动逻辑读配置
  const k0 = await startKernel({ dataDir, port: httpPort, listen: false });
  await k0.config.set('system.settings', {
    httpPort,
    httpsPort,
    httpsEnabled: true,
    hostname: 'tls-test',
  });
  await k0.app.close();

  const k = await startKernel({ dataDir, port: httpPort, listen: true });
  try {
    const httpRes = await get(http, httpPort);
    check('http_entry', httpRes.status === 200, 'status=' + httpRes.status);

    const httpsRes = await get(https, httpsPort);
    let body = {};
    try {
      body = JSON.parse(httpsRes.body || '{}');
    } catch {
      body = {};
    }
    check(
      'https_entry',
      httpsRes.status === 200 && body.hostname === 'tls-test' && body.ok === true,
      `status=${httpsRes.status} hostname=${body.hostname}`,
    );
  } finally {
    await k.app.close();
    try {
      fs.rmSync(dataDir, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
    } catch {
      /* 句柄释放有延迟 */
    }
  }

  let failed = 0;
  for (const x of results) {
    console.log(`${x.ok ? '[OK]  ' : '[FAIL]'} ${x.name.padEnd(20)} ${x.detail}`);
    if (!x.ok) failed++;
  }
  console.log(`[summary] ${results.length - failed}/${results.length} passed`);
  process.exit(failed ? 1 : 0);
})().catch((e) => {
  console.error('[FATAL]', e);
  process.exit(1);
});