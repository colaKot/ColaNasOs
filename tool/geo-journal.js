#!/usr/bin/env node
/**
 * 把随包的地名库 `vendor/geo/geonames.sqlite` 转成 **rollback journal（DELETE）** 模式。
 *
 * 为什么必须做（2026-11-12 装机版 500 的根因）：
 *   地名库是从开发机直接拷出来的 WAL 库（header 第 18/19 字节 = 2），但打包时只带
 *   `.sqlite`、不带 `-shm/-wal`。安装到 `C:\Program Files\ColaNasOs\resources\geo`
 *   后是只读资源，SQLite 以 readonly 打开 WAL 库时无法创建 `-shm`，**open 能成功、
 *   首次 `prepare` 才报 `SQLITE_CANTOPEN: unable to open database file`** ——
 *   表现就是「相册回忆」整页 500（`/api/v1/photo/memories/chapters`）。
 *
 *   转成 DELETE 模式后没有旁路文件，只读打开即可正常查询（已实测）。
 *
 * 用法（由 tool/build-pack.js 在打包前调用，需用 Electron 的 node 跑，ABI 才匹配）：
 *   ELECTRON_RUN_AS_NODE=1 electron.exe tool/geo-journal.js
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');

const file = path.join(__dirname, '..', 'vendor', 'geo', 'geonames.sqlite');

if (!fs.existsSync(file)) {
  console.log('[geo] 未找到 vendor/geo/geonames.sqlite，跳过（相册地名会降级为空）');
  process.exit(0);
}

const header = fs.readFileSync(file).subarray(0, 100);
const writeVer = header[18];
if (writeVer !== 2) {
  console.log(`[geo] journal_mode 已是 legacy（header=${writeVer}），无需转换`);
  process.exit(0);
}

const Database = require('better-sqlite3');
const db = new Database(file);
try {
  // 先把 -wal 里的内容落回主库，再切模式，否则切换时可能丢最后几条
  db.pragma('wal_checkpoint(TRUNCATE)');
  const mode = db.pragma('journal_mode = DELETE', { simple: true });
  console.log(`[geo] journal_mode → ${mode}`);
} finally {
  db.close();
}

for (const f of [`${file}-wal`, `${file}-shm`]) {
  if (fs.existsSync(f)) {
    fs.rmSync(f, { force: true });
    console.log(`[geo] removed ${path.basename(f)}`);
  }
}
console.log(`[geo] ${file} 已转成只读友好的 DELETE 模式`);
