#!/usr/bin/env node
/**
 * indexer sidecar（SP2-04）：目录遍历 → 批量推送。
 *
 * 协议：
 *   invoke('scan', { root, batchSize?, flushMs?, sinceSeq? }) → { accepted: true }
 *   event 'batch'     { seq, entries:[{path,size,mtime}], done }
 *   event 'scan_done' { total, batches }
 *
 * 断点续传：`sinceSeq` 之前批次不再推送（扫描仍从头遍历，写库侧跳过已应用批），
 * 保证重启后不重复写、最终一致。
 */
'use strict';

const fs = require('node:fs');
const nodePath = require('node:path');
const { setImmediate } = require('node:timers');

process.stdin.setEncoding('utf8');
process.stdout.on('error', () => {
  /* 父进程已退出 */
});

let buf = '';
const send = (obj) => {
  if (process.stdout.writable) process.stdout.write(JSON.stringify(obj) + '\n');
};

async function* walk(root, rel) {
  let entries;
  try {
    entries = await fs.promises.readdir(nodePath.join(root, rel), { withFileTypes: true });
  } catch {
    return;
  }

  entries.sort((a, b) => a.name.localeCompare(b.name));

  for (const e of entries) {
    const childRel = rel ? `${rel}/${e.name}` : e.name;
    if (e.isDirectory()) {
      yield* walk(root, childRel);
    } else if (e.isFile()) {
      try {
        const st = await fs.promises.stat(nodePath.join(root, childRel));
        yield { path: childRel, size: st.size, mtime: Math.floor(st.mtimeMs) };
      } catch {
        /* 文件在遍历中被删除，跳过 */
      }
    }
  }
}

let busy = false;

async function scan(params) {
  if (busy) throw Object.assign(new Error('scan already running'), { code: 'E_BUSY' });

  const root = params.root;
  if (typeof root !== 'string' || root.length === 0) {
    throw Object.assign(new Error('root required'), { code: 'E_PARAM' });
  }

  const batchSize = Math.max(1, Math.min(Number(params.batchSize) || 500, 2000));
  const flushMs = Math.max(100, Number(params.flushMs) || 2000);
  const sinceSeq = Math.max(0, Number(params.sinceSeq) || 0);

  busy = true;
  setImmediate(async () => {
    let batch = [];
    let seq = 0;
    let total = 0;
    let lastFlush = Date.now();

    const flush = (done) => {
      seq += 1;
      if (seq > sinceSeq) {
        send({ type: 'event', event: 'batch', data: { seq, entries: batch, done } });
      }
      batch = [];
      lastFlush = Date.now();
    };

    try {
      for await (const entry of walk(root, '')) {
        batch.push(entry);
        total += 1;
        if (batch.length >= batchSize) flush(false);
        else if (Date.now() - lastFlush >= flushMs) flush(false);
      }
      if (batch.length > 0) flush(false);
      flush(true);
      send({ type: 'event', event: 'scan_done', data: { total, batches: seq } });
    } catch (err) {
      send({ type: 'event', event: 'scan_failed', data: { message: String(err && err.message) } });
    } finally {
      busy = false;
    }
  });

  return { accepted: true };
}

function handle(msg) {
  if (msg.type === 'ping') {
    send({ id: msg.id, ok: true, result: 'pong' });
    return;
  }

  if (msg.type === 'invoke' && msg.method === 'scan') {
    scan(msg.params || {})
      .then((result) => send({ id: msg.id, ok: true, result }))
      .catch((err) =>
        send({
          id: msg.id,
          ok: false,
          error: { code: err.code || 'E_SCAN', message: String(err.message) },
        }),
      );
    return;
  }

  if (msg.type === 'shutdown') {
    send({ id: msg.id, ok: true });
    setTimeout(() => process.exit(0), 5);
    return;
  }

  if (msg.type === 'invoke') {
    send({
      id: msg.id,
      ok: false,
      error: { code: 'E_METHOD', message: `unknown method: ${msg.method}` },
    });
    return;
  }

  send({ type: 'log', level: 'warn', message: `unknown message type: ${msg.type}` });
}

process.stdin.on('data', (chunk) => {
  buf += chunk;
  let idx = buf.indexOf('\n');
  while (idx >= 0) {
    const line = buf.slice(0, idx).trim();
    buf = buf.slice(idx + 1);
    if (line) {
      try {
        handle(JSON.parse(line));
      } catch {
        send({ type: 'log', level: 'warn', message: 'bad ndjson line' });
      }
    }
    idx = buf.indexOf('\n');
  }
});

process.stdin.on('end', () => process.exit(0));