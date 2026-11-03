#!/usr/bin/env node
/**
 * SP4 更新器验收（SP4-01/02/03）：
 *  1. 版本目录落位 + 指针切换
 *  2. 默认禁止降级，--force-downgrade 可放行
 *  3. 回滚切回上一目录
 *  4. ed25519 签名 + sha256 校验；文件被篡改即失败
 *  5. 数据初始化幂等，清理遗留 pid
 *
 * 纯 Node 运行（不依赖 Electron ABI）。
 * 用法：node tool/check/updater-smoke.js [--root=<dir>]
 *   --root  指定版本目录的根（默认临时目录）；安装验收用它把版本目录落到
 *           安装隔离区，与「安装目录」串成同一条链路。
 */
'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');

const root = path.join(__dirname, '..', '..');
const args = Object.fromEntries(
  process.argv
    .slice(2)
    .map((a) => /^--([^=]+)(?:=(.*))?$/.exec(a))
    .filter(Boolean)
    .map((m) => [m[1], m[2] === undefined ? '1' : m[2]]),
);
const { Updater, UpdaterError, signManifest, initDataDir, versionId } = require(path.join(
  root,
  'dist',
  'kernel',
  'updater.js',
));

const results = [];
const check = (name, ok, detail) => results.push({ name, ok, detail: detail || '' });

function makeBuild(dir, content) {
  fs.mkdirSync(path.join(dir, 'resources'), { recursive: true });
  fs.writeFileSync(path.join(dir, 'app.txt'), content, 'utf8');
  fs.writeFileSync(path.join(dir, 'resources', 'model.bin'), crypto.randomBytes(64));
  return dir;
}

function signInto(entry, privatePem) {
  const manifest = signManifest(entry.version, entry.dir, privatePem);
  fs.writeFileSync(path.join(entry.dir, 'manifest.json'), JSON.stringify(manifest, null, 2), 'utf8');
  return manifest;
}

(async () => {
  const work = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-updater-'));
  const rootDir = args.root ? path.resolve(args.root) : path.join(work, 'install');
  console.log(`[updater] versions-root=${rootDir}`);
  const { privateKey, publicKey } = crypto.generateKeyPairSync('ed25519');
  const priv = privateKey.export({ type: 'pkcs8', format: 'pem' }).toString();
  const pub = publicKey.export({ type: 'spki', format: 'pem' }).toString();
  const privPath = path.join(work, 'deploy.pem');
  fs.writeFileSync(privPath, priv, 'utf8');

  const up = new Updater(rootDir);

  const b1 = makeBuild(path.join(work, 'build-101'), 'v101');
  const b2 = makeBuild(path.join(work, 'build-102'), 'v102');

  const e1 = up.install(b1, 101);
  signInto(e1, priv);
  const e2 = up.install(b2, 102);
  signInto(e2, priv);

  check('install_layout', e1.id === 'D101' && fs.existsSync(e1.dir) && up.list().length === 2, up.list().map((v) => v.id).join(','));

  let dup = null;
  try {
    up.install(b1, 101);
  } catch (err) {
    dup = err.code;
  }
  check('no_overwrite', dup === 'E_EXISTS', 'code=' + dup);

  const a1 = up.activate(101);
  const c1 = up.current();
  const a2 = up.activate(102);
  const c2 = up.current();
  check(
    'activate_monotonic',
    a1.id === 'D101' && c1.version === 101 && a2.id === 'D102' && c2.version === 102,
    `${c1 && c1.id} -> ${c2 && c2.id}`,
  );

  let down = null;
  try {
    up.activate(101);
  } catch (err) {
    down = err.code;
  }
  check('downgrade_blocked', down === 'E_DOWNGRADE', 'code=' + down);

  const forced = up.activate(101, { forceDowngrade: true });
  check('force_downgrade', forced.version === 101 && up.current().version === 101, 'current=' + up.current().id);

  const back = up.rollback();
  check('rollback', back.version === 102 && up.current().version === 102, 'current=' + up.current().id);

  const verifier = new Updater(rootDir, pub);
  const okVerify = verifier.verify(verifier.list().find((v) => v.version === 102));
  check('signature_ok', okVerify.ok, okVerify.errors.join('; '));

  fs.writeFileSync(path.join(up.versionsDir, versionId(102), 'app.txt'), 'tampered', 'utf8');
  const badVerify = verifier.verify(verifier.list().find((v) => v.version === 102));
  let tamperCode = null;
  try {
    verifier.activate(102);
  } catch (err) {
    tamperCode = err.code;
  }
  check(
    'tamper_detected',
    !badVerify.ok && tamperCode === 'E_SIGNATURE',
    (badVerify.errors[0] || '') + ' / code=' + tamperCode,
  );

  // 数据初始化
  const dataDir = path.join(work, 'data');
  fs.mkdirSync(dataDir, { recursive: true });
  fs.writeFileSync(path.join(dataDir, 'kernel.pid'), '12345', 'utf8');
  const first = initDataDir(dataDir);
  const second = initDataDir(dataDir);
  check(
    'data_init_idempotent',
    first.created.includes('config.json') &&
      second.created.length === 0 &&
      fs.existsSync(path.join(dataDir, 'logs')) &&
      !fs.existsSync(path.join(dataDir, 'kernel.pid')),
    `first=${first.created.join(',')} second=${second.created.length}`,
  );

  // 版本目录名补零
  check('version_padding', versionId(7) === 'D007' && versionId(104) === 'D104', versionId(104));

  fs.rmSync(work, { recursive: true, force: true });

  let failed = 0;
  for (const x of results) {
    console.log(`${x.ok ? '[OK]  ' : '[FAIL]'} ${x.name.padEnd(22)} ${x.detail}`);
    if (!x.ok) failed++;
  }
  console.log(`[summary] ${results.length - failed}/${results.length} passed`);
  process.exit(failed ? 1 : 0);
})().catch((e) => {
  console.error('[FATAL]', e);
  if (e instanceof UpdaterError) console.error('code=', e.code);
  process.exit(1);
});