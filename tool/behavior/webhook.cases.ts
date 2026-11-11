import type { BehaviorDomain, CaseContext } from '../check/behavior-types';

/**
 * webhook 域行为用例：创建权限、secret 只返回一次、列表脱敏、删除。
 * 不触发真实投递（避免依赖外部 HTTP 端点），投递链路由 `smoke:webhook` 覆盖。
 */
const OWNER = ['system:read', 'system:write'];

async function createHook(ctx: CaseContext, name = 'Behavior Hook'): Promise<{ id: string; secret?: string }> {
  const owner = await ctx.token(OWNER);
  const res = await ctx.request('POST', '/api/v1/integration/webhooks', {
    token: owner,
    payload: {
      url: 'https://example.com/colanas-hook',
      events: ['task.done', 'file.changed'],
      secret: 'bhv-secret-0123456789',
      name,
    },
  });
  ctx.assertStatus(res, 200, '创建 webhook');
  return res.json() as { id: string; secret?: string };
}

const domain: BehaviorDomain = {
  domain: 'webhook',
  // Webhook 配置是全局资源（webhooks 无 owner 列），跨用户角色不适用
  shared: true,
  cases: [
    {
      id: 'create.anonymous-401',
      name: '匿名用户不能创建 webhook',
      async run(ctx) {
        const res = await ctx.request('POST', '/api/v1/integration/webhooks', {
          payload: { url: 'https://example.com/x', events: ['task.done'] },
        });
        ctx.assertStatus(res, 401, '匿名创建');
      },
    },
    {
      id: 'create.reader-403',
      name: '只读用户不能创建 webhook',
      async run(ctx) {
        const reader = await ctx.token(['system:read']);
        const res = await ctx.request('POST', '/api/v1/integration/webhooks', {
          token: reader,
          payload: { url: 'https://example.com/x', events: ['task.done'] },
        });
        ctx.assertStatus(res, 403, '只读创建');
      },
    },
    {
      id: 'create.secret-once',
      name: '创建时返回 secret，列表不回传明文',
      async run(ctx) {
        const created = await createHook(ctx);
        ctx.expect(!!created.id, '返回 id');
        ctx.expect(typeof created.secret === 'string' && created.secret.length >= 8, '创建时返回 secret');

        const owner = await ctx.token(OWNER);
        const list = await ctx.request('GET', '/api/v1/integration/webhooks', { token: owner });
        ctx.assertStatus(list, 200, '列表');
        const row = (list.json().items as Array<Record<string, unknown>>).find(
          (x) => x.id === created.id,
        );
        ctx.expect(!!row, '列表包含新建 webhook');
        ctx.expect(row?.secret !== created.secret, '列表不回传明文 secret');
        ctx.expect(Array.isArray(row?.events), '返回 events');
      },
    },
    {
      id: 'create.invalid-events-400',
      name: '缺少 events 时校验失败',
      async run(ctx) {
        const owner = await ctx.token(OWNER);
        const res = await ctx.request('POST', '/api/v1/integration/webhooks', {
          token: owner,
          payload: { url: 'https://example.com/x' },
        });
        ctx.assertStatus(res, 400, '缺少 events');
      },
    },
    {
      id: 'remove',
      name: '删除后列表不含',
      async run(ctx) {
        const created = await createHook(ctx);
        const owner = await ctx.token(OWNER);
        const removed = await ctx.request('POST', '/api/v1/integration/webhooks/remove', {
          token: owner,
          payload: { id: created.id },
        });
        ctx.assertStatus(removed, 200, '删除');

        const list = await ctx.request('GET', '/api/v1/integration/webhooks', { token: owner });
        ctx.expect(
          !(list.json().items as Array<{ id: string }>).some((x) => x.id === created.id),
          '列表已无该 webhook',
        );
      },
    },
  ],
};

export default domain;