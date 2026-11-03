#!/usr/bin/env node
/**
 * 安装器验收（SP4-03 的「干净机器」环节，Windows）：
 *
 *   npm run dist            # 先出安装器（或 dist:lite）
 *   npm run smoke:install
 *
 * 流程：
 *   1. 用 NSIS 静默安装到隔离目录 `.devdata/install-smoke/app`（`/S /D=`）
 *   2. 校验安装目录结构（exe / app.asar / web / contracts / 卸载器）
 *   3. 对**安装后的程序**跑一遍 `smoke:packaged` 探针（health / Web 首页 / 未登录 401 / 首启初始化）
 *   4. 升级链路：在同一隔离数据目录（`.devdata/install-smoke/data`）跑 `smoke:updater`
 *      （版本目录 D101→D102 + 指针切换 + 回滚 + 签名），与安装目录串成一条验收
 *   5. 静默卸载并等待安装目录被清理
 *
 * 说明：NSIS 安装会写入 HKCU（开始菜单/桌面快捷方式），卸载会一并清理；
 * 脚本只删除自己指定的隔离目录，不触碰用户已有安装。
 *
 * 用法：node tool/check/install-smoke.js [--installer=<setup.exe>] [--keep]
 *   --keep  卸载后保留安装目录（排查用）
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const root = path.join(__dirname, '..', '..');
const args = Object.fromEntries(
  process.argv
    .slice(2)
    .map((a) => /^--([^=]+)(?:=(.*))?$/.exec(a))
    .filter(Boolean)
    .map((m) => [m[1], m[2] === undefined ? '1' : m[2]]),
);
const keep = args.keep === '1';

const outDir = path.join(root, 'dist_installer');
const workDir = path.join(root, '.devdata', 'install-smoke');
const targetDir = path.join(workDir, 'app');
const dataDir = path.join(workDir, 'data');
const port = Number(args.port || 7800);

const results = [];
const check = (name, ok, detail) => results.push({ name, ok, detail: detail || '' });

function findInstaller() {
  if (args.installer) {
    const p = path.resolve(args.installer);
    return fs.existsSync(p) ? p : null;
  }
  if (!fs.existsSync(outDir)) return null;
  const setups = fs
    .readdirSync(outDir)
    .filter((f) => /setup[-.].*\.exe$/i.test(f) && !/uninstall/i.test(f))
    .sort((a, b) => {
      // 优先完整包（ColaNasOs-Setup-*），其次精简包（*-lite-setup.exe）
      const rank = (n) => (/^ColaNasOs-Setup-/.test(n) ? 0 : 1);
      return (
        rank(a) - rank(b) ||
        fs.statSync(path.join(outDir, b)).mtimeMs - fs.statSync(path.join(outDir, a)).mtimeMs
      );
    });
  return setups.length ? path.join(outDir, setups[0]) : null;
}

const installer = findInstaller();
if (!installer) {
  console.error('[smoke:install] 找不到安装器；先执行 npm run dist（或 dist:lite）');
  process.exit(1);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function waitFor(predicate, timeoutMs, stepMs = 500) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return true;
    await sleep(stepMs);
  }
  return predicate();
}

(async () => {
  console.log(`[smoke:install] 安装器=${path.relative(root, installer)}`);
  fs.rmSync(workDir, { recursive: true, force: true });
  fs.mkdirSync(targetDir, { recursive: true });

  // 1. 静默安装（NSIS：/D 必须是最后一个参数且不带引号）
  const install = spawnSync(installer, ['/S', `/D=${targetDir}`], {
    cwd: path.dirname(installer),
    stdio: 'ignore',
    timeout: 180000,
  });
  const exe = path.join(targetDir, 'ColaNasOs.exe');
  const installed = await waitFor(() => fs.existsSync(exe), 120000);
  check(
    'silent_install',
    install.status === 0 && installed,
    `status=${install.status} exe=${installed}`,
  );
  if (!installed) {
    finish();
    return;
  }

  // 2. 安装目录结构
  const asar = path.join(targetDir, 'resources', 'app.asar');
  const web = path.join(targetDir, 'resources', 'web', 'index.html');
  const locales = path.join(targetDir, 'resources', 'contracts', 'locales.json');
  const models = path.join(targetDir, 'resources', 'models');
  const uninstaller = path.join(targetDir, 'Uninstall ColaNasOs.exe');
  check('installed_asar', fs.existsSync(asar), `resources/app.asar ${fs.existsSync(asar) ? '存在' : '缺失'}`);
  check('installed_web', fs.existsSync(web), `resources/web/index.html ${fs.existsSync(web) ? '存在' : '缺失'}`);
  check(
    'installed_contracts',
    fs.existsSync(locales),
    `resources/contracts/locales.json ${fs.existsSync(locales) ? '存在' : '缺失'}`,
  );
  check(
    'installed_uninstaller',
    fs.existsSync(uninstaller),
    `Uninstall ColaNasOs.exe ${fs.existsSync(uninstaller) ? '存在' : '缺失'}`,
  );
  console.log(`[info]   installed_models      ${fs.existsSync(models) ? '存在（完整包）' : '缺失（精简包）'}`);

  // 3. 对安装后的程序跑运行探针（复用 packaged-runtime，独立端口 + 同区数据目录）
  const probe = spawnSync(
    process.execPath,
    [
      path.join(root, 'tool', 'check', 'packaged-runtime.js'),
      `--bin=${exe}`,
      `--port=${port}`,
      `--data=${dataDir}`,
    ],
    { cwd: root, stdio: 'inherit', timeout: 180000 },
  );
  check('runtime_probe', probe.status === 0, `packaged-runtime exit=${probe.status}`);

  // 3.5 升级链路：在同一个隔离数据目录下落版本目录（D101 → D102），
  //     与安装目录一起构成「安装 → 升级 → 回滚」可复现链路。
  const upgrade = spawnSync(
    process.execPath,
    [path.join(root, 'tool', 'check', 'updater-smoke.js'), `--root=${dataDir}`],
    { cwd: root, stdio: 'inherit', timeout: 120000 },
  );
  check('upgrade_smoke', upgrade.status === 0, `updater-smoke exit=${upgrade.status}`);

  const versionsDir = path.join(dataDir, 'versions');
  let currentId;
  try {
    currentId = JSON.parse(fs.readFileSync(path.join(versionsDir, 'current.json'), 'utf8')).id;
  } catch {
    currentId = null;
  }
  check(
    'upgrade_versions_layout',
    fs.existsSync(path.join(versionsDir, 'D101')) && fs.existsSync(path.join(versionsDir, 'D102')),
    'versions/D101 + D102',
  );
  check('upgrade_current_pointer', currentId === 'D102', 'current=' + currentId);
  check(
    'upgrade_manifest_signed',
    fs.existsSync(path.join(versionsDir, 'D102', 'manifest.json')),
    'versions/D102/manifest.json',
  );

  // 4. 静默卸载
  const un = spawnSync(uninstaller, ['/S'], {
    cwd: path.dirname(uninstaller),
    stdio: 'ignore',
    timeout: 120000,
  });
  const removed = await waitFor(() => !fs.existsSync(exe), 90000);
  check('silent_uninstall', un.status === 0 && removed, `status=${un.status} removed=${removed}`);
  if (!keep) fs.rmSync(workDir, { recursive: true, force: true });

  finish();
})();

function finish() {
  for (const r of results) console.log(`${r.ok ? '[OK]  ' : '[FAIL]'} ${r.name.padEnd(20)} ${r.detail}`);
  const failed = results.filter((r) => !r.ok);
  console.log(`\n[smoke:install] ${results.length - failed.length}/${results.length} passed`);
  if (failed.length) {
    console.error('[smoke:install] 若安装目录残留，请手动检查：' + path.relative(root, workDir));
  }
  process.exit(failed.length ? 1 : 0);
}