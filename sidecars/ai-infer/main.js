#!/usr/bin/env node
/**
 * ai-infer sidecar（SP2-02）：ONNX 推理。
 *
 * 协议：
 *   invoke('infer', { model, dims, data, dtype?, inputName?, outputName? }) -> { dims, data, type, runs }
 *   invoke('list')  -> { models:[name], loaded:[{ model, runs }], creates }
 *   invoke('eps')   -> { eps, backend }        // 执行提供者白名单（永不包含 webgpu）
 *   invoke('unload', { model }) -> { unloaded: true }
 *
 * 红线（docs/02 §15）：
 *   - 会话**串行创建**：所有 create 挂在同一条 promise 链上，进程内同一时刻只有一次 create。
 *   - EP 白名单**显式排除 webgpu**（1.30 的 webgpu/dml 互斥会在 Windows 上废掉全部会话）。
 */
'use strict';

const fs = require('node:fs');
const nodePath = require('node:path');
const ort = require('onnxruntime-node');

const MODEL_ROOT =
  process.env.COLANAS_MODEL_DIR || nodePath.join(__dirname, '..', '..', 'onnx_models');

/** 白名单：即使后端列表里出现 webgpu 也不会被选中 */
const EP_ALLOW = ['dml', 'cuda', 'cpu'];

process.stdin.setEncoding('utf8');
process.stdout.on('error', () => {
  /* 父进程已退出 */
});

let buf = '';
const send = (obj) => {
  if (process.stdout.writable) process.stdout.write(JSON.stringify(obj) + '\n');
};

function listModels() {
  try {
    return fs
      .readdirSync(MODEL_ROOT, { withFileTypes: true })
      .filter((e) => e.isDirectory())
      .map((e) => e.name)
      .sort();
  } catch {
    return [];
  }
}

/** 解析模型文件：<root>/<name>/<version>/model.onnx（取最大版本）或 <root>/<name>.onnx */
function resolveModel(name) {
  if (typeof name !== 'string' || !name) return null;
  const flat = nodePath.join(MODEL_ROOT, `${name}.onnx`);
  if (fs.existsSync(flat)) return flat;

  const dir = nodePath.join(MODEL_ROOT, name);
  let versions;
  try {
    versions = fs.readdirSync(dir, { withFileTypes: true }).filter((e) => e.isDirectory());
  } catch {
    return null;
  }
  const sorted = versions
    .map((e) => e.name)
    .sort((a, b) => {
      const na = Number.parseFloat(a);
      const nb = Number.parseFloat(b);
      return Number.isNaN(nb) || Number.isNaN(na) ? b.localeCompare(a) : nb - na;
    });
  for (const v of sorted) {
    const p = nodePath.join(dir, v, 'model.onnx');
    if (fs.existsSync(p)) return p;
  }
  return null;
}

function backendNames() {
  try {
    return ort.listSupportedBackends().map((b) => b.name);
  } catch {
    return ['cpu'];
  }
}

/** 白名单 ∩ 可用后端；webgpu 恒定剔除，cpu 兜底 */
function pickEPs() {
  const available = backendNames();
  const eps = EP_ALLOW.filter((n) => n !== 'webgpu' && available.includes(n));
  if (!eps.includes('cpu')) eps.push('cpu');
  return eps;
}

const eps = pickEPs();
const sessions = new Map();
let creates = 0;
let createChain = Promise.resolve();

/**
 * 串行建会话：同一 name 并发请求只创建一次，且所有创建排队执行。
 */
function loadSession(name) {
  const hit = sessions.get(name);
  if (hit) return Promise.resolve(hit);

  const job = createChain.then(async () => {
    const again = sessions.get(name);
    if (again) return again;

    const modelPath = resolveModel(name);
    if (!modelPath) {
      const err = new Error(`model not found: ${name} (root=${MODEL_ROOT})`);
      err.code = 'E_NO_MODEL';
      throw err;
    }

    const session = await ort.InferenceSession.create(modelPath, { executionProviders: eps });
    creates += 1;
    const rec = { session, modelPath, runs: 0 };
    sessions.set(name, rec);
    send({
      type: 'event',
      event: 'session_created',
      data: { model: name, creates, eps },
    });
    return rec;
  });

  // 链尾吞掉错误，避免一次失败拖垮后续创建
  createChain = job.then(
    () => undefined,
    () => undefined,
  );
  return job;
}

async function infer(params) {
  const name = params && params.model;
  if (!name) {
    throw Object.assign(new Error('model required'), { code: 'E_PARAM' });
  }
  if (!Array.isArray(params.dims) || !Array.isArray(params.data)) {
    throw Object.assign(new Error('dims/data required'), { code: 'E_PARAM' });
  }

  const rec = await loadSession(name);
  const inputName = params.inputName || rec.session.inputNames[0];
  if (!inputName) throw Object.assign(new Error('model has no input'), { code: 'E_MODEL' });

  const tensor = new ort.Tensor(params.dtype || 'float32', params.data, params.dims);
  rec.runs += 1;
  const out = await rec.session.run({ [inputName]: tensor });

  const outName = params.outputName || rec.session.outputNames[0];
  const first = out[outName];
  return {
    model: name,
    outputName: outName,
    dims: first.dims,
    type: first.type,
    data: Array.from(first.data),
    runs: rec.runs,
    creates,
  };
}

function list() {
  return {
    root: MODEL_ROOT,
    models: listModels(),
    eps,
    creates,
    loaded: [...sessions.entries()].map(([model, rec]) => ({
      model,
      runs: rec.runs,
      path: rec.modelPath,
    })),
  };
}

async function unload(params) {
  const name = params && params.model;
  const rec = sessions.get(name);
  if (!rec) return { unloaded: false };
  sessions.delete(name);
  await rec.session.release();
  return { unloaded: true };
}

async function handle(msg) {
  if (msg.type === 'ping') {
    send({ id: msg.id, ok: true, result: 'pong' });
    return;
  }
  if (msg.type === 'shutdown') {
    for (const rec of sessions.values()) {
      try {
        await rec.session.release();
      } catch {
        /* 忽略 */
      }
    }
    send({ id: msg.id, ok: true });
    setTimeout(() => process.exit(0), 5);
    return;
  }
  if (msg.type !== 'invoke') {
    send({ type: 'log', level: 'warn', message: `unknown message type: ${msg.type}` });
    return;
  }

  const handlers = {
    infer,
    list: async () => list(),
    eps: async () => ({ eps, backend: backendNames() }),
    unload,
  };
  const fn = handlers[msg.method];
  if (!fn) {
    send({
      id: msg.id,
      ok: false,
      error: { code: 'E_METHOD', message: `unknown method: ${msg.method}` },
    });
    return;
  }

  try {
    const result = await fn(msg.params || {});
    send({ id: msg.id, ok: true, result });
  } catch (err) {
    send({
      id: msg.id,
      ok: false,
      error: { code: err.code || 'E_INFER', message: String(err.message || err) },
    });
  }
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