import fs from 'node:fs';
import path from 'node:path';
import type { BehaviorDomain, CaseContext, ResponseLike } from '../check/behavior-types';

/**
 * share 域行为用例：谁能创建分享、公开下载与密码保护、越界与撤销。
 * 每个 case 自包含（自己创建链接），支持 `--id=` 单独跑。
 */
const OWNER = ['share:read', 'share:write', 'files:read'];

async function createShare(
  ctx: CaseContext,
  extra: Record<string, unknown> = {},
): Promise<{ id: string; url: string }> {
  const owner = await ctx.token(OWNER);
  const res = await ctx.request('POST', '/api/v1/share/create', {
    token: owner,
    payload: { path: 'media/note.txt', ...extra },
  });
  ctx.assertStatus(res, 200, '创建分享');
  const body = res.json() as { id: string; url: string };
  ctx.expect(!!body.id && !!body.url, '返回 id 与 url');
  return body;
}

async function publicDownload(ctx: CaseContext, id: string, password?: string): Promise<ResponseLike> {
  const q = `/api/v1/share/download?id=${encodeURIComponent(id)}${password ? `&password=${encodeURIComponent(password)}` : ''}`;
  return ctx.request('GET', q);
}

const domain: BehaviorDomain = {
  domain: 'share',
  // 分享链接本就是「给所有人」的公开资源（share_links 无 owner 列），跨用户角色不适用
  shared: true,
  async prepare(tmpDir) {
    fs.mkdirSync(path.join(tmpDir, 'files', 'media'), { recursive: true });
    fs.writeFileSync(path.join(tmpDir, 'files', 'media', 'note.txt'), 'hello-share');
    return {};
  },
  cases: [
    {
      id: 'create.anonymous-401',
      name: '匿名用户不能创建分享链接',
      async run(ctx) {
        const res = await ctx.request('POST', '/api/v1/share/create', {
          payload: { path: 'media/note.txt' },
        });
        ctx.assertStatus(res, 401, '匿名创建');
      },
    },
    {
      id: 'create.reader-403',
      name: '只有读权限的用户不能创建分享',
      async run(ctx) {
        const reader = await ctx.token(['share:read']);
        const res = await ctx.request('POST', '/api/v1/share/create', {
          token: reader,
          payload: { path: 'media/note.txt' },
        });
        ctx.assertStatus(res, 403, '只读创建');
      },
    },
    {
      id: 'create.owner-200',
      name: '具备写权限的用户可以创建分享',
      async run(ctx) {
        const created = await createShare(ctx);
        ctx.expect(created.url.includes(created.id), 'url 应包含 id');
      },
    },
    {
      id: 'download.public-200',
      name: '公开链接无需登录即可下载',
      async run(ctx) {
        const created = await createShare(ctx);
        const info = await ctx.request('GET', `/api/v1/share/info?id=${encodeURIComponent(created.id)}`);
        ctx.assertStatus(info, 200, '公开 info');
        ctx.expect(info.json().fileName === 'note.txt', 'info 返回文件名');

        const dl = await publicDownload(ctx, created.id);
        ctx.assertStatus(dl, 200, '公开下载');
        ctx.expect(dl.body === 'hello-share', '下载内容一致');
      },
    },
    {
      id: 'download.password-guard',
      name: '带密码的链接必须提供正确密码',
      async run(ctx) {
        const created = await createShare(ctx, { password: 's3cret' });
        const none = await publicDownload(ctx, created.id);
        const wrong = await publicDownload(ctx, created.id, 'wrong');
        const right = await publicDownload(ctx, created.id, 's3cret');
        ctx.assertStatus(none, 403, '未给密码');
        ctx.assertStatus(wrong, 403, '错误密码');
        ctx.assertStatus(right, 200, '正确密码');
        ctx.expect(right.body === 'hello-share', '密码正确后内容一致');
      },
    },
    {
      id: 'path.escape-400',
      name: '越界路径不能创建分享',
      async run(ctx) {
        const owner = await ctx.token(OWNER);
        const res = await ctx.request('POST', '/api/v1/share/create', {
          token: owner,
          payload: { path: '../../../../etc/passwd' },
        });
        ctx.assertStatus(res, 400, '越界路径');
      },
    },
    {
      id: 'revoke.then-404',
      name: '撤销后链接立即失效',
      async run(ctx) {
        const created = await createShare(ctx);
        const owner = await ctx.token(OWNER);
        const revoke = await ctx.request('POST', '/api/v1/share/revoke', {
          token: owner,
          payload: { id: created.id },
        });
        ctx.assertStatus(revoke, 200, '撤销');
        const after = await ctx.request('GET', `/api/v1/share/info?id=${encodeURIComponent(created.id)}`);
        ctx.assertStatus(after, 404, '撤销后 info');
        const dl = await publicDownload(ctx, created.id);
        ctx.assertStatus(dl, 404, '撤销后下载');
      },
    },
  ],
};

export default domain;