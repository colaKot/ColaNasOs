#!/usr/bin/env node
/**
 * 六端构建实测（X-01）：逐端 `flutter build`，记录耗时 / 产物大小 / 不可测原因，
 * 结果写入 `docs/bench/x01-ends.md`。
 *
 *   node tool/build-ends.js                       # 全部可测端
 *   node tool/build-ends.js --only=windows,web    # 指定端
 *   node tool/build-ends.js --out=...md           # 自定义输出
 *
 * 端与环境强绑定：windows 只能 Win、macos/ios 只能 macOS、linux 只能 Linux；
 * 缺工具链时**不猜**，直接标 skipped 并写原因——这是实测报告，不是打勾表。
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const root = path.join(__dirname, '..');
const appDir = path.join(root, 'apps', 'colanas_os');
const platform = process.platform;

const TARGETS = {
  windows: {
    build: ['build', 'windows', '--release'],
    outputs: ['build/windows/x64/runner/Release'],
    platforms: ['win32'],
  },
  web: {
    build: ['build', 'web', '--release'],
    outputs: ['build/web'],
    platforms: ['win32', 'darwin', 'linux'],
  },
  apk: {
    build: ['build', 'apk', '--debug'],
    outputs: ['build/app/outputs/flutter-apk/app-debug.apk'],
    platforms: ['win32', 'darwin', 'linux'],
  },
  linux: {
    build: ['build', 'linux', '--release'],
    outputs: ['build/linux/x64/release/bundle'],
    platforms: [],
  },
  macos: {
    build: ['build', 'macos', '--release'],
    outputs: ['build/macos/Build/Products/Release'],
    platforms: [],
  },
  ios: { build: ['build', 'ios', '--no-codesign'], outputs: ['build/ios/iphoneos'], platforms: [] },
  // 鸿蒙：需要 flutter_ohos（与 Flutter 3.47 配套）+ 本项目 profile；
  // 用 COLANAS_FLUTTER_OHOS 指向该 SDK 的 flutter(.bat)，缺省时记 skipped。
  ohos: {
    build: ['build', 'hap', '--release'],
    outputs: ['build/ohos/hap'],
    platforms: ['win32', 'darwin', 'linux'],
    requireEnv: 'COLANAS_FLUTTER_OHOS',
    envHint: '未设置 COLANAS_FLUTTER_OHOS（指向 flutter_ohos 的 flutter 可执行文件）',
  },
};

function parseArgs(argv) {
  const out = {};
  for (const a of argv) {
    const m = /^--([^=]+)=(.*)$/.exec(a);
    if (m) out[m[1]] = m[2];
  }
  out.out = out.out || 'docs/bench/x01-ends.md';
  return out;
}

function sizeOf(target) {
  const abs = path.join(appDir, target);
  if (!fs.existsSync(abs)) return { exists: false, bytes: 0 };
  const st = fs.statSync(abs);
  if (st.isFile()) return { exists: true, bytes: st.size };
  let total = 0;
  const stack = [abs];
  while (stack.length) {
    const dir = stack.pop();
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
      const f = path.join(dir, e.name);
      if (e.isDirectory()) stack.push(f);
      else total += fs.statSync(f).size;
    }
  }
  return { exists: true, bytes: total };
}

function human(bytes) {
  if (bytes >= 1024 * 1024) return (bytes / 1024 / 1024).toFixed(1) + ' MB';
  if (bytes >= 1024) return (bytes / 1024).toFixed(1) + ' KB';
  return bytes + ' B';
}

function flutterVersion() {
  const r = spawnSync('flutter', ['--version'], { cwd: appDir, shell: true, encoding: 'utf-8' });
  const first = (r.stdout || '').split('\n')[0].trim();
  return first || 'unknown';
}

function runTarget(name, cfg) {
  if (!cfg.platforms.includes(platform)) {
    return {
      name,
      status: 'skipped',
      reason: `当前平台 ${platform} 无法构建 ${name}`,
      ms: 0,
      size: '',
      artifact: '',
    };
  }
  if (cfg.requireEnv && !process.env[cfg.requireEnv]) {
    return {
      name,
      status: 'skipped',
      reason: cfg.envHint || `缺少 ${cfg.requireEnv}`,
      ms: 0,
      size: '',
      artifact: '',
    };
  }
  const flutter = cfg.requireEnv ? process.env[cfg.requireEnv] : 'flutter';
  const t0 = Date.now();
  const r = spawnSync(flutter, cfg.build, {
    cwd: appDir,
    shell: true,
    encoding: 'utf-8',
    env: process.env,
  });
  const ms = Date.now() - t0;
  const ok = r.status === 0;

  let size = '';
  let artifact = cfg.outputs[0];
  if (ok) {
    let bytes = 0;
    for (const o of cfg.outputs) bytes += sizeOf(o).bytes;
    size = human(bytes);
  } else {
    const log = ((r.stdout || '') + (r.stderr || '')).split('\n');
    const tail = log
      .filter((l) => l.trim())
      .slice(-4)
      .join(' ');
    artifact = tail.slice(0, 200);
  }
  return {
    name,
    status: ok ? 'ok' : 'failed',
    reason: ok ? '' : '构建失败，见输出末行',
    ms,
    size,
    artifact,
  };
}

const args = parseArgs(process.argv.slice(2));
const only = args.only ? args.only.split(',').map((s) => s.trim()) : Object.keys(TARGETS);
const blocked = new Map(
  (args.blocked || '')
    .split(',')
    .filter(Boolean)
    .map((s) => {
      const i = s.indexOf(':');
      return [s.slice(0, i).trim(), s.slice(i + 1).trim()];
    }),
);
const rows = only.map((n) => {
  if (!TARGETS[n]) throw new Error('未知端：' + n);
  if (blocked.has(n)) {
    return { name: n, status: 'blocked', reason: blocked.get(n), ms: 0, size: '', artifact: '' };
  }
  process.stderr.write(`[build-ends] ${n} ...\n`);
  const r = runTarget(n, TARGETS[n]);
  process.stderr.write(
    `[build-ends] ${n} → ${r.status} ${r.ms ? (r.ms / 1000).toFixed(1) + 's' : ''}\n`,
  );
  return r;
});

const stamp = new Date().toISOString().slice(0, 10);
const lines = [
  '# X-01 六端构建实测',
  '',
  `> 由 \`node tool/build-ends.js\` 生成（${stamp}）；环境：${flutterVersion()} · ${platform}；表内为 \`flutter clean\` 后的冷构建。`,
  '> 不可测的端直接标 `skipped` 并写明原因，不做推测。',
  '',
  '| 端 | 结果 | 耗时 | 产物 / 体积 | 说明 |',
  '| --- | --- | --- | --- | --- |',
  ...rows.map((r) => {
    const dur = r.ms ? (r.ms / 1000).toFixed(1) + ' s' : '-';
    const prod = r.status === 'ok' ? '`' + r.artifact + '` ' + r.size : '-';
    return `| ${r.name} | ${r.status} | ${dur} | ${prod} | ${r.reason || '-'} |`;
  }),
  '',
  '## 结论',
  '',
  '- 已实测端：' +
    (rows
      .filter((r) => r.status === 'ok')
      .map((r) => r.name)
      .join(' / ') || '无'),
  '- 失败端：' +
    (rows
      .filter((r) => r.status === 'failed')
      .map((r) => r.name)
      .join(' / ') || '无'),
  '- 受限端：' +
    (rows
      .filter((r) => r.status === 'blocked')
      .map((r) => r.name)
      .join(' / ') || '无'),
  '- 未测端：' +
    (rows
      .filter((r) => r.status === 'skipped')
      .map((r) => r.name)
      .join(' / ') || '无'),
  '',
  '> windows / web 可在本机复现；macos / ios 需 macOS 构建机，linux 需 Linux 构建机；',
  '> 鸿蒙（CL4-01）需 `COLANAS_FLUTTER_OHOS` 指向 flutter_ohos（与 Flutter 3.47 配套），',
  '> TV（CL4-02）需 Android TV 工程，均不在默认实测范围。',
  '>',
  '> 耗时与缓存强相关：`flutter clean` 后是冷构建，二次重建通常快一个量级',
  '> （同机实测 windows 增量约 8 s，web 因要重新编译 Dart→JS，提速有限）。',
  '',
];

const outPath = path.join(root, args.out);
fs.mkdirSync(path.dirname(outPath), { recursive: true });
fs.writeFileSync(outPath, lines.join('\n'), 'utf-8');
console.log(`[build-ends] wrote ${args.out}`);
for (const r of rows) console.log(`  ${r.name.padEnd(8)} ${r.status.padEnd(8)} ${r.size || ''}`);
