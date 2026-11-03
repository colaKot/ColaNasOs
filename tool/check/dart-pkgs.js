#!/usr/bin/env node
/**
 * 客户端包门禁：packages/*（纯 Dart）与 apps/*（Flutter）逐个 analyze，有 test 目录的再跑测试。
 *   - 纯 Dart 包：dart analyze / dart test
 *   - 含 `sdk: flutter` 的工程：flutter analyze / flutter test
 *
 * 找不到 SDK 时打印 SKIP 并以 0 退出（不阻断无 Flutter 环境的机器）。
 * 用法：node tool/check/dart-pkgs.js
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');

const root = path.join(__dirname, '..', '..');
const isWin = process.platform === 'win32';
const argv = process.argv.slice(2);
const jobsArg = argv.find((a) => a.startsWith('--jobs='));
const jobs = Math.max(1, Number(jobsArg ? jobsArg.split('=')[1] : 0) || 4);

function findBin(name) {
  const cands = [];
  if (process.env.COLANAS_DART && name === 'dart') cands.push(process.env.COLANAS_DART);
  if (process.env.COLANAS_FLUTTER && name === 'flutter') cands.push(process.env.COLANAS_FLUTTER);
  const roots = [process.env.FLUTTER_ROOT, 'C:/dev/flutter', 'C:/flutter', 'D:/flutter'].filter(Boolean);
  for (const r of roots) cands.push(path.join(r, 'bin', isWin ? `${name}.bat` : name));
  cands.push(isWin ? `${name}.bat` : name);
  for (const c of cands) {
    const r = spawnSync(c, ['--version'], { encoding: 'utf8', shell: true, windowsHide: true });
    if (r.status === 0) return c;
  }
  return null;
}

const dart = findBin('dart');
if (!dart) {
  console.log('[SKIP] 未找到 Dart SDK（设置 COLANS_DART 或 FLUTTER_ROOT）');
  process.exit(0);
}
const flutter = findBin('flutter');

function targets() {
  const out = [];
  for (const top of ['packages', 'apps']) {
    const dir = path.join(root, top);
    if (!fs.existsSync(dir)) continue;
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
      if (!e.isDirectory()) continue;
      const p = path.join(dir, e.name);
      if (fs.existsSync(path.join(p, 'pubspec.yaml'))) out.push({ name: e.name, dir: p });
    }
  }
  return out.sort((a, b) => a.name.localeCompare(b.name));
}

function run(bin, args, cwd) {
  return new Promise((resolve) => {
    const child = spawn(bin, args, { cwd, shell: true, windowsHide: true });
    let out = '';
    child.stdout.on('data', (d) => (out += d));
    child.stderr.on('data', (d) => (out += d));
    child.on('error', (e) => (out += String(e)));
    child.on('close', (code) => resolve({ code, out }));
  });
}

async function checkTarget(t) {
  const lines = [];
  const pubspec = fs.readFileSync(path.join(t.dir, 'pubspec.yaml'), 'utf8');
  const isFlutter = /sdk:\s*flutter/.test(pubspec);
  const bin = isFlutter ? flutter : dart;
  if (!bin) {
    lines.push(`[SKIP] ${t.name.padEnd(14)} 需要 Flutter，但未找到`);
    return { ok: true, lines };
  }

  const needsGet = !fs.existsSync(path.join(t.dir, '.dart_tool', 'package_config.json'));
  if (needsGet) {
    let pg = await run(bin, ['pub', 'get'], t.dir);
    // 首次并发时 pub 缓存锁可能冲突，串行重试一次
    if (pg.code !== 0) pg = await run(bin, ['pub', 'get'], t.dir);
    if (pg.code !== 0) {
      lines.push(`[FAIL] ${t.name.padEnd(14)} pub get`);
      lines.push(pg.out.split('\n').slice(-8).join('\n'));
      return { ok: false, lines };
    }
  }

  const an = await run(bin, ['analyze'], t.dir);
  lines.push(
    `${an.code === 0 ? '[OK]  ' : '[FAIL]'} ${t.name.padEnd(14)} analyze${isFlutter ? ' (flutter)' : ''}`,
  );
  if (an.code !== 0) {
    lines.push(an.out.split('\n').slice(-8).join('\n'));
    return { ok: false, lines };
  }

  if (fs.existsSync(path.join(t.dir, 'test'))) {
    const te = await run(bin, ['test'], t.dir);
    lines.push(`${te.code === 0 ? '[OK]  ' : '[FAIL]'} ${t.name.padEnd(14)} test`);
    if (te.code !== 0) {
      lines.push(te.out.split('\n').slice(-8).join('\n'));
      return { ok: false, lines };
    }
  }
  return { ok: true, lines };
}

async function pool(items, limit, worker) {
  const results = new Array(items.length);
  let cursor = 0;
  let active = 0;
  return new Promise((resolve) => {
    const pump = () => {
      while (active < limit && cursor < items.length) {
        const index = cursor;
        const item = items[cursor++];
        active += 1;
        worker(item).then((r) => {
          results[index] = r;
          active -= 1;
          pump();
        });
      }
      if (active === 0 && cursor >= items.length) resolve(results);
    };
    pump();
  });
}

(async () => {
  const list = targets();
  const started = Date.now();
  const results = await pool(list, Math.min(jobs, list.length || 1), checkTarget);
  let failed = 0;
  for (const r of results) {
    for (const line of r.lines) console.log(line);
    if (!r.ok) failed += 1;
  }
  console.log(
    `[dart] ${failed === 0 ? '全部通过' : failed + ' 个目标失败'}` +
      `（jobs=${Math.min(jobs, list.length || 1)}, ${((Date.now() - started) / 1000).toFixed(1)}s，` +
      `dart=${dart}${flutter ? ', flutter=' + flutter : ''}）`,
  );
  process.exit(failed ? 1 : 0);
})();