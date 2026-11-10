#!/usr/bin/env node
/**
 * 权限域清单对账：客户端「新建账号」里能勾的域，必须等于服务端真实存在的域。
 *
 * 为什么要这个检查：权限选择器是**按域硬编码**的（`scope_picker.dart` 的 `kScopeDomains`）。
 * 新加一个模块时只写了服务端 `secured('cool:read', …)` 而忘了加进客户端清单，
 * 界面上就永远勾不到这个模块的权限 —— 不报错、不崩溃，管理员只会觉得「这个模块没法授权」，
 * 排查成本极高。反过来，删了模块但清单没删，界面上会留一个勾了也不生效的幽灵项。
 *
 *   node tool/check/scope-catalog.js
 *   node tool/check/scope-catalog.js --json
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.join(__dirname, '..', '..');
const CLIENT = 'apps/colanas_os/lib/features/accounts/scope_picker.dart';

/** 从 `secured('<scope>'` 调用里抽所有 scope 字面量 */
function serverScopes() {
  const dir = path.join(ROOT, 'src', 'modules');
  const out = new Set();
  const walk = (d) => {
    for (const f of fs.readdirSync(d)) {
      const p = path.join(d, f);
      if (fs.statSync(p).isDirectory()) {
        walk(p);
        continue;
      }
      if (!f.endsWith('.ts')) continue;
      const txt = fs.readFileSync(p, 'utf8');
      for (const m of txt.matchAll(/secured\(\s*'([^']+)'/g)) out.add(m[1]);
    }
  };
  walk(dir);
  return out;
}

/** 客户端 `kScopeDomains` 里的域 */
function clientDomains() {
  const p = path.join(ROOT, CLIENT);
  if (!fs.existsSync(p)) return null;
  const txt = fs.readFileSync(p, 'utf8');
  const block = txt.match(/kScopeDomains\s*=\s*<String>\[([\s\S]*?)\]/);
  if (!block) return null;
  return new Set([...block[1].matchAll(/'([^']+)'/g)].map((m) => m[1]));
}

const server = serverScopes();
const serverDomains = new Set([...server].map((s) => s.split(':')[0]));
const client = clientDomains();

if (client === null) {
  console.error(`[FAIL] 读不到 ${CLIENT} 里的 kScopeDomains`);
  process.exit(1);
}

const missingInClient = [...serverDomains].filter((d) => !client.has(d)).sort();
const ghostInClient = [...client].filter((d) => !serverDomains.has(d)).sort();
// 域存在但动作不是成套的（只有 read 没有 write，或反之）也值得提醒
const oddActions = [...server]
  .map((s) => s.split(':'))
  .filter(([, a]) => a !== 'read' && a !== 'write')
  .map(([d, a]) => `${d}:${a}`)
  .sort();

const ok = missingInClient.length === 0 && ghostInClient.length === 0;

if (process.argv.includes('--json')) {
  console.log(
    JSON.stringify(
      {
        ok,
        serverCount: serverDomains.size,
        clientCount: client.size,
        missingInClient,
        ghostInClient,
        oddActions,
      },
      null,
      2,
    ),
  );
} else {
  console.log(`服务端权限域 ${serverDomains.size} 个：${[...serverDomains].sort().join(' ')}`);
  console.log(`客户端清单 ${client.size} 个：${[...client].sort().join(' ')}`);
  if (missingInClient.length) {
    console.log(`[FAIL] 服务端有、客户端勾不到：${missingInClient.join(', ')}`);
  }
  if (ghostInClient.length) {
    console.log(`[FAIL] 客户端有、服务端已没有：${ghostInClient.join(', ')}`);
  }
  if (oddActions.length) {
    console.log(`[WARN] 非 read/write 的动作（确认界面是否需要单独暴露）：${oddActions.join(', ')}`);
  }
  console.log(ok ? '[OK]   权限域清单一致' : '[FAIL] 权限域清单不一致');
}

process.exit(ok ? 0 : 1);
