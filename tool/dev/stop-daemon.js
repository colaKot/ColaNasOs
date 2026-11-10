'use strict';
/* global AbortSignal */
/**
 * 停掉由本项目拉起的 transmission-daemon。
 *
 * 用途：开发守护（tool/dev/watch-kernel.js）退出时调用 —— 内核被 kill 重启时
 * **故意不停** daemon（否则每次重启都是一次新的 tracker session），但整个开发
 * 环境真的退出时应该一起停：种子先发 stopped，再杀进程。
 *
 * 依据 `<dataDir>/transmission/daemon.json`（内核 spawn 时写入的 pid/port）；
 * 没有这个文件说明端口上是用户自己装的 transmission，一律不动。
 */
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const dataDir =
  process.env.COLANAS_DATA_DIR ||
  path.join(process.env.APPDATA || process.env.HOME || '.', 'colanas_os_server');
const infoFile = path.join(dataDir, 'transmission', 'daemon.json');

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function readInfo() {
  try {
    const raw = JSON.parse(fs.readFileSync(infoFile, 'utf8'));
    return raw && Number(raw.pid) > 0 && Number(raw.port) > 0 ? raw : null;
  } catch {
    return null;
  }
}

function isDaemon(pid) {
  try {
    const r = spawnSync('tasklist', ['/FI', `PID eq ${pid}`, '/FO', 'CSV', '/NH'], {
      encoding: 'utf8',
      windowsHide: true,
    });
    return /transmission-daemon\.exe/i.test(String(r.stdout || ''));
  } catch {
    return false;
  }
}

async function rpc(url, method, args, sessionId) {
  const res = await fetch(url, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      ...(sessionId ? { 'x-transmission-session-id': sessionId } : {}),
    },
    body: JSON.stringify({ method, arguments: args || {} }),
    signal: AbortSignal.timeout(2000),
  });
  const sid = res.headers.get('x-transmission-session-id');
  if (res.status === 409 && sid) return rpc(url, method, args, sid);
  return res.json();
}

(async () => {
  const info = readInfo();
  if (!info || !isDaemon(info.pid)) {
    console.log('[stop-daemon] 没有由本项目拉起的 transmission，跳过');
    return;
  }
  const url = `http://127.0.0.1:${info.port}/transmission/rpc`;
  try {
    const list = await rpc(url, 'torrent-get', { fields: ['id', 'status'] });
    const ids = (list.arguments?.torrents || [])
      .filter((t) => t.status !== 0)
      .map((t) => String(t.id));
    if (ids.length) await rpc(url, 'torrent-stop', { ids });
    console.log(`[stop-daemon] 已暂停 ${ids.length} 个种子，等待 tracker 的 stopped 发出…`);
    await sleep(1500);
  } catch (err) {
    console.log('[stop-daemon] RPC 停种子失败（继续杀进程）：', String(err && err.message));
  }
  try {
    process.kill(info.pid);
    console.log('[stop-daemon] 已结束 transmission-daemon', info.pid);
  } catch {
    console.log('[stop-daemon] 进程已不在', info.pid);
  }
  try {
    fs.unlinkSync(infoFile);
  } catch {
    /* 已经没了 */
  }
})();
