import fs from 'node:fs';
import path from 'node:path';
import type { BehaviorDomain, CaseContext } from '../check/behavior-types';

/**
 * book 域行为用例：库权限、扫描、收藏与进度的用户隔离、阅读直链、无封面降级。
 */
const OWNER = ['book:read', 'book:write', 'files:read'];
let libId = '';

async function ensureLibrary(ctx: CaseContext): Promise<string> {
  if (libId) return libId;
  const owner = await ctx.token(OWNER);
  const list = await ctx.request('GET', '/api/v1/book/libraries', { token: owner });
  ctx.assertStatus(list, 200, '库列表');
  const existing = (list.json().items as Array<{ id: string; path: string }>).find(
    (x) => x.path === 'books',
  );
  if (existing) {
    libId = existing.id;
    return libId;
  }
  const res = await ctx.request('POST', '/api/v1/book/libraries', {
    token: owner,
    payload: { name: 'Shelf', path: 'books' },
  });
  ctx.assertStatus(res, 200, '建库');
  libId = res.json().id as string;
  return libId;
}

async function ensureScanned(ctx: CaseContext): Promise<void> {
  await ensureLibrary(ctx);
  const owner = await ctx.token(OWNER);
  const scan = await ctx.request('POST', '/api/v1/book/scan', { token: owner, payload: {} });
  ctx.assertStatus(scan, 200, '扫描');
}

async function firstBookId(ctx: CaseContext): Promise<string> {
  await ensureScanned(ctx);
  const owner = await ctx.token(OWNER);
  const list = await ctx.request('GET', '/api/v1/book/list?limit=10', { token: owner });
  ctx.assertStatus(list, 200, '书架');
  const items = list.json().items as Array<{ id: string }>;
  ctx.expect(items.length >= 1, '至少 1 本书');
  return items[0].id;
}

const domain: BehaviorDomain = {
  domain: 'book',
  async prepare(tmpDir) {
    const dir = path.join(tmpDir, 'files', 'books');
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, 'Alpha.txt'), 'alpha book content');
    fs.writeFileSync(path.join(dir, 'Beta.txt'), 'beta book content');
    return {};
  },
  cases: [
    {
      id: 'library.anonymous-401',
      name: '匿名用户不能查看书库',
      async run(ctx) {
        const res = await ctx.request('GET', '/api/v1/book/libraries');
        ctx.assertStatus(res, 401, '匿名书库');
      },
    },
    {
      id: 'library.reader-write-403',
      name: '只读用户不能新建书库',
      async run(ctx) {
        const reader = await ctx.token(['book:read']);
        const res = await ctx.request('POST', '/api/v1/book/libraries', {
          token: reader,
          payload: { name: 'X', path: 'books' },
        });
        ctx.assertStatus(res, 403, '只读建库');
      },
    },
    {
      id: 'scan.owner-200',
      name: '写权限用户可以扫描并入库',
      async run(ctx) {
        await ensureLibrary(ctx);
        const owner = await ctx.token(OWNER);
        const res = await ctx.request('POST', '/api/v1/book/scan', { token: owner, payload: {} });
        ctx.assertStatus(res, 200, '扫描');
        const body = res.json() as { books: number };
        ctx.expect(body.books >= 2, '至少 2 本');
      },
    },
    {
      id: 'favorite.isolated',
      name: '收藏按用户隔离',
      async run(ctx) {
        const bookId = await firstBookId(ctx);
        const owner = await ctx.token(OWNER);
        const add = await ctx.request('POST', '/api/v1/book/favorites/add', {
          token: owner,
          payload: { id: bookId },
        });
        ctx.assertStatus(add, 200, '收藏');

        const mine = await ctx.request('GET', '/api/v1/book/list?favorite=1', { token: owner });
        const other = await ctx.request('GET', '/api/v1/book/list?favorite=1', {
          token: await ctx.token(['book:read', 'book:write'], 'u3'),
        });
        ctx.expect((mine.json().items as unknown[]).length === 1, '本人 1 条收藏');
        ctx.expect((other.json().items as unknown[]).length === 0, '他人看不到');
      },
    },
    {
      id: 'progress.isolated',
      name: '阅读进度按用户隔离',
      async run(ctx) {
        const bookId = await firstBookId(ctx);
        const owner = await ctx.token(OWNER);
        const save = await ctx.request('POST', '/api/v1/book/progress/save', {
          token: owner,
          payload: { id: bookId, position: 'p42', percent: 42 },
        });
        ctx.assertStatus(save, 200, '保存进度');

        const mine = await ctx.request(
          'GET',
          `/api/v1/book/progress?id=${encodeURIComponent(bookId)}`,
          { token: owner },
        );
        const other = await ctx.request(
          'GET',
          `/api/v1/book/progress?id=${encodeURIComponent(bookId)}`,
          { token: await ctx.token(['book:read', 'book:write'], 'u3') },
        );
        ctx.expect(mine.json().percent === 42, '本人 42%');
        ctx.expect(other.json().percent === 0, '他人 0%');
      },
    },
    {
      id: 'file-url.playable',
      name: '阅读直链无需 Authorization 头',
      async run(ctx) {
        const bookId = await firstBookId(ctx);
        const owner = await ctx.token(OWNER);
        const url = await ctx.request('GET', `/api/v1/book/file-url?id=${encodeURIComponent(bookId)}`, {
          token: owner,
        });
        ctx.assertStatus(url, 200, '生成直链');
        const direct = await ctx.request('GET', url.json().url as string, {
          headers: { range: 'bytes=0-4' },
        });
        ctx.assertStatus(direct, 206, '直链读取');
      },
    },
    {
      id: 'cover.txt-404',
      name: 'txt 书没有封面时返回 404',
      async run(ctx) {
        const bookId = await firstBookId(ctx);
        const owner = await ctx.token(OWNER);
        const res = await ctx.request('GET', `/api/v1/book/cover?id=${encodeURIComponent(bookId)}`, {
          token: owner,
        });
        ctx.assertStatus(res, 404, '无封面');
      },
    },
    {
      id: 'organize.anonymous-401',
      name: '匿名用户不能查看合集与自定义列表',
      async run(ctx) {
        const cols = await ctx.request('GET', '/api/v1/book/collections');
        ctx.assertStatus(cols, 401, '匿名合集');
        const lists = await ctx.request('GET', '/api/v1/book/lists');
        ctx.assertStatus(lists, 401, '匿名列表');
      },
    },
    {
      id: 'organize.collection.reader-403',
      name: '只读用户不能设置合集',
      async run(ctx) {
        const bookId = await firstBookId(ctx);
        const reader = await ctx.token(['book:read']);
        const res = await ctx.request('POST', '/api/v1/book/collection', {
          token: reader,
          payload: { id: bookId, name: 'Series' },
        });
        ctx.assertStatus(res, 403, '只读设合集');
      },
    },
    {
      id: 'organize.archive.isolated',
      name: '归档按用户隔离，并支持按归档过滤',
      async run(ctx) {
        const bookId = await firstBookId(ctx);
        const owner = await ctx.token(OWNER);
        const other = await ctx.token(['book:read', 'book:write'], 'u4');

        const set = await ctx.request('POST', '/api/v1/book/archive', {
          token: owner,
          payload: { id: bookId },
        });
        ctx.assertStatus(set, 200, '归档');

        const mine = await ctx.request('GET', '/api/v1/book/list?archived=1', { token: owner });
        const theirs = await ctx.request('GET', '/api/v1/book/list?archived=1', { token: other });
        ctx.expect((mine.json().items as unknown[]).length === 1, '本人 1 条归档');
        ctx.expect((theirs.json().items as unknown[]).length === 0, '他人看不到');

        await ctx.request('POST', '/api/v1/book/archive', {
          token: owner,
          payload: { id: bookId, archived: false },
        });
      },
    },
    {
      id: 'organize.list.cross-user-404',
      name: '自定义列表跨用户不可见',
      async run(ctx) {
        const owner = await ctx.token(OWNER);
        const other = await ctx.token(['book:read', 'book:write'], 'u5');

        const created = await ctx.request('POST', '/api/v1/book/lists', {
          token: owner,
          payload: { name: 'Behavior list' },
        });
        ctx.assertStatus(created, 200, '建列表');
        const listId = created.json().id as string;

        const mine = await ctx.request(
          'GET',
          `/api/v1/book/lists/items?listId=${encodeURIComponent(listId)}`,
          { token: owner },
        );
        ctx.assertStatus(mine, 200, '本人读列表');

        const theirs = await ctx.request(
          'GET',
          `/api/v1/book/lists/items?listId=${encodeURIComponent(listId)}`,
          { token: other },
        );
        ctx.assertStatus(theirs, 404, '他人读列表');

        const remove = await ctx.request('POST', '/api/v1/book/lists/remove', {
          token: owner,
          payload: { id: listId },
        });
        ctx.assertStatus(remove, 200, '删除列表');
      },
    },
  ],
};

export default domain;