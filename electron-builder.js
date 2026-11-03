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
    filter: ['tray.png', 'icon.png', 'icon.ico'],
  },
];

if (!LITE) {
  extraResources.unshift({ from: 'vendor/models', to: 'models' });
}

module.exports = {
  appId: 'com.colanas.os',
  productName: 'ColaNasOs',
  copyright: 'Copyright © 2026 ColaNasOs',
  directories: {
    output: 'dist_installer',
    buildResources: 'resources',
  },
  // 不相信 electron-builder 的全量 rebuild：
  //   - node-pty 1.1 是 N-API（node-addon-api），系统 Node 与 Electron ABI 都能加载，
  //     而它的源码编译在本机需要 VS 的 Spectre 缓解库（缺失即 MSB8040，整包失败）；
  //   - better-sqlite3 必须按 Electron ABI 重建，由 `npm run rebuild` 预先完成。
  // 所以这里关掉自动 rebuild，改由 `npm run pack` / `npm run dist` / `dist:lite` 先跑 rebuild。
  npmRebuild: false,
  files: [
    'dist/**/*',
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
      ? 'ColaNasOs-${version}-${arch}-lite-setup.${ext}'
      : 'ColaNasOs-Setup-${version}.${ext}',
  },
  nsis: {
    oneClick: false,
    allowToChangeInstallationDirectory: true,
    perMachine: false,
    createDesktopShortcut: true,
    createStartMenuShortcut: true,
    shortcutName: 'ColaNasOs',
    uninstallDisplayName: 'ColaNasOs ${version}',
    deleteAppDataOnUninstall: false,
  },
  mac: {
    icon: 'resources/icon.png',
    category: 'public.app-category.utilities',
    target: ['dmg'],
    artifactName: LITE ? 'ColaNasOs-${version}-${arch}-lite.${ext}' : 'ColaNasOs-${version}.${ext}',
  },
  linux: {
    icon: 'resources/icon.png',
    category: 'Utility',
    target: ['AppImage'],
    artifactName: LITE ? 'ColaNasOs-${version}-${arch}-lite.${ext}' : 'ColaNasOs-${version}.${ext}',
  },
};