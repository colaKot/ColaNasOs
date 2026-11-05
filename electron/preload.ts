import { contextBridge, ipcRenderer } from 'electron';

/**
 * 同步（以及将来其它需要本地目录的功能）的文件能力桥。
 *
 * 为什么要有它：PC 客户端是 Electron 外壳 + **Flutter Web 产物**，
 * 渲染进程跑在浏览器沙箱里，`dart:io` 不存在，`sync_fs_web.dart` 只能报
 * 「web 端无法创建同步」——可它明明就是桌面客户端（2026-11-04 反馈）。
 *
 * 这里只暴露**一个**入口，参数与返回值都是 JSON 字符串：Dart 侧的
 * `dart:js_interop` 调用越简单越不容易出错（不做结构化的双向对象映射）。
 */
contextBridge.exposeInMainWorld('colanasSync', {
  available: true,
  invoke: (json: string): Promise<string> => ipcRenderer.invoke('colanas:sync', json),
});
