#!/usr/bin/env node
/**
 * 打 **PC 客户端** 安装包（Flutter Windows 桌面端）。
 *
 * 和服务端安装包的分工：
 *   - 服务端：`npm run dist` → electron-builder → `dist_installer/ColaNasOs-Server-<ver>-Setup.exe`
 *     （托盘 + 内核 + Web 界面 + 模型，装完就能用浏览器访问 7788）；
 *   - 客户端：本脚本 → NSIS → `dist_installer/ColaNasOs-Client-<ver>-Setup.exe`
 *     （Flutter 桌面端，启动后自己发现 / 连服务端，不依赖服务端装在同一个目录）。
 *
 * 两个产物**放同一个目录** `dist_installer/`，文件名分别带 `Server` / `Client`：
 * 交付时用户一眼能分清装的是哪一个（以前客户端落在 `dist/`，看着像没打安装包）。
 *
 * 两个包彼此独立：客户端可以只装在另一台电脑上连局域网里的服务端，
 * 所以这里不合并、也不要求同目录。
 *
 * 用法：
 *   node tool/build-client-installer.js            # 先 flutter build windows --release，再打包
 *   node tool/build-client-installer.js --skip-build
 *   node tool/build-client-installer.js --no-zip   # 只要安装包，不要便携 zip
 *
 * 说明：NSIS 编译器复用 electron-builder 缓存里的那份（`%LOCALAPPDATA%\electron-builder\Cache\nsis-*`），
 * 不额外引入构建依赖；找不到时只产出便携 zip 并给出提示。
 */
'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const root = path.join(__dirname, '..');
const appDir = path.join(root, 'apps', 'colanas_os');
const releaseDir = path.join(appDir, 'build', 'windows', 'x64', 'runner', 'Release');
const distDir = path.join(root, 'dist_installer');
const version = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf-8')).version;
const appName = 'ColaNasOs 客户端';
const exeName = 'colanas_os.exe';

const args = process.argv.slice(2);
const skipBuild = args.includes('--skip-build');
const noZip = args.includes('--no-zip');

function buildFlutter() {
  console.log('[client-installer] flutter build windows --release ...');
  const r = spawnSync('flutter', ['build', 'windows', '--release'], {
    cwd: appDir,
    stdio: 'inherit',
    shell: true,
  });
  if (r.status !== 0) {
    console.error('[client-installer] Flutter 构建失败');
    process.exit(r.status ?? 1);
  }
}

/** 找 NSIS：优先环境变量，其次 electron-builder 缓存，最后 PATH */
function findMakensis() {
  const fromEnv = process.env.MAKENSIS;
  if (fromEnv && fs.existsSync(fromEnv)) return fromEnv;

  const caches = [
    process.env.LOCALAPPDATA && path.join(process.env.LOCALAPPDATA, 'electron-builder', 'Cache'),
    path.join(os.homedir(), '.cache', 'electron-builder'),
  ].filter(Boolean);

  const search = (dir, depth) => {
    if (depth > 4 || !fs.existsSync(dir)) return null;
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const abs = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        const hit = search(abs, depth + 1);
        if (hit) return hit;
      } else if (/^makensis(\.exe)?$/i.test(entry.name)) {
        return abs;
      }
    }
    return null;
  };
  for (const cache of caches) {
    const hit = search(cache, 0);
    if (hit) return hit;
  }

  const probe = spawnSync(process.platform === 'win32' ? 'where' : 'which', ['makensis'], {
    encoding: 'utf-8',
  });
  const line = (probe.stdout || '').split('\n')[0].trim();
  return line || null;
}

function writeZip() {
  // archiver v8 去掉了默认导出函数，改成具名类
  const { ZipArchive } = require('archiver');
  const outPath = path.join(distDir, `ColaNasOs-Client-${version}-windows-x64.zip`);
  return new Promise((resolve, reject) => {
    const output = fs.createWriteStream(outPath);
    const zip = new ZipArchive({ zlib: { level: 9 } });
    output.on('close', () => resolve(outPath));
    zip.on('error', reject);
    zip.pipe(output);
    zip.directory(releaseDir, `ColaNasOs-Client-${version}-windows-x64`);
    void zip.finalize();
  });
}

function escapeNsis(text) {
  return String(text).replace(/"/g, '$\\"');
}

function writeNsi(makensis) {
  const ico = path.join(root, 'resources', 'icon.ico');
  const outFile = path.join(distDir, `ColaNasOs-Client-${version}-Setup.exe`);
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-nsi-'));
  const script = path.join(tmpDir, 'client.nsi');

  const nsi = `Unicode true
!include "MUI2.nsh"

!define APP_NAME "${escapeNsis(appName)}"
!define APP_EXE "${exeName}"
!define APP_VERSION "${version}"
!define UNINST_KEY "Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\ColaNasOsClient"

Name "\${APP_NAME}"
OutFile "${escapeNsis(outFile)}"
InstallDir "$LOCALAPPDATA\\Programs\\ColaNasOs 客户端"
InstallDirRegKey HKCU "Software\\ColaNasOs\\Client" "InstallDir"
RequestExecutionLevel user
SetCompressor /SOLID lzma

!define MUI_ICON "${escapeNsis(ico)}"
!define MUI_UNICON "${escapeNsis(ico)}"
!define MUI_ABORTWARNING
!define MUI_FINISHPAGE_RUN "$INSTDIR\\\${APP_EXE}"
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "SimpChinese"
!insertmacro MUI_LANGUAGE "English"

VIProductVersion "${version}.0"
VIAddVersionKey "ProductName" "\${APP_NAME}"
VIAddVersionKey "FileDescription" "\${APP_NAME} 安装程序"
VIAddVersionKey "FileVersion" "\${APP_VERSION}"
VIAddVersionKey "ProductVersion" "\${APP_VERSION}"
VIAddVersionKey "LegalCopyright" "Copyright © 2026 ColaNasOs"

Section "\${APP_NAME}" SecMain
  SetShellVarContext current
  SetOutPath "$INSTDIR"
  File /r "${escapeNsis(releaseDir)}\\*.*"

  WriteRegStr HKCU "Software\\ColaNasOs\\Client" "InstallDir" "$INSTDIR"
  WriteUninstaller "$INSTDIR\\Uninstall.exe"

  CreateShortcut "$DESKTOP\\\${APP_NAME}.lnk" "$INSTDIR\\\${APP_EXE}" "" "$INSTDIR\\\${APP_EXE}" 0
  CreateDirectory "$SMPROGRAMS\\\${APP_NAME}"
  CreateShortcut "$SMPROGRAMS\\\${APP_NAME}\\\${APP_NAME}.lnk" "$INSTDIR\\\${APP_EXE}" "" "$INSTDIR\\\${APP_EXE}" 0
  CreateShortcut "$SMPROGRAMS\\\${APP_NAME}\\卸载 \${APP_NAME}.lnk" "$INSTDIR\\Uninstall.exe"

  WriteRegStr HKCU "\${UNINST_KEY}" "DisplayName" "\${APP_NAME}"
  WriteRegStr HKCU "\${UNINST_KEY}" "DisplayVersion" "\${APP_VERSION}"
  WriteRegStr HKCU "\${UNINST_KEY}" "Publisher" "ColaNasOs"
  WriteRegStr HKCU "\${UNINST_KEY}" "DisplayIcon" "$INSTDIR\\\${APP_EXE}"
  WriteRegStr HKCU "\${UNINST_KEY}" "UninstallString" "$\\"$INSTDIR\\Uninstall.exe$\\""
  WriteRegStr HKCU "\${UNINST_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegDWORD HKCU "\${UNINST_KEY}" "NoModify" 1
  WriteRegDWORD HKCU "\${UNINST_KEY}" "NoRepair" 1
SectionEnd

Section "Uninstall"
  SetShellVarContext current
  Delete "$DESKTOP\\\${APP_NAME}.lnk"
  RMDir /r "$SMPROGRAMS\\\${APP_NAME}"
  RMDir /r "$INSTDIR"
  DeleteRegKey HKCU "\${UNINST_KEY}"
  DeleteRegKey HKCU "Software\\ColaNasOs\\Client"
SectionEnd
`;

  // NSIS 只有在脚本带 UTF-8 BOM 时才按 UTF-8 解析；否则中文产品名会报「Bad text encoding」
  fs.writeFileSync(script, `\uFEFF${nsi}`, 'utf-8');
  console.log(`[client-installer] makensis: ${makensis}`);
  const r = spawnSync(makensis, ['/V2', script], { cwd: root, stdio: 'inherit' });
  fs.rmSync(tmpDir, { recursive: true, force: true });
  if (r.status !== 0) {
    console.error('[client-installer] NSIS 编译失败');
    process.exit(r.status ?? 1);
  }
  return outFile;
}

(async () => {
  if (!skipBuild) buildFlutter();
  if (!fs.existsSync(path.join(releaseDir, exeName))) {
    console.error(`[client-installer] 找不到 ${path.join(releaseDir, exeName)}，先跑 flutter build windows --release`);
    process.exit(1);
  }
  fs.mkdirSync(distDir, { recursive: true });

  const makensis = findMakensis();
  if (!makensis) {
    console.warn('[client-installer] [!] 找不到 makensis（NSIS），只产出便携 zip。');
    console.warn('                  需要安装包时：装 NSIS，或跑一次 `npm run pack` 让 electron-builder 下载缓存。');
  } else {
    const installer = writeNsi(makensis);
    console.log(`[client-installer] PC 客户端安装包：${installer}`);
  }

  if (!noZip) {
    const zipPath = await writeZip();
    console.log(`[client-installer] PC 客户端便携包：${zipPath}`);
  }
  console.log('[client-installer] 产物目录 dist_installer/（服务端同名带 Server，客户端带 Client）');
})();
