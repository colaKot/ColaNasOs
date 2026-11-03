import fs from 'node:fs';
import path from 'node:path';
import type { BehaviorDomain, CaseContext } from '../check/behavior-types';

/**
 * music 域行为用例：库权限、扫描、搜索、歌单跨用户隔离、播放直链。
 */
const OWNER = ['music:read', 'music:write', 'files:read'];
let libId = '';

async function ensureLibrary(ctx: CaseContext): Promise<string> {
  if (libId) return libId;
  const owner = await ctx.token(OWNER);
  const list = await ctx.request('GET', '/api/v1/music/libraries', { token: owner });
  ctx.assertStatus(list, 200, '库列表');
  const existing = (list.json().items as Array<{ id: string; path: string }>).find(
    (x) => x.path === 'music',
  );
  if (existing) {
    libId = existing.id;
    return libId;
  }
  const res = await ctx.request('POST', '/api/v1/music/libraries', {
    token: owner,
    payload: { name: 'Music', path: 'music' },
  });
  ctx.assertStatus(res, 200, '建库');
  libId = res.json().id as string;
  return libId;
}

async function ensureScanned(ctx: CaseContext): Promise<void> {
  await ensureLibrary(ctx);
  const owner = await ctx.token(OWNER);
  const scan = await ctx.request('POST', '/api/v1/music/scan', { token: owner, payload: {} });
  ctx.assertStatus(scan, 200, '扫描');
}

async function firstTrackId(ctx: CaseContext): Promise<string> {
  await ensureScanned(ctx);
  const owner = await ctx.token(OWNER);
  const list = await ctx.request('GET', '/api/v1/music/list?limit=10', { token: owner });
  ctx.assertStatus(list, 200, '曲目列表');
  const items = list.json().items as Array<{ id: string }>;
  ctx.expect(items.length >= 1, '至少 1 首曲目');
  return items[0].id;
}

const domain: BehaviorDomain = {
  domain: 'music',
  async prepare(tmpDir) {
    const dir = path.join(tmpDir, 'files', 'music');
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, 'Alpha.m4a'), Buffer.alloc(2048, 1));
    fs.writeFileSync(path.join(dir, 'Beta.m4a'), Buffer.alloc(2048, 2));
    return {};
  },
  cases: [
    {
      id: 'library.anonymous-401',
      name: '匿名用户不能查看音乐库',
      async run(ctx) {
        const res = await ctx.request('GET', '/api/v1/music/libraries');
        ctx.assertStatus(res, 401, '匿名库列表');
      },
    },
    {
      id: 'scan.reader-write-403',
      name: '只读用户不能触发扫描',
      async run(ctx) {
        const reader = await ctx.token(['music:read']);
        const res = await ctx.request('POST', '/api/v1/music/scan', { token: reader, payload: {} });
        ctx.assertStatus(res, 403, '只读扫描');
      },
    },
    {
      id: 'scan.owner-200',
      name: '写权限用户可以扫描并入库',
      async run(ctx) {
        await ensureLibrary(ctx);
        const owner = await ctx.token(OWNER);
        const res = await ctx.request('POST', '/api/v1/music/scan', { token: owner, payload: {} });
        ctx.assertStatus(res, 200, '扫描');
        const body = res.json() as { tracks: number };
        ctx.expect(body.tracks >= 2, '至少 2 首');
      },
    },
    {
      id: 'list.search',
      name: '关键词搜索命中曲目',
      async run(ctx) {
        await ensureScanned(ctx);
        const owner = await ctx.token(OWNER);
        const res = await ctx.request('GET', '/api/v1/music/list?q=beta', { token: owner });
        ctx.assertStatus(res, 200, '搜索');
        const items = res.json().items as Array<{ title: string }>;
        ctx.expect(items.length === 1 && items[0].title === 'Beta', '命中 Beta');
      },
    },
    {
      id: 'playlist.other-user-404',
      name: '歌单按用户隔离',
      async run(ctx) {
        const trackId = await firstTrackId(ctx);
        const owner = await ctx.token(OWNER);
        const created = await ctx.request('POST', '/api/v1/music/playlists', {
          token: owner,
          payload: { name: 'Fav', trackIds: [trackId] },
        });
        ctx.assertStatus(created, 200, '建歌单');
        const playlistId = created.json().id as string;

        const other = await ctx.token(['music:read', 'music:write'], 'u3');
        const mine = await ctx.request(
          'GET',
          `/api/v1/music/playlists/items?playlistId=${encodeURIComponent(playlistId)}`,
          { token: owner },
        );
        const theirs = await ctx.request(
          'GET',
          `/api/v1/music/playlists/items?playlistId=${encodeURIComponent(playlistId)}`,
          { token: other },
        );
        ctx.assertStatus(mine, 200, '本人歌单');
        ctx.assertStatus(theirs, 404, '他人歌单');
      },
    },
    {
      id: 'stream-url.playable',
      name: '播放直链无需 Authorization 头',
      async run(ctx) {
        const trackId = await firstTrackId(ctx);
        const owner = await ctx.token(OWNER);
        const url = await ctx.request(
          'GET',
          `/api/v1/music/stream-url?id=${encodeURIComponent(trackId)}`,
          { token: owner },
        );
        ctx.assertStatus(url, 200, '生成直链');
        const direct = await ctx.request('GET', url.json().url as string, {
          headers: { range: 'bytes=0-4' },
        });
        ctx.assertStatus(direct, 206, '直链播放');
      },
    },
  ],
};

export default domain;