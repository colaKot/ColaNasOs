import fs from 'node:fs';
import path from 'node:path';
import type { BehaviorDomain, CaseContext } from '../check/behavior-types';

/**
 * photo 域行为用例：谁能建库/扫描、时间轴与搜索、相册的用户隔离。
 * 每个 case 自包含（需要时自动建库并扫描），支持 `--id=` 单独跑。
 */
const OWNER = ['photo:read', 'photo:write', 'files:read'];
const PNG_1PX = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  'base64',
);

let libId = '';

async function ensureLibrary(ctx: CaseContext): Promise<string> {
  if (libId) return libId;
  const owner = await ctx.token(OWNER);
  const list = await ctx.request('GET', '/api/v1/photo/libraries', { token: owner });
  ctx.assertStatus(list, 200, '库列表');
  const existing = (list.json().items as Array<{ id: string; path: string }>).find(
    (x) => x.path === 'photos',
  );
  if (existing) {
    libId = existing.id;
    return libId;
  }
  const res = await ctx.request('POST', '/api/v1/photo/libraries', {
    token: owner,
    payload: { name: 'Photos', path: 'photos' },
  });
  ctx.assertStatus(res, 200, '建库');
  libId = res.json().id as string;
  return libId;
}

async function ensureScanned(ctx: CaseContext): Promise<void> {
  await ensureLibrary(ctx);
  const owner = await ctx.token(OWNER);
  const scan = await ctx.request('POST', '/api/v1/photo/scan', { token: owner, payload: {} });
  ctx.assertStatus(scan, 200, '扫描');
  ctx.expect((scan.json().added as number) >= 0, '扫描返回统计');
}

const domain: BehaviorDomain = {
  domain: 'photo',
  async prepare(tmpDir) {
    const dir = path.join(tmpDir, 'files', 'photos', 'trip');
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, 'IMG_20240102_120000.png'), PNG_1PX);
    fs.writeFileSync(path.join(tmpDir, 'files', 'photos', 'Alpha.png'), PNG_1PX);
    return {};
  },
  cases: [
    {
      id: 'timeline.anonymous-401',
      name: '匿名用户不能读取时间轴',
      async run(ctx) {
        const res = await ctx.request('GET', '/api/v1/photo/timeline');
        ctx.assertStatus(res, 401, '匿名时间轴');
      },
    },
    {
      id: 'library.reader-write-403',
      name: '只读用户不能新建相册库',
      async run(ctx) {
        const reader = await ctx.token(['photo:read']);
        const res = await ctx.request('POST', '/api/v1/photo/libraries', {
          token: reader,
          payload: { name: 'X', path: 'photos' },
        });
        ctx.assertStatus(res, 403, '只读建库');
      },
    },
    {
      id: 'library.escape-400',
      name: '越界路径不能建库',
      async run(ctx) {
        const owner = await ctx.token(OWNER);
        const res = await ctx.request('POST', '/api/v1/photo/libraries', {
          token: owner,
          payload: { name: 'bad', path: '../../../etc' },
        });
        ctx.assertStatus(res, 400, '越界建库');
      },
    },
    {
      id: 'scan.owner-200',
      name: '写权限用户可以扫描索引',
      async run(ctx) {
        await ensureLibrary(ctx);
        const owner = await ctx.token(OWNER);
        const res = await ctx.request('POST', '/api/v1/photo/scan', { token: owner, payload: {} });
        ctx.assertStatus(res, 200, '扫描');
        const body = res.json() as { images: number; added: number; libraries: number };
        ctx.expect(body.libraries >= 1, '至少扫描 1 个库');
        ctx.expect(body.images >= 1, '至少发现 1 张图');
      },
    },
    {
      id: 'timeline.has-item',
      name: '扫描后时间轴返回照片并按拍摄时间倒序',
      async run(ctx) {
        await ensureScanned(ctx);
        const owner = await ctx.token(OWNER);
        const res = await ctx.request('GET', '/api/v1/photo/timeline?limit=10', { token: owner });
        ctx.assertStatus(res, 200, '时间轴');
        const items = res.json().items as Array<{ takenAt: number; path: string }>;
        ctx.expect(items.length >= 1, '时间轴非空');
        const sorted = [...items].sort((a, b) => b.takenAt - a.takenAt);
        ctx.expect(
          items.every((x, i) => x.takenAt === sorted[i].takenAt),
          '按 takenAt 倒序',
        );
      },
    },
    {
      id: 'search.keyword',
      name: '关键词搜索命中文件名',
      async run(ctx) {
        await ensureScanned(ctx);
        const owner = await ctx.token(OWNER);
        const res = await ctx.request('GET', '/api/v1/photo/search?q=alpha', { token: owner });
        ctx.assertStatus(res, 200, '搜索');
        const items = res.json().items as Array<{ path: string }>;
        ctx.expect(items.length >= 1, '搜索有结果');
        ctx.expect(
          items.every((x) => x.path.toLowerCase().includes('alpha')),
          '结果都含关键词',
        );
      },
    },
    {
      id: 'album.other-user-404',
      name: '相册按用户隔离，其他用户不可见',
      async run(ctx) {
        await ensureLibrary(ctx);
        const owner = await ctx.token(OWNER);
        const created = await ctx.request('POST', '/api/v1/photo/albums', {
          token: owner,
          payload: { name: 'Trip' },
        });
        ctx.assertStatus(created, 200, '建相册');
        const albumId = created.json().id as string;

        const other = await ctx.token(['photo:read', 'photo:write'], 'u3');
        const mine = await ctx.request('GET', `/api/v1/photo/albums/items?albumId=${encodeURIComponent(albumId)}`, {
          token: owner,
        });
        const theirs = await ctx.request(
          'GET',
          `/api/v1/photo/albums/items?albumId=${encodeURIComponent(albumId)}`,
          { token: other },
        );
        ctx.assertStatus(mine, 200, '本人相册');
        ctx.assertStatus(theirs, 404, '他人相册');
      },
    },
  ],
};

export default domain;