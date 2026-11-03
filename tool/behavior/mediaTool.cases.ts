import fs from 'node:fs';
import path from 'node:path';
import type { BehaviorDomain } from '../check/behavior-types';

/**
 * mediaTool 域行为用例：任务权限、入队与列表可见性。
 *
 * 任务本身由 media sidecar 执行（有 ffmpeg 才会真正出图），这里只验证
 * 「谁能建任务 / 只读不能建 / 建了能在列表里看到」，media 不可用时按 503 放行。
 * 资源是全局的（任务表无 owner），所以 `shared: true`。
 */
const WRITER = ['mediatool:read', 'mediatool:write'];

const domain: BehaviorDomain = {
  domain: 'mediaTool',
  shared: true,
  async prepare(tmpDir) {
    fs.mkdirSync(path.join(tmpDir, 'files', 'src'), { recursive: true });
    fs.writeFileSync(path.join(tmpDir, 'files', 'src', 'a.txt'), 'not an image');
    fs.writeFileSync(
      path.join(tmpDir, 'files', 'src', 'a.png'),
      Buffer.from(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
        'base64',
      ),
    );
    return {};
  },
  cases: [
    {
      id: 'jobs.anonymous-401',
      name: '匿名用户不能查看媒体工具任务',
      async run(ctx) {
        const res = await ctx.request('GET', '/api/v1/media-tool/jobs');
        ctx.assertStatus(res, 401, '匿名任务列表');
      },
    },
    {
      id: 'thumbnails.reader-403',
      name: '只读用户不能建批量缩略图任务',
      async run(ctx) {
        const reader = await ctx.token(['mediatool:read']);
        const res = await ctx.request('POST', '/api/v1/media-tool/thumbnails', {
          token: reader,
          payload: { source: 'src' },
        });
        ctx.assertStatus(res, 403, '只读建任务');
      },
    },
    {
      id: 'tasks.writer-thumbnails-403',
      name: '写权限用户（非管理员）不能建批量缩略图任务',
      async run(ctx) {
        const writer = await ctx.token(WRITER);
        const res = await ctx.request('POST', '/api/v1/media-tool/thumbnails', {
          token: writer,
          payload: { source: 'src', target: 'thumbs', size: 64 },
        });
        ctx.assertStatus(res, 403, '非管理员建批量任务');
      },
    },
    {
      id: 'tasks.writer-image-allowed',
      name: '非管理员可以建单图压缩任务且能在列表看到',
      async run(ctx) {
        const writer = await ctx.token(WRITER);
        const created = await ctx.request('POST', '/api/v1/media-tool/tasks/upsert', {
          token: writer,
          payload: {
            kind: 'image',
            source: 'src/a.png',
            target: 'imgout',
            config: { format: 'png', quality: 80, size: 0, policy: 'skip' },
          },
        });
        ctx.assertStatus(created, 200, '建单图压缩');
        const id = created.json().id as string;

        const list = await ctx.request('GET', '/api/v1/media-tool/tasks', { token: writer });
        ctx.assertStatus(list, 200, '任务列表');
        const row = (list.json().items as Array<Record<string, unknown>>).find((x) => x.id === id);
        ctx.expect(!!row, '列表包含刚建的任务');
        ctx.expect(row?.kind === 'image', '任务类型为 image');
      },
    },
  ],
};

export default domain;
