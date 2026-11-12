import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { app } from 'electron';

/**
 * 「开机自动启动」开关。
 *
 * 两件事分开：
 *   - **状态**存在数据目录的 `config.json`（`autostart` 字段），默认不勾选。
 *     设置页 / 托盘都读这一份，重装、便携版挪目录都不会把状态弄丢。
 *   - **生效**交给系统：Windows 写 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`
 *     （`app.setLoginItemSettings`），安装版与便携版都对当前 exe 生效。
 *
 * 便携版的 exe 路径会变，所以每次启动都按当前 `process.execPath` 重写一遍；
 * 开发态（`electron .`）不写 —— 否则会把真实安装版的启动项覆盖成 electron.exe。
 */

export function dataDir(): string {
  const base = process.env.APPDATA || path.join(os.homedir(), '.config');
  return process.env.COLANAS_DATA_DIR || path.join(base, 'colanas_os_server');
}

function configPath(): string {
  return path.join(dataDir(), 'config.json');
}

function readConfig(): Record<string, unknown> {
  try {
    return JSON.parse(fs.readFileSync(configPath(), 'utf-8')) as Record<string, unknown>;
  } catch {
    return {};
  }
}

/** 默认关闭：只有显式写入 `autostart: true` 才算开启 */
export function isAutostartEnabled(): boolean {
  return readConfig().autostart === true;
}

function applyLoginItem(enabled: boolean): void {
  try {
    app.setLoginItemSettings({
      openAtLogin: enabled,
      path: process.execPath,
      args: [],
    });
  } catch (err) {
    console.error('[shell] setLoginItemSettings 失败：', err);
  }
}

/** 用户切换开关：先落盘，再写系统启动项 */
export function setAutostart(enabled: boolean): void {
  const cfg = readConfig();
  cfg.autostart = enabled;
  try {
    fs.mkdirSync(dataDir(), { recursive: true });
    fs.writeFileSync(configPath(), JSON.stringify(cfg, null, 2), 'utf-8');
  } catch (err) {
    console.error('[shell] 写入开机自启设置失败：', err);
  }
  if (app.isPackaged) applyLoginItem(enabled);
}

/**
 * 启动时对账：按配置把启动项同步成当前 exe 路径（便携版最需要）。
 * 返回当前是否开启，托盘菜单用它打勾。
 */
export function syncAutostart(): boolean {
  const enabled = isAutostartEnabled();
  if (app.isPackaged) applyLoginItem(enabled);
  return enabled;
}
