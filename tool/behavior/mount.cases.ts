import type { BehaviorDomain } from '../check/behavior-types';

/**
 * mount 域行为用例：挂载配置的权限、凭据不外泄、rclone 可用性、删除。
 * 不依赖外部 WebDAV 服务 —— 真实读写链路由 `smoke:mount` 覆盖。
 */
const OWNER = ['mount:read', 'mount:write'];

const domain: BehaviorDomain = {
  domain: 'mount',
  // 挂载配置是全局资源（remote_mounts 无 owner 列），跨用户角色不适用
  shared: true,
  cases: [
    {
      id: 'create.anonymous-401',
      name: '匿名用户不能创建挂载',
      async run(ctx) {
        const res = await ctx.request('POST', '/api/v1/mount/mounts', {
          payload: { name: 'x', kind: 'webdav', baseUrl: 'http://127.0.0.1:1/' },
        });
        ctx.assertStatus(res, 401, '匿名创建');
      },
    },
    {
      id: 'create.invalid-kind-400',
      name: '不支持的挂载类型被拒绝',
      async run(ctx) {
        const owner = await ctx.token(OWNER);
        const res = await ctx.request('POST', '/api/v1/mount/mounts', {
          token: owner,
          payload: { name: 'x', kind: 'ftp', baseUrl: 'ftp://example.com' },
        });
        ctx.assertStatus(res, 400, '非法 kind');
      },
    },
    {
      id: 'create.reader-403',
      name: '只读用户不能创建挂载',
      async run(ctx) {
        const reader = await ctx.token(['mount:read']);
        const res = await ctx.request('POST', '/api/v1/mount/mounts', {
          token: reader,
          payload: { name: 'x', kind: 'webdav', baseUrl: 'http://127.0.0.1:1/' },
        });
        ctx.assertStatus(res, 403, '只读创建');
      },
    },
    {
      id: 'list.no-secret',
      name: '挂载列表不返回密码',
      async run(ctx) {
        const owner = await ctx.token(OWNER);
        const created = await ctx.request('POST', '/api/v1/mount/mounts', {
          token: owner,
          payload: {
            name: 'Dav',
            kind: 'webdav',
            baseUrl: 'http://127.0.0.1:1/',
            username: 'u',
            password: 'p@ssw0rd',
          },
        });
        ctx.assertStatus(created, 200, '创建');

        const list = await ctx.request('GET', '/api/v1/mount/mounts', { token: owner });
        ctx.assertStatus(list, 200, '列表');
        const items = list.json().items as Array<Record<string, unknown>>;
        const row = items.find((x) => x.id === created.json().id);
        ctx.expect(!!row, '列表包含新挂载');
        ctx.expect(!('secret' in (row as object)) && !('password' in (row as object)), '不含凭据字段');
        ctx.expect(String(row?.baseUrl).includes('127.0.0.1'), '返回 baseUrl');
      },
    },
    {
      id: 'rclone.available-or-501',
      name: 'rclone 未安装时明确 501，已安装则测试成功',
      async run(ctx) {
        const owner = await ctx.token(OWNER);
        const created = await ctx.request('POST', '/api/v1/mount/mounts', {
          token: owner,
          payload: { name: 'SMB', kind: 'rclone', baseUrl: 'smb:share' },
        });
        ctx.assertStatus(created, 200, '创建 rclone 挂载');

        const test = await ctx.request('POST', '/api/v1/mount/mounts/test', {
          token: owner,
          payload: { id: created.json().id },
        });
        ctx.expect([200, 501].includes(test.statusCode), `期望 200 或 501，实际 ${test.statusCode}`);
      },
    },
    {
      id: 'remove.then-absent',
      name: '删除后列表不再包含',
      async run(ctx) {
        const owner = await ctx.token(OWNER);
        const created = await ctx.request('POST', '/api/v1/mount/mounts', {
          token: owner,
          payload: { name: 'Temp', kind: 'webdav', baseUrl: 'http://127.0.0.1:1/' },
        });
        ctx.assertStatus(created, 200, '创建');
        const id = created.json().id as string;

        const removed = await ctx.request('POST', '/api/v1/mount/mounts/remove', {
          token: owner,
          payload: { id },
        });
        ctx.assertStatus(removed, 200, '删除');

        const list = await ctx.request('GET', '/api/v1/mount/mounts', { token: owner });
        const items = list.json().items as Array<{ id: string }>;
        ctx.expect(!items.some((x) => x.id === id), '列表已无该挂载');
      },
    },
  ],
};

export default domain;