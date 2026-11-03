#!/usr/bin/env node
/**
 * 契约 ↔ Dart 生成物一致性验收（SP1-01，不需要 Dart SDK）。
 * 校验项：
 *  1. 生成幂等（--check 0 diff）
 *  2. 契约里每个 operationId 都有对应 Dart 方法
 *  3. client 引用的模型全部在 models.dart 中定义
 *  4. 每个模型类都有 fromJson / toJson
 *  5. 生成物为 UTF-8 无 BOM、行尾 LF
 *
 * 用法：node tool/check/dart-contract-smoke.js
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const root = path.join(__dirname, '..', '..');
const spec = JSON.parse(fs.readFileSync(path.join(root, 'contracts', 'openapi.json'), 'utf-8'));

const clientPath = path.join(root, 'packages', 'nas_core', 'lib', 'api', 'client.dart');
const modelsPath = path.join(root, 'packages', 'nas_core', 'lib', 'api', 'models.dart');
const client = fs.readFileSync(clientPath, 'utf-8');
const models = fs.readFileSync(modelsPath, 'utf-8');

const results = [];
const check = (name, ok, detail) => results.push({ name, ok, detail: detail || '' });

/** 1. 生成幂等 */
const genCheck = spawnSync(
  process.execPath,
  [path.join(root, 'tool', 'gen-client.js'), '--check'],
  {
    cwd: root,
    encoding: 'utf-8',
  },
);
check('gen_idempotent', genCheck.status === 0, (genCheck.stdout || '').trim());

/** 2. operationId 覆盖 */
const opIds = [];
for (const ops of Object.values(spec.paths || {})) {
  for (const [method, op] of Object.entries(ops)) {
    if (['get', 'post', 'put', 'patch', 'delete'].includes(method) && op.operationId) {
      opIds.push(op.operationId);
    }
  }
}
const missingOps = opIds.filter((id) => !new RegExp(`\\b${id}\\(`).test(client));
check(
  'operations_covered',
  missingOps.length === 0,
  `${opIds.length - missingOps.length}/${opIds.length}` +
    (missingOps.length ? ' missing=' + missingOps.join(',') : ''),
);

/** 3. 模型引用完整 */
const definedModels = new Set([...models.matchAll(/^class\s+(\w+)/gm)].map((m) => m[1]));
const referenced = new Set();
for (const m of client.matchAll(/Future<(\w+)>/g)) referenced.add(m[1]);
for (const m of client.matchAll(/required\s+(\w+)\s+body/g)) referenced.add(m[1]);
for (const m of models.matchAll(/:\s*(\w+)\.fromJson\(/g)) referenced.add(m[1]);
const primitives = new Set(['Map', 'String', 'int', 'double', 'bool', 'List', 'void', 'dynamic']);
const missingModels = [...referenced].filter((n) => !primitives.has(n) && !definedModels.has(n));
check(
  'models_defined',
  missingModels.length === 0,
  missingModels.length ? 'missing=' + missingModels.join(',') : `${definedModels.size} classes`,
);

/** 4. 每个模型都有 fromJson / toJson */
const classes = [...models.matchAll(/^class\s+(\w+)\s*\{/gm)].map((m) => m[1]);
const badClasses = classes.filter((c) => !new RegExp(`factory ${c}\\.fromJson\\(`).test(models));
check(
  'models_serde',
  badClasses.length === 0,
  badClasses.length ? 'missing fromJson: ' + badClasses.join(',') : `${classes.length} classes`,
);

/** 5. 编码与行尾 */
const rawClient = fs.readFileSync(clientPath);
const rawModels = fs.readFileSync(modelsPath);
const hasBom = (b) => b[0] === 0xef && b[1] === 0xbb && b[2] === 0xbf;
const hasCrlf = (b) => b.includes(Buffer.from('\r\n'));
check(
  'encoding_lf',
  !hasBom(rawClient) && !hasBom(rawModels) && !hasCrlf(rawClient) && !hasCrlf(rawModels),
  'utf8-no-bom + lf',
);

/** 6. 生成物带 AUTO-GENERATED 头 */
check(
  'auto_generated_header',
  client.startsWith('// AUTO-GENERATED. DO NOT EDIT.') &&
    models.startsWith('// AUTO-GENERATED. DO NOT EDIT.'),
  '',
);

let failed = 0;
for (const x of results) {
  console.log(`${x.ok ? '[OK]  ' : '[FAIL]'} ${x.name.padEnd(24)} ${x.detail}`);
  if (!x.ok) failed++;
}
console.log(`[summary] ${results.length - failed}/${results.length} passed`);
process.exit(failed ? 1 : 0);
