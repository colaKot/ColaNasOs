#!/usr/bin/env node
/**
 * 错误码生成器：`contracts/errors.json` → `kernel/errors.ts`。
 *
 * 约定（docs/10-DoD §2「错误码」）：代码里一律写 `Err.badRequest`，不写裸字符串。
 * 这样新增 / 改名错误码会先在契约里出现，`npm run gen:errors.check` 与 `npm run errors.check`
 * 才能挡住「代码用了契约里没有的码」。
 *
 * 用法：
 *   node tool/gen-errors.js            生成
 *   node tool/gen-errors.js --check    校验磁盘与契约一致（CI 用）
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..');
const specPath = path.join(root, 'contracts', 'errors.json');
const outPath = path.join(root, 'kernel', 'errors.ts');

function build() {
  const spec = JSON.parse(fs.readFileSync(specPath, 'utf-8'));
  const codes = Object.keys(spec.codes || {});
  if (codes.length === 0) throw new Error('contracts/errors.json has no codes');

  const lines = [
    '// AUTO-GENERATED. DO NOT EDIT.',
    '// source: contracts/errors.json',
    '// regenerate: npm run gen:errors',
    '',
    '/** 统一错误码：值就是 API 返回里的 `error` 字段（与旧版裸字符串完全兼容） */',
    'export const Err = {',
    ...codes.map((c) => `  ${c}: '${c}',`),
    '} as const;',
    '',
    'export type ErrorCode = keyof typeof Err;',
    '',
    '/** 每个错误码的默认 HTTP 状态（业务可用 `reply.code()` 覆盖） */',
    'export const ERROR_STATUS: Record<ErrorCode, number> = {',
    ...codes.map((c) => `  ${c}: ${Number(spec.codes[c].status) || 500},`),
    '};',
    '',
    '/** 默认文案（中文；客户端可本地化） */',
    'export const ERROR_MESSAGE: Record<ErrorCode, string> = {',
    ...codes.map((c) => `  ${c}: ${JSON.stringify(String(spec.codes[c].message || c))},`),
    '};',
    '',
  ];
  return { text: lines.join('\n'), codes };
}

function main() {
  const { text, codes } = build();
  const checkOnly = process.argv.includes('--check');

  if (checkOnly) {
    const prev = fs.existsSync(outPath) ? fs.readFileSync(outPath, 'utf-8') : '';
    if (prev !== text) {
      console.error(`[gen:errors.check] kernel/errors.ts 已过期（codes=${codes.length}），请运行 npm run gen:errors`);
      process.exit(1);
    }
    console.log(`[gen:errors.check] ok, codes=${codes.length}`);
    return;
  }

  fs.mkdirSync(path.dirname(outPath), { recursive: true });
  fs.writeFileSync(outPath, text, 'utf-8');
  console.log(`[gen:errors] wrote ${outPath} codes=${codes.length}`);
}

if (require.main === module) main();

module.exports = { build };