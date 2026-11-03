import type { BehaviorDomain, CaseContext } from '../check/behavior-types';

/**
 * notes 域行为用例：创建权限、版本历史与恢复、用户隔离、软删除。
 */
const OWNER = ['notes:read', 'notes:write'];

async function createNote(ctx: CaseContext): Promise<string> {
  const owner = await ctx.token(OWNER);
  const res = await ctx.request('POST', '/api/v1/notes/create', {
    token: owner,
    payload: { title: 'Alpha Note', body: 'v1 body', tags: ['x'] },
  });
  ctx.assertStatus(res, 200, '创建笔记');
  return res.json().id as string;
}

const domain: BehaviorDomain = {
  domain: 'notes',
  cases: [
    {
      id: 'create.anonymous-401',
      name: '匿名用户不能创建笔记',
      async run(ctx) {
        const res = await ctx.request('POST', '/api/v1/notes/create', {
          payload: { title: 'x', body: 'y' },
        });
        ctx.assertStatus(res, 401, '匿名创建');
      },
    },
    {
      id: 'create.reader-403',
      name: '只读用户不能创建笔记',
      async run(ctx) {
        const reader = await ctx.token(['notes:read']);
        const res = await ctx.request('POST', '/api/v1/notes/create', {
          token: reader,
          payload: { title: 'x', body: 'y' },
        });
        ctx.assertStatus(res, 403, '只读创建');
      },
    },
    {
      id: 'create-and-get',
      name: '创建后可读回内容',
      async run(ctx) {
        const id = await createNote(ctx);
        const owner = await ctx.token(OWNER);
        const res = await ctx.request('GET', `/api/v1/notes/get?id=${encodeURIComponent(id)}`, {
          token: owner,
        });
        ctx.assertStatus(res, 200, '详情');
        ctx.expect(res.json().title === 'Alpha Note', '标题一致');
        ctx.expect(res.json().body === 'v1 body', '内容一致');
      },
    },
    {
      id: 'update.version-history',
      name: '更新写入历史版本，且可恢复',
      async run(ctx) {
        const id = await createNote(ctx);
        const owner = await ctx.token(OWNER);
        const updated = await ctx.request('POST', '/api/v1/notes/update', {
          token: owner,
          payload: { id, body: 'v2 body' },
        });
        ctx.assertStatus(updated, 200, '更新');

        const versions = await ctx.request(
          'GET',
          `/api/v1/notes/versions?id=${encodeURIComponent(id)}`,
          { token: owner },
        );
        ctx.assertStatus(versions, 200, '版本历史');
        const rows = versions.json().items as Array<{ id: string; body: string }>;
        ctx.expect(rows.length >= 1, '至少 1 个历史版本');
        ctx.expect(rows.some((v) => v.body === 'v1 body'), '含 v1 历史');

        const target = rows.find((v) => v.body === 'v1 body');
        const restored = await ctx.request('POST', '/api/v1/notes/restore', {
          token: owner,
          payload: { id, versionId: target?.id },
        });
        ctx.assertStatus(restored, 200, '恢复');

        const after = await ctx.request('GET', `/api/v1/notes/get?id=${encodeURIComponent(id)}`, {
          token: owner,
        });
        ctx.expect(after.json().body === 'v1 body', '恢复后回到 v1');
      },
    },
    {
      id: 'other-user-404',
      name: '笔记按用户隔离',
      async run(ctx) {
        const id = await createNote(ctx);
        const other = await ctx.token(['notes:read', 'notes:write'], 'u3');
        const res = await ctx.request('GET', `/api/v1/notes/get?id=${encodeURIComponent(id)}`, {
          token: other,
        });
        ctx.assertStatus(res, 404, '他人笔记');
      },
    },
    {
      id: 'remove.soft-delete',
      name: '删除后列表与详情都不可见',
      async run(ctx) {
        const id = await createNote(ctx);
        const owner = await ctx.token(OWNER);
        const removed = await ctx.request('POST', '/api/v1/notes/remove', {
          token: owner,
          payload: { id },
        });
        ctx.assertStatus(removed, 200, '删除');

        const list = await ctx.request('GET', '/api/v1/notes?limit=100', { token: owner });
        const items = list.json().items as Array<{ id: string }>;
        ctx.expect(!items.some((x) => x.id === id), '列表不含');
        const get = await ctx.request('GET', `/api/v1/notes/get?id=${encodeURIComponent(id)}`, {
          token: owner,
        });
        ctx.assertStatus(get, 404, '详情 404');
      },
    },
  ],
};

export default domain;