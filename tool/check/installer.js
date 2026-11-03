#!/usr/bin/env node
/**
 * 安装器门禁（SP4-03 交付收口）：
 *   1. `electron-builder.js` 关键字段正确（appId / productName / 输出目录）
 *   2. `files` 覆盖 tsc 产物与 package.json，`extraResources` 把 Web / 契约 / 模型映射到位
 *   3. 完整包含 `vendor/models`；精简包（COLANAS_LITE=1）不含且产物名带 `-lite`
 *   4. 主进程在打包形态注入 COLANAS_WEB_DIR / COLANAS_CONTRACTS_DIR；内核启动做数据初始化
 *   5. `package.json` 提供 pack / dist / dist:lite / smoke:packaged 脚本，版本单一真源已接通
 *   6. 已产出的安装器做结构校验（无产物只提示，不算失败）
 *
 * 用法：node tool/check/installer.js
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..', '..');
const read = (p) => fs.readFileSync(path.join(root, p), 'utf-8');
const results = [];
const check = (name, ok, detail) => results.push({ name, ok, detail: detail || '' });

const configPath = path.join(root, 'electron-builder.js');

/** 按 LITE 模式加载同一份配置（清 require 缓存，让环境变量重新参与计算）。 */
function loadConfig(lite) {
  const prev = process.env.COLANAS_LITE;
  if (lite) process.env.COLANAS_LITE = '1';
  else delete process.env.COLANAS_LITE;
  delete require.cache[require.resolve(configPath)];
  const cfg = require(configPath);
  if (prev === undefined) delete process.env.COLANAS_LITE;
  else process.env.COLANAS_LITE = prev;
  return cfg;
}

/** 1. 配置 */
let cfg = {};
let liteCfg = {};
try {
  cfg = loadConfig(false);
  liteCfg = loadConfig(true);
} catch (err) {
  check('config', false, `electron-builder.js 加载失败：${err.message}`);
}
if (cfg.appId) {
  check('app_id', cfg.appId === 'com.colanas.os', `appId=${cfg.appId}`);
  check('product_name', cfg.productName === 'ColaNasOs', `productName=${cfg.productName}`);
  check(
    'output_dir',
    (cfg.directories || {}).output === 'dist_installer',
    `output=${(cfg.directories || {}).output}`,
  );
} else {
  check('config', false, 'electron-builder.js 缺少 appId');
}

/** 2. files / extraResources */
const files = cfg.files || [];
check(
  'files_cover',
  files.includes('dist/**/*') && files.includes('package.json'),
  files.join(','),
);
check('files_skip_maps', files.includes('!dist/**/*.map'), '源码映射不应进安装包');

const extra = cfg.extraResources || [];
const findEntry = (list, to) => (list || []).find((e) => e && e.to === to);
const webEntry = findEntry(extra, 'web');
check(
  'web_assets',
  Boolean(webEntry) && webEntry.from === 'apps/colanas_os/build/web',
  webEntry ? `from=${webEntry.from} to=${webEntry.to}` : '缺少 Web 产物 extraResources',
);
const contractEntry = findEntry(extra, 'contracts');
check(
  'contracts_assets',
  Boolean(contractEntry) && contractEntry.from === 'contracts',
  contractEntry ? `from=${contractEntry.from} to=${contractEntry.to}` : '缺少 contracts extraResources',
);

/** 3. 完整包 / 精简包 */
const fullModels = findEntry(extra, 'models');
check(
  'models_full',
  Boolean(fullModels) && fullModels.from === 'vendor/models',
  fullModels ? `完整包含 ${fullModels.from}` : '完整包缺少 models',
);
const liteExtra = liteCfg.extraResources || [];
check('models_lite', !findEntry(liteExtra, 'models'), '精简包不应包含 models');
check(
  'lite_artifact_name',
  String((liteCfg.win || {}).artifactName || '').includes('-lite-'),
  `lite artifactName=${(liteCfg.win || {}).artifactName}`,
);
check(
  'lite_web_assets',
  Boolean(findEntry(liteExtra, 'web')) && Boolean(findEntry(liteExtra, 'contracts')),
  '精简包也必须带 Web 与契约',
);

/** 4. 运行时接线 */
const main = read('electron/main.ts');
check(
  'web_dir_env',
  main.includes('COLANAS_WEB_DIR') && main.includes('app.isPackaged'),
  '主进程未在打包形态设置 COLANAS_WEB_DIR',
);
check(
  'window_load_packaged',
  main.includes("path.join(process.resourcesPath, 'web', 'index.html')"),
  '窗口在打包形态没有指向 resources/web（会退回 /health）',
);
check(
  'contracts_dir_env',
  main.includes('COLANAS_CONTRACTS_DIR') && main.includes("'contracts'"),
  '主进程未在打包形态设置 COLANAS_CONTRACTS_DIR（内核会读不到 locales.json）',
);
const host = read('electron/kernel-host.ts');
check(
  'data_init',
  host.includes('initDataDir('),
  '内核启动未执行 initDataDir（数据目录初始化）',
);

/** 5. 脚本与版本 */
const pkg = JSON.parse(read('package.json'));
const scripts = pkg.scripts || {};
check(
  'npm_scripts',
  Boolean(scripts.pack) &&
    Boolean(scripts.dist) &&
    Boolean(scripts['dist:lite']) &&
    Boolean(scripts['smoke:packaged']),
  `pack=${Boolean(scripts.pack)} dist=${Boolean(scripts.dist)} lite=${Boolean(scripts['dist:lite'])}`,
);
check(
  'config_not_in_package',
  !pkg.build,
  'package.json#build 与 electron-builder.js 只能留一份',
);
check(
  'version_scripts',
  Boolean(scripts['version:sync']) && Boolean(scripts['version:check']),
  `version:check=${Boolean(scripts['version:check'])}`,
);

/** 6. 产物（可选） */
const outDir = path.join(root, 'dist_installer');
const unpacked = path.join(outDir, 'win-unpacked', 'ColaNasOs.exe');
const installers = fs.existsSync(outDir)
  ? fs.readdirSync(outDir).filter((f) => /setup\.exe$|\.dmg$|\.AppImage$|\.deb$/.test(f))
  : [];
if (fs.existsSync(unpacked)) {
  const resWeb = path.join(outDir, 'win-unpacked', 'resources', 'web', 'index.html');
  const resLocales = path.join(outDir, 'win-unpacked', 'resources', 'contracts', 'locales.json');
  const resModels = path.join(outDir, 'win-unpacked', 'resources', 'models');
  const asar = path.join(outDir, 'win-unpacked', 'resources', 'app.asar');
  check('unpacked_web', fs.existsSync(resWeb), `resources/web/index.html ${fs.existsSync(resWeb) ? '存在' : '缺失'}`);
  check(
    'unpacked_contracts',
    fs.existsSync(resLocales),
    `resources/contracts/locales.json ${fs.existsSync(resLocales) ? '存在' : '缺失（内核启动会 ENOENT）'}`,
  );
  check('unpacked_asar', fs.existsSync(asar), `app.asar ${fs.existsSync(asar) ? '存在' : '缺失'}`);
  console.log(`[info]   unpacked_models     ${fs.existsSync(resModels) ? '存在（完整包）' : '缺失（精简包）'}`);
}
if (installers.length) {
  const sizes = installers.map(
    (f) => `${f}=${(fs.statSync(path.join(outDir, f)).size / 1048576).toFixed(1)}MB`,
  );
  check('installer_artifact', true, sizes.join(', '));
} else {
  console.log('[info]   installer_artifact   尚未产出（npm run dist / dist:lite 生成）');
}

for (const r of results) console.log(`${r.ok ? '[OK]  ' : '[FAIL]'} ${r.name.padEnd(20)} ${r.detail}`);
const failed = results.filter((r) => !r.ok);
console.log(`\n[installer] ${results.length - failed.length}/${results.length} passed`);
process.exit(failed.length ? 1 : 0);