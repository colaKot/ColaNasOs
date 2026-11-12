'use strict';

/**
 * electron-builder 配置（SP4-03 交付收口）。
 *
 * 为什么从 `package.json#build` 搬出来：
 *   - 需要按环境切换「完整包 / 精简包」（本地 AI 模型 292 MB 可选）；
 *   - 交付脚本 `pack.bat` / `dist.bat` 与 `installer.check` 共用同一份配置，避免两处漂移。
 *
 * 模式：
 *   - 默认（`npm run pack` / `npm run dist`）：含 `vendor/models`，AI 人脸/场景可用；
 *   - 精简（`npm run dist:lite`，`COLANAS_LITE=1`）：不含模型，安装体积约减 292 MB，
 *     AI 相关功能需用户自行放置模型到 `resources/models`（AI 设置页可查看模型目录）。
 *
 * 版本真源：`package.json.version`（见 `tool/version.js`）。
 */

const LITE = process.env.COLANAS_LITE === '1';

const extraResources = [
  {
    from: 'contracts',
    to: 'contracts',
    filter: ['locales.json'],
  },
  {
    // 一键下载脚本必须随包：files 里显式排除了 tool/**，而内核用
    // process.resourcesPath/tool/*.js 以 Node 模式拉起它们。
    // 两个都只有十几 KB，精简包也带上（精简包用户同样可以按需补模型）。
    from: 'tool',
    to: 'tool',
    filter: ['tts-model.js', 'mt-model.js'],
  },
  {
    // 内置 transmission-daemon（Windows 官方 MSI 里取出的二进制 + 4 个 DLL）：
    // 内核会拉起它当默认下载器，见 src/modules/pt/daemon.ts
    from: 'vendor/transmission-win',
    to: 'transmission-daemon',
    filter: ['**/*'],
  },
  {
    // 内置 transmission 官方 Web UI（见 vendor/transmission-web/NOTICE.md）：
    // 只托管静态文件 + 内核反代 RPC，不打包 daemon 二进制。
    from: 'vendor/transmission-web',
    to: 'transmission-web',
    filter: ['**/*'],
  },
  {
    // 记忆页 / 地图的省市区与最近地名（开发态读 vendor/geo，安装态读 resources/geo）
    from: 'vendor/geo',
    to: 'geo',
    filter: ['geonames.sqlite', 'china-divisions.json'],
  },
  {
    from: 'apps/colanas_os/build/web',
    to: 'web',
  },
  {
    from: 'sidecars',
    to: 'sidecars',
    filter: ['**/*', '!**/node_modules/**'],
  },
  {
    from: 'resources',
    to: '.',
    filter: ['tray.png', 'tray16.png', 'icon.png', 'icon.ico'],
  },
];

if (!LITE) {
  // 语音模型（Qwen3-TTS，1.4GB）**不进安装包**：
  // 大部分用户不用播客，塞进去等于给所有人加 1.4GB。装机版首次使用会提示
  // 跑 `npm run tts:model`（源码用户）或从文档给的链接下载后放进 models/qwen3-tts。
  extraResources.unshift({
    from: 'vendor/models',
    to: 'models',
    // 下划线开头的目录是本地临时 / 手工测试备份（例如 `_manual-test-backup` 1.1GB），
    // 一旦混进来安装包会从 543MB 涨到 1.6GB；这里整体排除。
    filter: ['**/*', '!kokoro/**', '!qwen3-tts/**', '!mt/**', '!**/_*/**'],
  });
  // 推理二进制随包带上（约 40MB，纯程序不含权重）：用户只需要再下模型
  extraResources.push({
    from: 'vendor/llama',
    to: 'llama',
    filter: ['**/*'],
  });
  // 内置参考音色（3 段 10 秒 wav，约 1.4MB）：不带的话开箱没有可用音色
  extraResources.push({ from: 'vendor/voices', to: 'voices', filter: ['**/*.wav'] });
  // 语音合成的 wav → mp3 用 ffmpeg；装机版没有它就只能落 wav（用户要的是 mp3）
  extraResources.push({ from: 'vendor/ffmpeg', to: 'ffmpeg' });
}

module.exports = {
  appId: 'com.colanas.os',
  // 这个包只是**服务端**（托盘 + 内核 + Web 界面），不含 Flutter 桌面客户端。
  // 客户端安装包由 tool/build-client-installer.js 单独产出，两者产品名刻意不同，
  // 免得用户装完分不清自己装的是哪一个。
  productName: 'ColaNasOs 服务端',
  copyright: 'Copyright © 2026 ColaNasOs',
  directories: {
    output: 'dist_installer',
    buildResources: 'resources',
  },
  // 可执行文件名保持 ASCII：脚本 / 防火墙规则 / 任务管理器里看到的是稳定的 ColaNasOs.exe，
  // 只有安装目录、快捷方式、卸载项带「服务端」。
  executableName: 'ColaNasOs',
  // 不相信 electron-builder 的全量 rebuild：
  //   - node-pty 1.1 是 N-API（node-addon-api），系统 Node 与 Electron ABI 都能加载，
  //     而它的源码编译在本机需要 VS 的 Spectre 缓解库（缺失即 MSB8040，整包失败）；
  //   - better-sqlite3 必须按 Electron ABI 重建，由 `npm run rebuild` 预先完成。
  // 所以这里关掉自动 rebuild，改由 `npm run pack` / `npm run dist` / `dist:lite` 先跑 rebuild。
  npmRebuild: false,
  files: [
    'dist/**/*',
    // `dist/` 里除了编译产物，还经常躺着打好的安装包 / apk / 便携 zip（发布流程会拷一份过去）。
    // 不排除的话它们会被塞进 app.asar —— 实测一次 1.28GB 的安装包（里面套着旧安装包），
    // 体积翻倍且毫无意义。
    '!dist/*.exe',
    '!dist/*.zip',
    '!dist/*.apk',
    '!dist/*.7z',
    '!dist/*.blockmap',
    '!dist/*.log',
    'package.json',
    '!dist/tool/**',
    '!dist/**/*.map',
    '!dist_installer/**/*',
    '!onnx_models/**',
    '!.devdata/**/*',
    '!docs/**',
    '!test/**',
    '!tool/**',
  ],
  extraResources,
  asar: true,
  win: {
    icon: 'resources/icon.ico',
    target: ['nsis'],
    artifactName: LITE
      ? 'ColaNasOs-Server-${version}-${arch}-lite-setup.${ext}'
      : 'ColaNasOs-Server-${version}-Setup.${ext}',
  },
  nsis: {
    oneClick: false,
    allowToChangeInstallationDirectory: true,
    perMachine: false,
    createDesktopShortcut: true,
    createStartMenuShortcut: true,
    shortcutName: 'ColaNasOs 服务端',
    uninstallDisplayName: 'ColaNasOs 服务端 ${version}',
    deleteAppDataOnUninstall: false,
  },
  mac: {
    icon: 'resources/icon.png',
    category: 'public.app-category.utilities',
    target: ['dmg'],
    artifactName: LITE
      ? 'ColaNasOs-Server-${version}-${arch}-lite.${ext}'
      : 'ColaNasOs-Server-${version}.${ext}',
  },
  linux: {
    icon: 'resources/icon.png',
    category: 'Utility',
    target: ['AppImage'],
    artifactName: LITE
      ? 'ColaNasOs-Server-${version}-${arch}-lite.${ext}'
      : 'ColaNasOs-Server-${version}.${ext}',
  },
};