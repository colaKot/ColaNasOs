#!/usr/bin/env node
/**
 * 契约生成器（SP0-07）：从真实运行实例导出 OpenAPI，避免手写漂移。
 * 需 Electron 运行时（better-sqlite3 为 Electron ABI），脚本自动自举。
 *
 * 用法：
 *   node tool/gen.js          生成 contracts/openapi.json
 *   node tool/gen.js --check   校验是否与代码一致（CI 用）
 */
'use strict';

const path = require('node:path');
const fs = require('node:fs');
const os = require('node:os');
const { spawnSync } = require('node:child_process');

function exeName() {
  return process.platform === 'win32' ? 'electron.exe' : 'electron';
}

function resolveElectronExe() {
  const candidates = [
    path.join(process.cwd(), 'node_modules', 'electron', 'dist', exeName()),
    path.join(__dirname, '..', 'node_modules', 'electron', 'dist', exeName()),
  ];
  for (const c of candidates) {
    if (fs.existsSync(c)) return c;
  }
  return null;
}

if (!process.versions.electron) {
  const exe = resolveElectronExe();
  if (!exe) {
    console.error('[FATAL] 找不到 electron，请先 npm install');
    process.exit(2);
  }
  const r = spawnSync(exe, [__filename, ...process.argv.slice(2)], {
    stdio: 'inherit',
    env: Object.assign({}, process.env, { ELECTRON_RUN_AS_NODE: '1' }),
  });
  process.exit(typeof r.status === 'number' ? r.status : 1);
}

const root = path.join(__dirname, '..');
const out = path.join(root, 'contracts', 'openapi.json');
const checkOnly = process.argv.includes('--check');

process.chdir(root);

/**
 * Fastify 对「非对象请求体」的 consumes 表达有限，二进制上传在导出后手工修正，
 * 保证生成器能识别 application/octet-stream。
 */
function normalizeSpec(spec) {
  const chunk = spec.paths && spec.paths['/api/v1/files/chunk'];
  const body = chunk && chunk.post && chunk.post.requestBody;
  const jsonBody = body && body.content && body.content['application/json'];
  if (jsonBody) {
    body.content = { 'application/octet-stream': jsonBody };
  }

  // 下载返回二进制：标注扩展字段，客户端生成器据此返回字节数组
  for (const p of ['/api/v1/files/download', '/api/v1/files/thumb']) {
    const op = spec.paths && spec.paths[p] && spec.paths[p].get;
    if (op) op['x-response-binary'] = true;
  }

  return spec;
}

(async () => {
  // 契约要描述**完整**接口集：开发令牌（`/auth/dev-token`）运行时默认关闭，但仍属于公开接口，
  // 生成时显式开启，避免它从 OpenAPI 里「消失」被当成破坏性变更。
  process.env.COLANAS_DEV_TOKEN = '1';
  const { startKernel } = require(path.join(root, 'dist', 'kernel', 'index'));

  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-gen-'));
  const k = await startKernel({ dataDir, port: 0, listen: false });
  await k.app.ready();

  const spec = normalizeSpec(k.app.swagger());
  await k.app.close();
  try { fs.rmSync(dataDir, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 }); } catch { /* 日志句柄释放有延迟，交给系统清理 */ }

  const next = JSON.stringify(spec, null, 2) + '\n';
  const paths = Object.keys(spec.paths || {}).length;

  if (checkOnly) {
    const prev = fs.existsSync(out) ? fs.readFileSync(out, 'utf-8') : '';
    if (prev !== next) {
      console.error(
        `[gen.check] contracts/openapi.json 已过期（paths=${paths}），请运行 npm run gen`,
      );
      process.exit(1);
    }
    console.log(`[gen.check] ok, paths=${paths}`);
    return;
  }

  fs.mkdirSync(path.dirname(out), { recursive: true });
  fs.writeFileSync(out, next, 'utf-8');
  console.log(`[gen] wrote ${out} paths=${paths}`);
})().catch((e) => {
  console.error('[FATAL]', e);
  process.exit(1);
});
