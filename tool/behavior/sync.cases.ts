import fs from 'node:fs';
import path from 'node:path';
import type { BehaviorDomain, CaseContext } from '../check/behavior-types';

/**
 * sync 域行为用例：同步方向、越界防护、冲突产生与裁决。
 * prepare 构造 a/x.txt（源内容）与 b/x.txt（目标不同内容），用于制造冲突。
 */
const OWNER = ['sync:read', 'sync:write', 'files:read', 'files:write'];

async function prepareFolders(ctx: CaseContext): Promise<void> {
  const a = path.join(ctx.filesRoot, 'a');
  const b = path.join(ctx.filesRoot, 'b');
  fs.mkdirSync(a, { recursive: true });
  fs.mkdirSync(b, { recursive: true });
  fs.writeFileSync(path.join(a, 'x.txt'), 'v1 from source');
  fs.writeFileSync(path.join(b, 'x.txt'), 'v2 target local');
}

const domain: BehaviorDomain = {
  domain: 'sync',
  // 同步任务与冲突表不含 owner（sync_jobs / sync_conflicts），全局资源 → 跨用户不适用
  shared: true,
  cases: [
    {
      id: 'diff.anonymous-401',
      name: '匿名用户不能查看差异',
      async run(ctx) {
        const res = await ctx.request('GET', '/api/v1/sync/diff?source=a&target=b');
        ctx.assertStatus(res, 401, '匿名差异');
      },
    },
    {
      id: 'run.escape-400',
      name: '越界目录不能同步',
      async run(ctx) {
        const owner = await ctx.token(OWNER);
        const res = await ctx.request('POST', '/api/v1/sync/run', {
          token: owner,
          payload: { source: '../../../etc', target: 'b' },
        });
        ctx.assertStatus(res, 400, '越界同步');
      },
    },
    {
      id: 'run.overwrite-copies',
      name: 'overwrite 策略把源内容覆盖到目标',
      async run(ctx) {
        await prepareFolders(ctx);
        const owner = await ctx.token(OWNER);
        const res = await ctx.request('POST', '/api/v1/sync/run', {
          token: owner,
          payload: { source: 'a', target: 'b', policy: 'overwrite' },
        });
        ctx.assertStatus(res, 200, '同步');
        const body = res.json() as { copied: number };
        ctx.expect(body.copied >= 1, '至少复制 1 个文件');
        const content = fs.readFileSync(path.join(ctx.filesRoot, 'b', 'x.txt'), 'utf8');
        ctx.expect(content === 'v1 from source', '目标内容被源覆盖');
      },
    },
    {
      id: 'conflict.skip-and-resolve',
      name: 'skip 策略产生冲突，裁决后可收敛',
      async run(ctx) {
        await prepareFolders(ctx);
        const owner = await ctx.token(OWNER);
        const run = await ctx.request('POST', '/api/v1/sync/run', {
          token: owner,
          payload: { source: 'a', target: 'b', policy: 'skip' },
        });
        ctx.assertStatus(run, 200, '同步');
        const job = run.json() as { id: string; conflicts: number };
        ctx.expect(job.conflicts >= 1, '任务记录冲突数');

        const conflicts = await ctx.request(
          'GET',
          `/api/v1/sync/conflicts?jobId=${encodeURIComponent(job.id)}`,
          { token: owner },
        );
        ctx.assertStatus(conflicts, 200, '冲突列表');
        const list = conflicts.json().items as Array<{ id: string; resolved: number }>;
        ctx.expect(list.length >= 1, '至少 1 个冲突');

        const resolve = await ctx.request('POST', '/api/v1/sync/conflicts/resolve', {
          token: owner,
          payload: { id: list[0].id, action: 'source' },
        });
        ctx.assertStatus(resolve, 200, '裁决');

        const after = await ctx.request(
          'GET',
          `/api/v1/sync/conflicts?jobId=${encodeURIComponent(job.id)}`,
          { token: owner },
        );
        const rows = after.json().items as Array<{ resolved: boolean | number; resolution: string | null }>;
        ctx.expect(
          rows.some((x) => Boolean(x.resolved) && x.resolution === 'source'),
          '冲突已裁决为 source',
        );
      },
    },
    {
      id: 'run.reader-403',
      name: '只读用户不能触发同步',
      async run(ctx) {
        await prepareFolders(ctx);
        const reader = await ctx.token(['sync:read', 'files:read']);
        const denied = await ctx.request('POST', '/api/v1/sync/run', {
          token: reader,
          payload: { source: 'a', target: 'b' },
        });
        ctx.assertStatus(denied, 403, '只读触发同步');
      },
    },
  ],
};

export default domain;