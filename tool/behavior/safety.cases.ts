import fs from 'node:fs';
import path from 'node:path';
import type { BehaviorDomain, CaseContext } from '../check/behavior-types';

/**
 * safety 域行为用例：备份权限与恢复、加密空间的密码门禁与往返。
 */
const OWNER = ['backup:read', 'backup:write', 'vault:read', 'vault:write', 'files:read'];

const domain: BehaviorDomain = {
  domain: 'safety',
  // 备份任务与加密空间是全局资源（backup_jobs / vaults 无 owner 列），跨用户角色不适用
  shared: true,
  async prepare(tmpDir) {
    const dir = path.join(tmpDir, 'files', 'src');
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, 'a.txt'), 'alpha');
    fs.writeFileSync(path.join(dir, 'b.txt'), 'beta');
    return {};
  },
  cases: [
    {
      id: 'backup.run.anonymous-401',
      name: '匿名用户不能触发备份',
      async run(ctx) {
        const res = await ctx.request('POST', '/api/v1/backup/run', { payload: { source: 'src' } });
        ctx.assertStatus(res, 401, '匿名备份');
      },
    },
    {
      id: 'backup.run-and-restore',
      name: '备份后可恢复',
      async run(ctx) {
        const owner = await ctx.token(OWNER);
        const run = await ctx.request('POST', '/api/v1/backup/run', {
          token: owner,
          payload: { source: 'src', name: 'nightly' },
        });
        ctx.assertStatus(run, 200, '备份');
        const job = run.json() as { id: string; files: number };
        ctx.expect(job.files >= 2, '备份包含 2 个文件');

        const list = await ctx.request('GET', '/api/v1/backup/list', { token: owner });
        ctx.assertStatus(list, 200, '备份列表');
        const items = list.json().items as Array<{ id: string }>;
        ctx.expect(items.some((x) => x.id === job.id), '列表包含该备份');

        const restore = await ctx.request('POST', '/api/v1/backup/restore', {
          token: owner,
          payload: { id: job.id, target: 'restored' },
        });
        ctx.assertStatus(restore, 200, '恢复');
        const body = restore.json() as { restored: number };
        ctx.expect(body.restored >= 2, '至少恢复 2 个文件');
      },
    },
    {
      id: 'backup.restore-unknown-404',
      name: '恢复不存在的备份返回 404',
      async run(ctx) {
        const owner = await ctx.token(OWNER);
        const res = await ctx.request('POST', '/api/v1/backup/restore', {
          token: owner,
          payload: { id: 'nope', target: 'restored' },
        });
        ctx.assertStatus(res, 404, '未知备份');
      },
    },
    {
      id: 'vault.roundtrip',
      name: '加密空间写入后可用同一密码读回',
      async run(ctx) {
        const owner = await ctx.token(OWNER);
        const created = await ctx.request('POST', '/api/v1/vault/create', {
          token: owner,
          payload: { id: 'vault1', password: 's3cret-pass' },
        });
        ctx.assertStatus(created, 200, '建加密空间');

        const put = await ctx.request('POST', '/api/v1/vault/put', {
          token: owner,
          payload: {
            id: 'vault1',
            path: 'secret.txt',
            data: Buffer.from('top-secret').toString('base64'),
            password: 's3cret-pass',
          },
        });
        ctx.assertStatus(put, 200, '写入');

        const got = await ctx.request('POST', '/api/v1/vault/get', {
          token: owner,
          payload: { id: 'vault1', path: 'secret.txt', password: 's3cret-pass' },
        });
        ctx.assertStatus(got, 200, '读取');
        const decoded = Buffer.from(String(got.json().data ?? ''), 'base64').toString('utf8');
        ctx.expect(decoded === 'top-secret', '内容一致');
      },
    },
    {
      id: 'vault.wrong-password-403',
      name: '错误密码不能读取加密空间',
      async run(ctx) {
        const owner = await ctx.token(OWNER);
        await ctx.request('POST', '/api/v1/vault/create', {
          token: owner,
          payload: { id: 'vault2', password: 's3cret-pass' },
        });
        await ctx.request('POST', '/api/v1/vault/put', {
          token: owner,
          payload: { id: 'vault2', path: 'a.txt', data: 'x', password: 's3cret-pass' },
        });
        const res = await ctx.request('POST', '/api/v1/vault/get', {
          token: owner,
          payload: { id: 'vault2', path: 'a.txt', password: 'wrong-pass' },
        });
        ctx.assertStatus(res, 403, '错误密码');
      },
    },
    {
      id: 'backup.reader-write-403',
      name: '只读用户不能触发备份',
      async run(ctx) {
        const reader = await ctx.token(['backup:read']);
        const res = await ctx.request('POST', '/api/v1/backup/run', {
          token: reader,
          payload: { source: 'src' },
        });
        ctx.assertStatus(res, 403, '只读备份');
      },
    },
  ],
};

export default domain;