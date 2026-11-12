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
  check(
    'product_name',
    cfg.productName === 'ColaNasOs 服务端',
    `productName=${cfg.productName}（安装包只是服务端，必须与客户端区分）`,
  );
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
check(
  'files_skip_artifacts',
  ['!dist/*.exe', '!dist/*.zip', '!dist/*.apk'].every((p) => files.includes(p)),
  'dist/ 下的历史安装包 / apk / zip 不能被塞进 app.asar（会把安装包体积翻倍）',
);

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

// 本地语音合成（Qwen3-TTS + llama.cpp）：二进制 + 内置音色 + ffmpeg 随包；
// 1.4GB 权重**不进包**（用户自己下）。少任何一项，装机版就是「点试听没反应」。
const llamaEntry = findEntry(extra, 'llama');
check(
  'tts_llama_bin',
  Boolean(llamaEntry) && llamaEntry.from === 'vendor/llama',
  llamaEntry ? `from=${llamaEntry.from}` : '完整包缺少 llama 二进制（语音合成会不可用）',
);
check(
  'tts_llama_lite',
  !findEntry(liteExtra, 'llama'),
  '精简包不含语音模型，二进制也不必带',
);
check(
  'tts_voices',
  Boolean(findEntry(extra, 'voices')) && findEntry(extra, 'voices').from === 'vendor/voices',
  '完整包缺少内置参考音色（开箱没有可用音色）',
);
check(
  'tts_ffmpeg',
  Boolean(findEntry(extra, 'ffmpeg')) && findEntry(extra, 'ffmpeg').from === 'vendor/ffmpeg',
  '完整包缺少 ffmpeg（wav → mp3 会失败，只能落 wav）',
);
const modelFilter = String((fullModels && fullModels.filter || []).join(','));
check(
  'tts_model_filter',
  !fullModels || modelFilter.includes('!qwen3-tts/**'),
  '1.4GB 的 Qwen3-TTS 权重不应进安装包（应由用户 npm run tts:model 下载）',
);
check(
  'tts_no_python',
  !findEntry(extra, 'python-runtime'),
  '不再需要 python 运行时（旧 Kokoro 方案已移除）',
);
// 一键下载：脚本不在 asar 里（files 排除 tool/**），必须由 extraResources 送到
// resources/tool/tts-model.js，否则装机版点「下载」只会报「找不到下载脚本」。
const toolEntry = findEntry(extra, 'tool');
check(
  'tts_model_script',
  Boolean(toolEntry) &&
    toolEntry.from === 'tool' &&
    (toolEntry.filter || []).includes('tts-model.js'),
  toolEntry ? `from=${toolEntry.from} filter=${(toolEntry.filter || []).join(',')}` : '缺少一键下载脚本',
);
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
// 2026-11-10 起服务端外壳是「纯托盘 + 内核守护」：不再内嵌 BrowserWindow，
// 界面一律交给系统浏览器打开。这里校验的正是这个约定。
check(
  'tray_shell_no_window',
  main.includes('new Tray(') && !main.includes('new BrowserWindow('),
  '服务端应为纯托盘（new Tray）且不创建 BrowserWindow',
);
check(
  'tray_icon_packaged',
  main.includes("'tray16.png'") && main.includes("'tray.png'"),
  '托盘图标应使用与安装包同一套品牌图（tray16.png / tray.png）',
);
check(
  'tray_icon_shipped',
  (cfg.extraResources || []).some(
    (e) => e && e.to === '.' && (e.filter || []).includes('tray16.png'),
  ),
  'extraResources 未把 tray16.png / tray.png 送到安装目录',
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

/**
 * 5.1 产物命名必须标清「服务端 / 客户端」
 *
 * 用户装完分不清装的是哪一个，是实打实踩过的坑（服务端和客户端都叫 ColaNasOs）。
 * 这里把命名钉在门禁上：服务端带 `Server`、PC 客户端带 `Client`、安卓也带 `Client`，
 * 且都落在 `dist_installer/`，找产物只有一个目录。
 */
check(
  'server_artifact_name',
  String((cfg.win || {}).artifactName || '').startsWith('ColaNasOs-Server-'),
  `win.artifactName=${(cfg.win || {}).artifactName}（服务端文件名必须带 Server）`,
);
const clientScript = read('tool/build-client-installer.js');
check(
  'client_artifact_name',
  clientScript.includes("'dist_installer'") &&
    clientScript.includes('ColaNasOs-Client-${version}-Setup.exe'),
  '客户端安装包应输出到 dist_installer/ 且文件名带 Client',
);
check(
  'client_installer_name',
  clientScript.includes("'ColaNasOs 客户端'"),
  '客户端安装包的显示名必须是「ColaNasOs 客户端」',
);
const androidScript = fs.existsSync(path.join(root, 'build-android.bat'))
  ? read('build-android.bat')
  : '';
check(
  'android_artifact_name',
  androidScript.includes('ColaNasOs-Client-%VER%-android-arm64.apk'),
  '安卓包应输出到 dist_installer/ 且文件名带 Client（安卓包是客户端）',
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