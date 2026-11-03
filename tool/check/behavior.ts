/**
 * X-03 行为用例执行器：把领域用例写成「可读的 DSL」，统一启动内核、发放令牌、断言与报告。
 *
 * 用例位置：`tool/behavior/*.cases.ts`（编译后在 `dist/tool/behavior/*.cases.js`）。
 * 与 `tool/check/*-smoke.js` 的分工：
 *   - smoke：单个域的实现细节验收（协议、边界、性能），实现即断言
 *   - behavior：跨角色的业务行为（谁能做什么、越权会怎样），可读性优先
 *
 * 用法：
 *   npm run behavior                         # 全部域
 *   npm run behavior -- --domain=share       # 只跑一个域
 *   npm run behavior -- --domains=share,sync # 只跑多个域
 *   npm run behavior -- --jobs=3             # 域级并行（每域一个子进程）
 *   npm run behavior -- --id=password        # 按 id 子串过滤
 *   npm run behavior -- --json=report.json   # 输出 JSON 报告
 *
 * 注意：必须用 Electron 运行时（better-sqlite3 为 Electron ABI），脚本自动自举。
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn, spawnSync } from 'node:child_process';

/** 向上找到含 package.json 的仓库根（源码在 tool/check、编译后在 dist/tool/check，层级不同） */
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

// ---------------------------------------------------------------- 自举 Electron

if (!process.versions.electron) {
  const exe = path.join(
    ROOT,
    'node_modules',
    'electron',
    'dist',
    process.platform === 'win32' ? 'electron.exe' : 'electron',
  );
  if (!fs.existsSync(exe)) {
    console.error('[FATAL] 找不到 electron，请先 npm install');
    process.exit(2);
  }
  const r = spawnSync(exe, [__filename, ...process.argv.slice(2)], {
    stdio: 'inherit',
    env: Object.assign({}, process.env, { ELECTRON_RUN_AS_NODE: '1' }),
  });
  process.exit(typeof r.status === 'number' ? r.status : 1);
}

// ---------------------------------------------------------------- 类型

import type {
  BehaviorDomain,
  CaseContext,
  CaseResult,
  ResponseLike,
} from './behavior-types';

export type { BehaviorCase, BehaviorDomain, CaseContext } from './behavior-types';

// ---------------------------------------------------------------- 参数

const argv = process.argv.slice(2);
const option = (name: string): string | undefined => {
  const hit = argv.find((a) => a.startsWith(`--${name}=`));
  return hit ? hit.slice(name.length + 3) : undefined;
};
const onlyDomain = option('domain');
const onlyDomains = (option('domains') || onlyDomain || '')
  .split(',')
  .map((s) => s.trim())
  .filter(Boolean);
const onlyId = option('id');
const jobs = Math.max(1, Number(option('jobs') || 1));
const jsonOut = option('json');

// ---------------------------------------------------------------- 执行

function loadCases(): string[] {
  const dir = path.join(__dirname, '..', 'behavior');
  if (!fs.existsSync(dir)) return [];
  return fs
    .readdirSync(dir)
    .filter((f) => f.endsWith('.cases.js'))
    .map((f) => path.join(dir, f))
    .sort();
}

async function runDomain(file: string, results: CaseResult[]): Promise<void> {
  const mod = require(file) as BehaviorDomain | { default: BehaviorDomain };
  const domain = (mod as { default?: BehaviorDomain }).default ?? (mod as BehaviorDomain);
  if (!domain || !Array.isArray(domain.cases)) {
    results.push({ domain: path.basename(file), id: 'load', name: '加载用例', ok: false, ms: 0, error: '导出结构不正确（需要 { domain, cases }）' });
    return;
  }
  if (onlyDomains.length > 0 && !onlyDomains.includes(domain.domain)) return;

  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), `colanas-bhv-${domain.domain}-`));
  const dataDir = path.join(tmpDir, 'data');
  const filesRoot = path.join(tmpDir, 'files');
  fs.mkdirSync(dataDir, { recursive: true });
  fs.mkdirSync(filesRoot, { recursive: true });

  const extraEnv = domain.prepare ? await domain.prepare(tmpDir) : {};
  process.env.COLANAS_DEV_TOKEN = '1';
  process.env.COLANAS_JWT_SECRET = 'test-secret-0123456789abcdef';
  process.env.COLANAS_FILES_ROOT = filesRoot;
  Object.assign(process.env, extraEnv);

  const { startKernel } = require(path.join(ROOT, 'dist', 'kernel', 'index'));
  const k = await startKernel({ dataDir, port: 0, listen: false });
  const app = k.app;

  const tokenCache = new Map<string, Record<string, string>>();
  const ctx: CaseContext = {
    app,
    k,
    tmpDir,
    dataDir,
    filesRoot,
    async token(scopes, sub) {
      const key = `${sub || 'u1'}|${scopes.join(',')}`;
      const hit = tokenCache.get(key);
      if (hit) return hit;
      const res = (await app.inject({
        method: 'POST',
        url: '/api/v1/auth/dev-token',
        payload: { sub: sub || 'u1', scopes },
      })) as ResponseLike;
      const header = { authorization: `Bearer ${res.json().token || ''}` };
      tokenCache.set(key, header);
      return header;
    },
    request(method, url, opts = {}) {
      return app.inject({
        method,
        url,
        headers: Object.assign({}, opts.token || {}, opts.headers || {}),
        ...(opts.payload === undefined ? {} : { payload: opts.payload as never }),
      }) as Promise<ResponseLike>;
    },
    expect(condition, message) {
      if (!condition) throw new Error(message);
    },
    assertStatus(res, expected, label) {
      if (res.statusCode !== expected) {
        throw new Error(`${label ? label + '：' : ''}期望 ${expected}，实际 ${res.statusCode}（${String(res.body).slice(0, 120)}）`);
      }
    },
  };

  try {
    if (domain.setup) await domain.setup(ctx);
    for (const c of domain.cases) {
      if (onlyId && !c.id.includes(onlyId)) continue;
      const started = Date.now();
      try {
        await c.run(ctx);
        results.push({ domain: domain.domain, id: c.id, name: c.name, ok: true, ms: Date.now() - started });
      } catch (err) {
        results.push({
          domain: domain.domain,
          id: c.id,
          name: c.name,
          ok: false,
          ms: Date.now() - started,
          error: err instanceof Error ? err.message : String(err),
        });
      }
    }
    if (domain.teardown) await domain.teardown(ctx);
  } finally {
    await app.close();
    try { fs.rmSync(tmpDir, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 }); } catch { /* 日志句柄释放有延迟 */ }
  }
}

function domainNameOf(file: string): string {
  return path.basename(file).replace(/\.cases\.js$/, '');
}

/** 每个域一个子进程：内核、临时数据目录与环境变量天然隔离。 */
function runDomainInChild(name: string): Promise<CaseResult[]> {
  const tmp = path.join(
    os.tmpdir(),
    `colanas-bhv-${name}-${Date.now()}-${Math.random().toString(36).slice(2)}.json`,
  );
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [__filename, `--domain=${name}`, '--jobs=1', `--json=${tmp}`], {
      cwd: ROOT,
      env: { ...process.env, ELECTRON_RUN_AS_NODE: '1' },
      stdio: ['ignore', 'ignore', 'inherit'],
      windowsHide: true,
    });
    const fail = (reason: string) => {
      try { fs.rmSync(tmp, { force: true }); } catch { /* 清理失败不影响结果 */ }
      resolve([{ domain: name, id: 'run', name: '运行域用例', ok: false, ms: 0, error: reason }]);
    };
    child.on('error', (e) => fail(String(e)));
    child.on('close', (code) => {
      try {
        const report = JSON.parse(fs.readFileSync(tmp, 'utf8')) as { results?: CaseResult[] };
        fs.rmSync(tmp, { force: true });
        resolve(report.results || []);
      } catch {
        fail(`子进程退出 ${code}，未产出报告`);
      }
    });
  });
}

/** 域级并行，按 files 顺序收集结果，输出顺序与串行一致。 */
async function runParallel(files: string[], limit: number): Promise<CaseResult[]> {
  const buckets: CaseResult[][] = files.map(() => []);
  let cursor = 0;
  let active = 0;
  await new Promise<void>((resolve) => {
    const pump = () => {
      while (active < limit && cursor < files.length) {
        const index = cursor;
        const file = files[cursor++];
        active += 1;
        runDomainInChild(domainNameOf(file)).then((rows) => {
          buckets[index] = rows;
          active -= 1;
          pump();
        });
      }
      if (active === 0 && cursor >= files.length) resolve();
    };
    pump();
  });
  return buckets.flat();
}

(async () => {
  const startedAt = Date.now();
  const files = loadCases();
  if (files.length === 0) {
    console.error('[behavior] 没有找到用例，先运行 npm run build（用例编译到 dist/tool/behavior）');
    process.exit(2);
  }

  const results: CaseResult[] = [];
  // 并行模式下先按域名收敛待跑文件：否则 --domains=book 也会为 14 个域各起一个内核（白等启动）。
  const matched = onlyDomains.length ? files.filter((f) => onlyDomains.includes(domainNameOf(f))) : files;
  const runFiles = matched.length > 0 ? matched : files;
  const parallel = jobs > 1 && runFiles.length > 1 && !onlyId;
  if (parallel) {
    results.push(...(await runParallel(runFiles, jobs)));
  } else {
    for (const file of runFiles) {
      await runDomain(file, results);
    }
  }

  let failed = 0;
  for (const r of results) {
    if (r.ok) {
      console.log(`[OK]   ${`${r.domain}.${r.id}`.padEnd(44)} ${String(r.ms).padStart(5)} ms`);
    } else {
      failed += 1;
      console.log(`[FAIL] ${`${r.domain}.${r.id}`.padEnd(44)} ${String(r.ms).padStart(5)} ms  ${r.error || ''}`);
    }
  }

  const summary = { total: results.length, passed: results.length - failed, failed };
  const elapsed = ((Date.now() - startedAt) / 1000).toFixed(1);
  console.log(
    `\n[behavior] ${summary.passed}/${summary.total} passed${failed ? `, ${failed} failed` : ''}` +
      `（jobs=${parallel ? jobs : 1}, ${elapsed}s）`,
  );

  if (jsonOut) {
    fs.writeFileSync(
      path.resolve(jsonOut),
      JSON.stringify({ generatedAt: new Date().toISOString(), ...summary, results }, null, 2),
      'utf-8',
    );
    console.log(`[behavior] 报告写入 ${jsonOut}`);
  }

  process.exit(failed ? 1 : 0);
})().catch((e) => {
  console.error('[FATAL]', e);
  process.exit(1);
});