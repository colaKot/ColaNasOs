#!/usr/bin/env node
/**
 * ai-infer 验收（SP2-02）：
 *  1. 会话可创建且推理通（mnist-8，输出 [1,10]）
 *  2. EP 白名单显式排除 webgpu
 *  3. 并发请求下会话只创建一次（串行建会话）
 *  4. 会话复用：runs 累加、creates 不增加
 *  5. 缺模型返回 E_NO_MODEL
 *
 * 纯 Node 运行（onnxruntime-node 为 N-API，无需 Electron ABI）。
 * 用法：node tool/check/ai-smoke.js
 */
'use strict';

const path = require('node:path');

const root = path.join(__dirname, '..', '..');
const { SidecarSupervisor } = require(path.join(root, 'dist', 'kernel', 'sidecar', 'supervisor'));

const results = [];
const check = (name, ok, detail) => results.push({ name, ok, detail: detail || '' });

const DIMS = [1, 1, 28, 28];
const INPUT = new Array(28 * 28).fill(0);

(async () => {
  const sup = new SidecarSupervisor({
    name: 'ai-infer',
    command: process.env.COLANAS_SIDECAR_NODE || process.execPath,
    args: [path.join(root, 'sidecars', 'ai-infer', 'main.js')],
    requestTimeoutMs: 20_000,
    heartbeatMs: 5_000,
    maxRestarts: 2,
    startTimeoutMs: 15_000,
    stopGraceMs: 3_000,
    log: () => {},
  });

  await sup.start();
  check('start_ready', sup.state === 'ready', 'pid=' + sup.pid);

  const ep = await sup.request('eps');
  check(
    'eps_excludes_webgpu',
    Array.isArray(ep.eps) && !ep.eps.includes('webgpu') && ep.eps.includes('cpu'),
    JSON.stringify(ep.eps),
  );

  const list0 = await sup.request('list');
  check('list_models', list0.models.includes('mnist-8'), list0.models.join(','));

  const first = await sup.request('infer', { model: 'mnist-8', dims: DIMS, data: INPUT });
  check(
    'infer_shape',
    Array.isArray(first.dims) && first.dims.join('x') === '1x10' && first.data.length === 10,
    `dims=${(first.dims || []).join('x')} n=${(first.data || []).length}`,
  );

  // 并发 4 个请求：串行建会话保证 creates 仍为 1
  const many = await Promise.all(
    Array.from({ length: 4 }, () => sup.request('infer', { model: 'mnist-8', dims: DIMS, data: INPUT })),
  );
  check(
    'concurrent_infer',
    many.every((r) => r.data.length === 10) && many.every((r) => r.creates === 1),
    'creates=' + many.map((r) => r.creates).join(','),
  );

  const after = await sup.request('list');
  const rec = after.loaded.find((x) => x.model === 'mnist-8');
  check(
    'session_reuse',
    after.creates === 1 && rec && rec.runs === 5,
    `creates=${after.creates} runs=${rec ? rec.runs : -1}`,
  );

  let missing = null;
  try {
    await sup.request('infer', { model: 'no-such-model', dims: DIMS, data: INPUT });
  } catch (err) {
    missing = err.code;
  }
  check('missing_model', missing === 'E_NO_MODEL', 'code=' + missing);

  const un = await sup.request('unload', { model: 'mnist-8' });
  const listEnd = await sup.request('list');
  check('unload', un.unloaded === true && listEnd.loaded.length === 0, JSON.stringify(un));

  await sup.stop();

  let failed = 0;
  for (const x of results) {
    console.log(`${x.ok ? '[OK]  ' : '[FAIL]'} ${x.name.padEnd(22)} ${x.detail}`);
    if (!x.ok) failed++;
  }
  console.log(`[summary] ${results.length - failed}/${results.length} passed`);
  process.exit(failed ? 1 : 0);
})().catch((e) => {
  console.error('[FATAL]', e);
  process.exit(1);
});