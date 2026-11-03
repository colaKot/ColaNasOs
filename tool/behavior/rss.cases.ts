import type { BehaviorDomain, CaseContext } from '../check/behavior-types';

/**
 * rss 域行为用例：订阅权限、内联 XML 解析、条目读取、刷新与取消订阅。
 * 用内联 xml（不访问外网）保证可离线运行。
 */
const OWNER = ['rss:read', 'rss:write'];

const FEED_XML = `<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0">
  <channel>
    <title>Behavior Feed</title>
    <item><title>First Item</title><link>https://example.com/1</link><guid>bhv-1</guid><description>one</description></item>
    <item><title>Second Item</title><link>https://example.com/2</link><guid>bhv-2</guid><description>two</description></item>
  </channel>
</rss>`;

async function addFeed(ctx: CaseContext): Promise<string> {
  const owner = await ctx.token(OWNER);
  const res = await ctx.request('POST', '/api/v1/rss/feeds', {
    token: owner,
    payload: { xml: FEED_XML, title: 'Behavior Feed' },
  });
  ctx.assertStatus(res, 200, '添加订阅');
  return (res.json().id ?? res.json().feedId) as string;
}

const domain: BehaviorDomain = {
  domain: 'rss',
  // 订阅与条目是全局资源（rss_feeds 无 owner 列），跨用户角色不适用
  shared: true,
  cases: [
    {
      id: 'feeds.anonymous-401',
      name: '匿名用户不能查看订阅',
      async run(ctx) {
        const res = await ctx.request('GET', '/api/v1/rss/feeds');
        ctx.assertStatus(res, 401, '匿名订阅');
      },
    },
    {
      id: 'feeds.add.reader-403',
      name: '只读用户不能添加订阅',
      async run(ctx) {
        const reader = await ctx.token(['rss:read']);
        const res = await ctx.request('POST', '/api/v1/rss/feeds', {
          token: reader,
          payload: { xml: FEED_XML },
        });
        ctx.assertStatus(res, 403, '只读添加');
      },
    },
    {
      id: 'feeds.add-and-items',
      name: '内联 XML 可解析出条目',
      async run(ctx) {
        await addFeed(ctx);
        const owner = await ctx.token(OWNER);
        const items = await ctx.request('GET', '/api/v1/rss/items?limit=10', { token: owner });
        ctx.assertStatus(items, 200, '条目列表');
        const rows = items.json().items as Array<{ title: string; guid: string }>;
        ctx.expect(rows.length >= 2, '至少 2 条');
        ctx.expect(rows.some((x) => x.title === 'First Item'), '含 First Item');
        ctx.expect(rows.some((x) => x.guid === 'bhv-2'), 'guid 保留');
      },
    },
    {
      id: 'feeds.refresh-idempotent',
      name: '刷新幂等（同 guid 只入库一次）',
      async run(ctx) {
        const feedId = await addFeed(ctx);
        const owner = await ctx.token(OWNER);
        const refresh = await ctx.request('POST', '/api/v1/rss/feeds/refresh', {
          token: owner,
          payload: { id: feedId, xml: FEED_XML },
        });
        ctx.assertStatus(refresh, 200, '刷新');
        const body = refresh.json() as { added: number; skipped: number };
        ctx.expect(body.added === 0 && body.skipped >= 2, `应全部跳过（added=${body.added}, skipped=${body.skipped}）`);
      },
    },
    {
      id: 'feeds.refresh-requires-source',
      name: '既没有 url 也没有 xml 时刷新明确报错',
      async run(ctx) {
        await addFeed(ctx);
        const owner = await ctx.token(OWNER);
        const res = await ctx.request('POST', '/api/v1/rss/feeds/refresh', {
          token: owner,
          payload: {},
        });
        ctx.assertStatus(res, 400, '无数据源刷新');
      },
    },
    {
      id: 'feeds.remove',
      name: '取消订阅后列表与条目都消失',
      async run(ctx) {
        const feedId = await addFeed(ctx);
        const owner = await ctx.token(OWNER);
        const removed = await ctx.request('POST', '/api/v1/rss/feeds/remove', {
          token: owner,
          payload: { id: feedId },
        });
        ctx.assertStatus(removed, 200, '取消订阅');

        const feeds = await ctx.request('GET', '/api/v1/rss/feeds', { token: owner });
        const items = await ctx.request(
          'GET',
          `/api/v1/rss/items?feedId=${encodeURIComponent(feedId)}`,
          { token: owner },
        );
        ctx.expect(!(feeds.json().items as Array<{ id: string }>).some((x) => x.id === feedId), '订阅已移除');
        ctx.expect((items.json().items as unknown[]).length === 0, '条目不残留');
      },
    },
  ],
};

export default domain;