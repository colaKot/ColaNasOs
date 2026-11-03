#!/usr/bin/env node
/**
 * 最小 Sidecar：SP2 协议自检用（ping / echo / fail / sleep / emit / shutdown）。
 * 协议见 kernel/sidecar/protocol.ts。
 */
'use strict';

process.stdin.setEncoding('utf8');
process.stdout.on('error', () => {
  /* 父进程已退出，忽略 EPIPE */
});

let buf = '';

const send = (obj) => {
  if (process.stdout.writable) process.stdout.write(JSON.stringify(obj) + '\n');
};

function handle(msg) {
  if (msg.type === 'ping') {
    send({ id: msg.id, ok: true, result: 'pong' });
    return;
  }

  if (msg.type === 'invoke') {
    switch (msg.method) {
      case 'echo':
        send({ id: msg.id, ok: true, result: msg.params ?? null });
        return;
      case 'fail':
        send({ id: msg.id, ok: false, error: { code: 'E_FAIL', message: 'boom' } });
        return;
      case 'sleep':
        setTimeout(() => send({ id: msg.id, ok: true, result: 'slept' }), Number(msg.params?.ms ?? 100));
        return;
      case 'emit':
        send({ type: 'event', event: 'progress', data: { pct: 50 } });
        send({ id: msg.id, ok: true });
        return;
      case 'pid':
        send({ id: msg.id, ok: true, result: process.pid });
        return;
      default:
        send({ id: msg.id, ok: false, error: { code: 'E_METHOD', message: `unknown method: ${msg.method}` } });
    }
    return;
  }

  if (msg.type === 'shutdown') {
    send({ id: msg.id, ok: true });
    setTimeout(() => process.exit(0), 5);
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