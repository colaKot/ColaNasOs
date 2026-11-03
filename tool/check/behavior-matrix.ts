/**
 * X-03 覆盖矩阵：从 `tool/behavior/*.cases.ts`（编译产物 `dist/tool/behavior/*.cases.js`）
 * 统计「域 × 四角色」的覆盖情况，生成 `docs/behavior-覆盖矩阵.md`；
 * `--check` 校验文件是否过期（已接入 verify）。
 *
 * 角色归属：用例上显式写了 `roles` 就用它；没写按 id 里的关键词推断：
 *   anonymous / reader / cross-user|cross_user|other-user|isolated|per-user
 * 都匹配不到算 `writer`（写权限用户的正常业务路径）。
 *
 * 跨用户角色只对「按用户隔离的资源」有意义：域声明 `shared: true`（账号、挂载、订阅、
 * 备份、分享链接、同步任务、监控、Webhook 等全局资源）时，跨用户列显示「不适用」，
 * 不计入缺口。
 *
 * 为什么直接 require 编译产物而不是正则扫源码：用例里 payload 也含 `id` 字段
 * （如 `{ id: 'vault1' }`），正则会把数据当成用例。
 *
 * 用法：
 *   npm run build && npm run behavior:matrix    # 生成 / 更新矩阵
 *   npm run behavior:matrix.check               # 只校验是否过期
 */
import fs from 'node:fs';
import path from 'node:path';

/** 四角色（与 behavior-types.ts 的 BehaviorRole 一致；本脚本不引运行时依赖） */
type Role = 'anonymous' | 'reader' | 'writer' | 'crossUser';

const ROLES: Role[] = ['anonymous', 'reader', 'writer', 'crossUser'];
const ROLE_LABEL: Record<Role, string> = {
  anonymous: '匿名',
  reader: '只读',
  writer: '写者',
  crossUser: '跨用户',
};

function findRoot(from: string): string {
  let cur = from;
  for (let i = 0; i < 6; i += 1) {
    if (fs.existsSync(path.join(cur, 'package.json'))) return cur;
    const parent = path.dirname(cur);
    if (parent === cur) break;
    cur = parent;
  }
  return from;
}

const ROOT = findRoot(__dirname);
const CASES_DIR = path.join(ROOT, 'dist', 'tool', 'behavior');
const OUT_FILE = path.join(ROOT, 'docs', 'behavior-覆盖矩阵.md');

interface LoadedCase {
  id: string;
  roles: Role[];
  /** 角色是显式标注的还是按命名推断的 */
  explicit: boolean;
}

interface LoadedDomain {
  domain: string;
  /** 资源是否全局共享（跨用户角色不适用） */
  shared: boolean;
  cases: LoadedCase[];
}

interface LoadedModule {
  domain: string;
  shared?: boolean;
  cases: Array<{ id: string; name?: string; roles?: Role[] }>;
}

/** 按 id 推断角色 */
function inferRoles(id: string): Role[] {
  if (/anonymous/i.test(id)) return ['anonymous'];
  if (/reader/i.test(id)) return ['reader'];
  if (/cross[-_]user|other[-_]user|isolated|per[-_]user|owner[-_]only/i.test(id)) {
    return ['crossUser'];
  }
  return ['writer'];
}

function loadCases(): { domains: LoadedDomain[]; warnings: string[] } {
  if (!fs.existsSync(CASES_DIR)) {
    console.error('[behavior-matrix] 找不到 dist/tool/behavior，请先运行 npm run build');
    process.exit(2);
  }
  const files = fs
    .readdirSync(CASES_DIR)
    .filter((f) => f.endsWith('.cases.js'))
    .sort();

  const domains: LoadedDomain[] = [];
  const warnings: string[] = [];

  for (const file of files) {
    const mod = require(path.join(CASES_DIR, file)) as LoadedModule | { default: LoadedModule };
    const raw = (mod as { default?: LoadedModule }).default ?? (mod as LoadedModule);
    if (!raw || typeof raw.domain !== 'string' || !Array.isArray(raw.cases)) {
      warnings.push(`${file}: 导出结构不正确（需要 { domain, cases }），已跳过`);
      continue;
    }
    const cases: LoadedCase[] = raw.cases.map((c) => {
      const declared = Array.isArray(c.roles) ? c.roles : [];
      const invalid = declared.filter((r) => !ROLES.includes(r));
      if (invalid.length > 0)
        warnings.push(`${raw.domain} / ${c.id}: 未知角色 ${invalid.join(', ')}`);
      const valid = declared.filter((r) => ROLES.includes(r));
      return {
        id: c.id,
        roles: valid.length > 0 ? valid : inferRoles(c.id),
        explicit: valid.length > 0,
      };
    });
    domains.push({ domain: raw.domain, shared: raw.shared === true, cases });
  }

  domains.sort((a, b) => a.domain.localeCompare(b.domain));
  return { domains, warnings };
}

function build(): string {
  const { domains, warnings } = loadCases();

  const total: Record<Role, number> = { anonymous: 0, reader: 0, writer: 0, crossUser: 0 };
  let caseCount = 0;
  let sharedCount = 0;

  const lines = [
    '# 行为用例覆盖矩阵（X-03）',
    '',
    '> 由 `npm run behavior:matrix` 从 `tool/behavior/*.cases.ts`（编译产物）统计生成，**不要手改**；',
    '> `npm run behavior:matrix.check`（已进 `verify`）在文件过期时失败。',
    '>',
    '> 角色归属：用例显式写 `roles` 就用它，否则按 id 关键词推断 ——',
    '> `anonymous` → 匿名；`reader` → 只读；`cross-user|cross_user|other-user|isolated|per-user` → 跨用户；',
    '> 都匹配不到算「写者」（写权限用户的正常业务路径）。命名不规范时请在 case 上显式标注 `roles`。',
    '>',
    '> 「跨用户」只对**按用户隔离的资源**有意义。账号、挂载、RSS 订阅、备份、分享链接、同步任务、',
    '> 监控、Webhook 等是全局资源（域上标 `shared: true`），跨用户列显示「不适用」，不计入缺口。',
    '',
    '| 域 | 用例 | 资源 | 匿名 | 只读 | 写者 | 跨用户 | 缺口 |',
    '| --- | --- | --- | --- | --- | --- | --- | --- |',
  ];

  const gaps: string[] = [];
  const sharedDomains: string[] = [];

  for (const d of domains) {
    const counts: Record<Role, number> = { anonymous: 0, reader: 0, writer: 0, crossUser: 0 };
    for (const c of d.cases) {
      for (const r of c.roles) counts[r] += 1;
    }
    // 共享资源域：跨用户不适用，也不计入合计的跨用户数
    if (d.shared) sharedCount += 1;
    else total.crossUser += counts.crossUser;
    total.anonymous += counts.anonymous;
    total.reader += counts.reader;
    total.writer += counts.writer;
    caseCount += d.cases.length;

    const missing = (d.shared ? ROLES.filter((r) => r !== 'crossUser') : ROLES).filter(
      (r) => counts[r] === 0,
    );
    if (missing.length > 0) {
      gaps.push(`- \`${d.domain}\`：缺 ${missing.map((r) => ROLE_LABEL[r]).join(' / ')}`);
    }
    if (d.shared) sharedDomains.push(`\`${d.domain}\``);

    lines.push(
      `| ${d.domain} | ${d.cases.length} | ${d.shared ? '全局' : '按用户'} | ${counts.anonymous} | ${
        counts.reader
      } | ${counts.writer} | ${d.shared ? '不适用' : counts.crossUser} | ${
        missing.length === 0 ? '—' : missing.map((r) => ROLE_LABEL[r]).join(' / ')
      } |`,
    );
  }

  lines.push(
    `| **合计** | **${caseCount}** | ${domains.length - sharedCount} 按用户 / ${sharedCount} 全局 | ${total.anonymous} | ${total.reader} | ${total.writer} | ${total.crossUser} | ${
      gaps.length === 0 ? '无缺口' : `${gaps.length} 个域有缺口`
    } |`,
    '',
    '## 角色推断来源',
    '',
    '| 域 | 显式标注 | 按命名推断 |',
    '| --- | --- | --- |',
  );
  for (const d of domains) {
    const explicit = d.cases.filter((c) => c.explicit).length;
    lines.push(`| ${d.domain} | ${explicit} | ${d.cases.length - explicit} |`);
  }

  lines.push(
    '',
    '## 缺口（未覆盖的角色）',
    '',
    ...(gaps.length === 0 ? ['- 无：每个域都已覆盖适用的角色。'] : gaps),
    '',
    '## 全局资源域（跨用户不适用）',
    '',
    ...(sharedDomains.length === 0
      ? ['- 无。']
      : [
          `${sharedDomains.join('、')} 的资源是系统级共享数据（账号表、挂载配置、订阅、备份、分享链接、同步任务、进程与监控、Webhook），`,
          '不存在「他人资源」，因此不要求跨用户用例；这些域的越权语义由「只读 403」表达。',
        ]),
  );

  if (warnings.length > 0) {
    lines.push('', '## 标注告警', '', ...warnings.map((w) => `- ${w}`));
  }

  lines.push(
    '',
    '## 怎么补一个缺口',
    '',
    '1. 在对应 `tool/behavior/<domain>.cases.ts` 里加一条自包含 case；',
    "2. id 按 `场景.角色-预期` 命名（如 `library.cross-user-404`），或直接在 case 上写 `roles: ['crossUser']`；",
    '3. `npm run build && npm run behavior:matrix` 重生成矩阵，`npm run behavior` 确认全绿。',
    '',
  );

  return lines.join('\n');
}

const markdown = build();

if (process.argv.includes('--check')) {
  const current = fs.existsSync(OUT_FILE) ? fs.readFileSync(OUT_FILE, 'utf-8') : '';
  if (current !== markdown) {
    console.error(
      `[behavior-matrix] ${path.relative(ROOT, OUT_FILE)} 已过期，请运行 npm run behavior:matrix`,
    );
    process.exit(1);
  }
  console.log('[behavior-matrix] ok');
  process.exit(0);
}

fs.mkdirSync(path.dirname(OUT_FILE), { recursive: true });
fs.writeFileSync(OUT_FILE, markdown, 'utf-8');
console.log(`[behavior-matrix] wrote ${path.relative(ROOT, OUT_FILE)}`);
