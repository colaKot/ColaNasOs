import type { BehaviorDomain, CaseContext } from '../check/behavior-types';

/**
 * system 域行为用例：监控/进程只读可见、写权限才能终止进程、拒绝危险 pid。
 */
const domain: BehaviorDomain = {
  domain: 'system',
  // 进程与监控是整机资源，没有「他人进程」语义，跨用户角色不适用
  shared: true,
  cases: [
    {
      id: 'monitor.anonymous-401',
      name: '匿名用户不能读取系统监控',
      async run(ctx) {
        const res = await ctx.request('GET', '/api/v1/system/monitor');
        ctx.assertStatus(res, 401, '匿名监控');
      },
    },
    {
      id: 'monitor.reader-200',
      name: '只读用户可读取监控指标',
      async run(ctx) {
        const reader = await ctx.token(['system:read']);
        const res = await ctx.request('GET', '/api/v1/system/monitor', { token: reader });
        ctx.assertStatus(res, 200, '监控');
        const body = res.json() as Record<string, unknown>;
        ctx.expect('memory' in body || 'cpu' in body, '返回 CPU / 内存字段');
        ctx.expect(Number(body.uptimeSec ?? 0) > 0, '返回运行时长 uptimeSec');
      },
    },
    {
      id: 'processes.list.reader-200',
      name: '只读用户可列出进程',
      async run(ctx) {
        const reader = await ctx.token(['system:read']);
        const res = await ctx.request('GET', '/api/v1/system/processes?limit=10', { token: reader });
        ctx.assertStatus(res, 200, '进程列表');
        const items = res.json().items as Array<{ pid: number }>;
        ctx.expect(Array.isArray(items), 'items 是数组');
        ctx.expect(items.length >= 1, '至少 1 个进程');
      },
    },
    {
      id: 'processes.kill.reader-403',
      name: '只读用户不能终止进程',
      async run(ctx) {
        const reader = await ctx.token(['system:read']);
        const res = await ctx.request('POST', '/api/v1/system/processes/kill', {
          token: reader,
          payload: { pid: 4 },
        });
        ctx.assertStatus(res, 403, '只读终止');
      },
    },
    {
      id: 'processes.kill.protected-pid-400',
      name: '受保护 pid（≤4）拒绝终止',
      async run(ctx) {
        const admin = await ctx.token(['system:read', 'system:write']);
        const res = await ctx.request('POST', '/api/v1/system/processes/kill', {
          token: admin,
          payload: { pid: 4 },
        });
        ctx.assertStatus(res, 400, '受保护 pid');
      },
    },
  ],
};

export default domain;