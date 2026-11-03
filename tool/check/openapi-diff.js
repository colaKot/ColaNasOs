#!/usr/bin/env node
/**
 * OpenAPI 破坏性变更检测（SP1-04）。
 * 基线：git HEAD 里的 contracts/openapi.json；目标：工作区的 contracts/openapi.json
 *
 * 判为破坏性：
 *  - 删除 path / method / operationId
 *  - 删除参数，或改变参数类型
 *  - 新增必填参数，或 requestBody 由可选变必填
 *  - 删除响应字段（components.schemas 属性减少）
 *
 * 用法：
 *   node tool/check/openapi-diff.js            仅报告
 *   node tool/check/openapi-diff.js --strict   有破坏性变更则退出码 1
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const root = path.join(__dirname, '..', '..');
const specPath = path.join(root, 'contracts', 'openapi.json');
const strict = process.argv.includes('--strict');
const METHODS = ['get', 'post', 'put', 'patch', 'delete'];

/** `--base <rev>`：CI 里传 origin/main；本地默认 HEAD（对比上次提交） */
const args = process.argv.slice(2);
const baseIdx = args.indexOf('--base');
const baseRev = baseIdx >= 0 && args[baseIdx + 1] ? args[baseIdx + 1] : 'HEAD';

function loadBase() {
  const r = spawnSync('git', ['show', `${baseRev}:contracts/openapi.json`], {
    cwd: root,
    encoding: 'utf-8',
  });
  if (r.status !== 0) return null;
  try {
    return JSON.parse(r.stdout);
  } catch {
    return null;
  }
}

const current = JSON.parse(fs.readFileSync(specPath, 'utf-8'));
const base = loadBase();

if (!base) {
  console.log('[openapi-diff] 无基线（HEAD 中不存在 openapi.json），跳过');
  process.exit(0);
}

const breaking = [];
const additive = [];

function opOf(spec, p, m) {
  return (spec.paths && spec.paths[p] && spec.paths[p][m]) || null;
}

for (const p of Object.keys(base.paths || {})) {
  for (const m of METHODS) {
    const oldOp = opOf(base, p, m);
    if (!oldOp) continue;

    const newOp = opOf(current, p, m);
    if (!newOp) {
      breaking.push(`removed ${m.toUpperCase()} ${p}`);
      continue;
    }

    if (oldOp.operationId && oldOp.operationId !== newOp.operationId) {
      breaking.push(
        `renamed operationId ${m.toUpperCase()} ${p}: ${oldOp.operationId} → ${newOp.operationId}`,
      );
    }

    const oldParams = oldOp.parameters || [];
    const newParams = newOp.parameters || [];
    for (const op of oldParams) {
      const np = newParams.find((x) => x.name === op.name && x.in === op.in);
      if (!np) {
        breaking.push(`removed parameter ${m.toUpperCase()} ${p}: ${op.in}.${op.name}`);
        continue;
      }
      if (JSON.stringify(np.schema) !== JSON.stringify(op.schema)) {
        breaking.push(`changed parameter schema ${m.toUpperCase()} ${p}: ${op.in}.${op.name}`);
      }
      if (op.required !== true && np.required === true) {
        breaking.push(`parameter became required ${m.toUpperCase()} ${p}: ${op.in}.${op.name}`);
      }
    }
    for (const np of newParams) {
      if (!np.required) continue;
      if (!oldParams.some((x) => x.name === np.name && x.in === np.in)) {
        breaking.push(`added required parameter ${m.toUpperCase()} ${p}: ${np.in}.${np.name}`);
      }
    }

    const oldBody = oldOp.requestBody && oldOp.requestBody.required;
    const newBody = newOp.requestBody && newOp.requestBody.required;
    if (!oldBody && newBody) breaking.push(`requestBody became required ${m.toUpperCase()} ${p}`);

    const oldCode = Object.keys(oldOp.responses || {});
    for (const code of oldCode) {
      if (!newOp.responses || !newOp.responses[code]) {
        breaking.push(`removed response ${code} for ${m.toUpperCase()} ${p}`);
      }
    }

    if (!oldOp.operationId && newOp.operationId) {
      additive.push(`added operationId ${m.toUpperCase()} ${p}: ${newOp.operationId}`);
    }
  }
}

for (const p of Object.keys(current.paths || {})) {
  for (const m of METHODS) {
    if (current.paths[p][m] && !opOf(base, p, m)) additive.push(`added ${m.toUpperCase()} ${p}`);
  }
}

// 响应模型属性减少 → 破坏性（客户端会缺字段）
const oldSchemas = (base.components && base.components.schemas) || {};
const newSchemas = (current.components && current.components.schemas) || {};
for (const [name, oldSchema] of Object.entries(oldSchemas)) {
  const newSchema = newSchemas[name];
  if (!newSchema) {
    breaking.push(`removed schema ${name}`);
    continue;
  }
  for (const prop of Object.keys(oldSchema.properties || {})) {
    if (!newSchema.properties || !newSchema.properties[prop]) {
      breaking.push(`removed field ${name}.${prop}`);
    }
  }
}
for (const name of Object.keys(newSchemas)) {
  if (!oldSchemas[name]) additive.push(`added schema ${name}`);
}

for (const a of additive) console.log(`[openapi-diff] + ${a}`);
for (const b of breaking) console.log(`[openapi-diff] ! ${b}`);

if (breaking.length === 0) {
  console.log(`[openapi-diff] ok, breaking=0, additive=${additive.length}`);
  process.exit(0);
}

console.error(`[openapi-diff] 检测到 ${breaking.length} 处破坏性变更（客户端需同步升级）`);
process.exit(strict ? 1 : 0);
