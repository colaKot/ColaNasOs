import type { BehaviorDomain, CaseContext } from '../check/behavior-types';

/**
 * message 域行为用例：站内消息的发送权限、已读流转、删除、跨用户隔离。
 */
const OWNER = ['message:read', 'message:write'];

async function sendToSelf(ctx: CaseContext, title: string): Promise<string> {
  const owner = await ctx.token(OWNER);
  const res = await ctx.request('POST', '/api/v1/messages/send', {
    token: owner,
    payload: { title, body: 'hello', level: 'info' },
  });
  ctx.assertStatus(res, 200, '发送');
  return (res.json().id ?? '') as string;
}

const domain: BehaviorDomain = {
  domain: 'message',
  cases: [
    {
      id: 'send.anonymous-401',
      name: '匿名用户不能发送站内消息',
      async run(ctx) {
        const res = await ctx.request('POST', '/api/v1/messages/send', {
          payload: { title: 'x', body: 'y' },
        });
        ctx.assertStatus(res, 401, '匿名发送');
      },
    },
    {
      id: 'send.reader-403',
      name: '只读用户不能发送消息',
      async run(ctx) {
        const reader = await ctx.token(['message:read']);
        const res = await ctx.request('POST', '/api/v1/messages/send', {
          token: reader,
          payload: { title: 'x', body: 'y' },
        });
        ctx.assertStatus(res, 403, '只读发送');
      },
    },
    {
      id: 'send-and-list',
      name: '发送后可读回，未读数增加',
      async run(ctx) {
        await sendToSelf(ctx, 'Alpha Message');
        const owner = await ctx.token(OWNER);
        const list = await ctx.request('GET', '/api/v1/messages?limit=20', { token: owner });
        ctx.assertStatus(list, 200, '消息列表');
        const items = list.json().items as Array<{ title: string; unread?: boolean; read?: boolean }>;
        ctx.expect(items.some((x) => x.title === 'Alpha Message'), '列表含新消息');

        const unread = await ctx.request('GET', '/api/v1/messages/unread-count', { token: owner });
        ctx.assertStatus(unread, 200, '未读数');
        ctx.expect(Number(unread.json().unread ?? unread.json().count ?? 0) >= 1, '未读数 ≥ 1');
      },
    },
    {
      id: 'read-flow',
      name: '标记已读后未读数下降',
      async run(ctx) {
        const id = await sendToSelf(ctx, 'Beta Message');
        const owner = await ctx.token(OWNER);
        const before = await ctx.request('GET', '/api/v1/messages/unread-count', { token: owner });
        const beforeCount = Number(before.json().unread ?? before.json().count ?? 0);

        const read = await ctx.request('POST', '/api/v1/messages/read', {
          token: owner,
          payload: { id },
        });
        ctx.assertStatus(read, 200, '标记已读');

        const after = await ctx.request('GET', '/api/v1/messages/unread-count', { token: owner });
        const afterCount = Number(after.json().unread ?? after.json().count ?? 0);
        ctx.expect(afterCount < beforeCount, `未读数应下降（${beforeCount} → ${afterCount}）`);
      },
    },
    {
      id: 'remove',
      name: '删除后列表不含',
      async run(ctx) {
        const id = await sendToSelf(ctx, 'Gamma Message');
        const owner = await ctx.token(OWNER);
        const removed = await ctx.request('POST', '/api/v1/messages/remove', {
          token: owner,
          payload: { id },
        });
        ctx.assertStatus(removed, 200, '删除');

        const list = await ctx.request('GET', '/api/v1/messages?limit=50', { token: owner });
        const items = list.json().items as Array<{ title: string }>;
        ctx.expect(!items.some((x) => x.title === 'Gamma Message'), '列表已无该消息');
      },
    },
    {
      id: 'cross-user-isolated',
      name: '发给他人只出现在他人收件箱',
      async run(ctx) {
        const sender = await ctx.token(OWNER);
        const sent = await ctx.request('POST', '/api/v1/messages/send', {
          token: sender,
          payload: { userId: 'u3', title: 'For U3', body: 'hi there' },
        });
        ctx.assertStatus(sent, 200, '定向发送');

        const mine = await ctx.request('GET', '/api/v1/messages?limit=50', { token: sender });
        const theirs = await ctx.request('GET', '/api/v1/messages?limit=50', {
          token: await ctx.token(['message:read'], 'u3'),
        });
        ctx.expect(
          !(mine.json().items as Array<{ title: string }>).some((x) => x.title === 'For U3'),
          '发送者收件箱不含',
        );
        ctx.expect(
          (theirs.json().items as Array<{ title: string }>).some((x) => x.title === 'For U3'),
          '接收者收件箱包含',
        );
      },
    },
  ],
};

export default domain;