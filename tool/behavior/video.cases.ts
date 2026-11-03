import fs from 'node:fs';
import path from 'node:path';
import type { BehaviorDomain, CaseContext } from '../check/behavior-types';

/**
 * video 域行为用例：库权限、扫描、搜索、播放直链、未知 id。
 * 用占位视频文件（扫描仍入库，元数据降级为 null），不依赖 ffmpeg。
 */
const OWNER = ['video:read', 'video:write', 'files:read'];
let libId = '';

async function ensureLibrary(ctx: CaseContext): Promise<string> {
  if (libId) return libId;
  const owner = await ctx.token(OWNER);
  const list = await ctx.request('GET', '/api/v1/video/libraries', { token: owner });
  ctx.assertStatus(list, 200, '库列表');
  const existing = (list.json().items as Array<{ id: string; path: string }>).find(
    (x) => x.path === 'movies',
  );
  if (existing) {
    libId = existing.id;
    return libId;
  }
  const res = await ctx.request('POST', '/api/v1/video/libraries', {
    token: owner,
    payload: { name: 'Movies', path: 'movies' },
  });
  ctx.assertStatus(res, 200, '建库');
  libId = res.json().id as string;
  return libId;
}

async function ensureScanned(ctx: CaseContext): Promise<void> {
  await ensureLibrary(ctx);
  const owner = await ctx.token(OWNER);
  const scan = await ctx.request('POST', '/api/v1/video/scan', { token: owner, payload: {} });
  ctx.assertStatus(scan, 200, '扫描');
}

const domain: BehaviorDomain = {
  domain: 'video',
  async prepare(tmpDir) {
    const dir = path.join(tmpDir, 'files', 'movies');
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, 'Alpha.mp4'), Buffer.alloc(2048, 1));
    fs.writeFileSync(path.join(dir, 'Beta.mkv'), Buffer.alloc(2048, 2));
    // 外挂字幕：与 Alpha.mp4 同目录同主名
    fs.writeFileSync(
      path.join(dir, 'Alpha.srt'),
      '1\n00:00:01,000 --> 00:00:02,000\nSubtitle line\n',
    );

    // 剧集样本：库根下「剧名/Season 1/S01E01」
    const showDir = path.join(dir, 'Breaking Bad', 'Season 1');
    fs.mkdirSync(showDir, { recursive: true });
    fs.writeFileSync(path.join(showDir, 'S01E01 - Pilot.mkv'), Buffer.alloc(2048, 3));
    return {};
  },
  cases: [
    {
      id: 'library.anonymous-401',
      name: '匿名用户不能查看影视库',
      async run(ctx) {
        const res = await ctx.request('GET', '/api/v1/video/libraries');
        ctx.assertStatus(res, 401, '匿名库列表');
      },
    },
    {
      id: 'library.reader-write-403',
      name: '只读用户不能新建影视库',
      async run(ctx) {
        const reader = await ctx.token(['video:read']);
        const res = await ctx.request('POST', '/api/v1/video/libraries', {
          token: reader,
          payload: { name: 'X', path: 'movies' },
        });
        ctx.assertStatus(res, 403, '只读建库');
      },
    },
    {
      id: 'library.escape-400',
      name: '越界路径不能建库',
      async run(ctx) {
        const owner = await ctx.token(OWNER);
        const res = await ctx.request('POST', '/api/v1/video/libraries', {
          token: owner,
          payload: { name: 'bad', path: '../../../etc' },
        });
        ctx.assertStatus(res, 400, '越界建库');
      },
    },
    {
      id: 'scan.owner-200',
      name: '写权限用户可以扫描并入库',
      async run(ctx) {
        await ensureLibrary(ctx);
        const owner = await ctx.token(OWNER);
        const res = await ctx.request('POST', '/api/v1/video/scan', { token: owner, payload: {} });
        ctx.assertStatus(res, 200, '扫描');
        const body = res.json() as { videos: number; libraries: number };
        ctx.expect(body.libraries >= 1, '至少 1 个库');
        ctx.expect(body.videos >= 1, '至少 1 个视频');
      },
    },
    {
      id: 'list.search',
      name: '列表支持关键词搜索且标题有序',
      async run(ctx) {
        await ensureScanned(ctx);
        const owner = await ctx.token(OWNER);
        const all = await ctx.request('GET', '/api/v1/video/list?limit=50', { token: owner });
        ctx.assertStatus(all, 200, '列表');
        const items = all.json().items as Array<{ title: string }>;
        ctx.expect(items.length >= 2, '至少 2 条');
        const sorted = [...items].sort((a, b) => a.title.localeCompare(b.title));
        ctx.expect(
          items.every((x, i) => x.title === sorted[i].title),
          '按标题升序',
        );

        const hit = await ctx.request('GET', '/api/v1/video/list?q=alpha', { token: owner });
        ctx.assertStatus(hit, 200, '搜索');
        const found = hit.json().items as Array<{ title: string }>;
        ctx.expect(found.length === 1 && found[0].title === 'Alpha', '命中 Alpha');
      },
    },
    {
      id: 'stream-url.playable',
      name: '播放直链无需 Authorization 头',
      async run(ctx) {
        await ensureScanned(ctx);
        const owner = await ctx.token(OWNER);
        const list = await ctx.request('GET', '/api/v1/video/list?q=alpha', { token: owner });
        const item = (list.json().items as Array<{ id: string }>)[0];
        ctx.expect(!!item, '找到影片');

        const url = await ctx.request(
          'GET',
          `/api/v1/video/stream-url?id=${encodeURIComponent(item.id)}`,
          { token: owner },
        );
        ctx.assertStatus(url, 200, '生成直链');
        const direct = await ctx.request('GET', url.json().url as string, {
          headers: { range: 'bytes=0-4' },
        });
        ctx.assertStatus(direct, 206, '直链播放');
      },
    },
    {
      id: 'item.404',
      name: '未知 id 返回 404',
      async run(ctx) {
        const owner = await ctx.token(OWNER);
        const res = await ctx.request('GET', '/api/v1/video/item?id=nope', { token: owner });
        ctx.assertStatus(res, 404, '未知 id');
      },
    },
    {
      id: 'series.recognizes-episodes',
      name: '编号文件归入剧集，普通文件留在影片',
      async run(ctx) {
        await ensureScanned(ctx);
        const owner = await ctx.token(OWNER);

        const shows = await ctx.request('GET', '/api/v1/video/series', { token: owner });
        ctx.assertStatus(shows, 200, '剧集列表');
        const items = shows.json().items as Array<{ name: string; episodes: number }>;
        const show = items.find((s) => s.name === 'Breaking Bad');
        ctx.expect(!!show && show.episodes >= 1, '识别出 Breaking Bad');

        const eps = await ctx.request(
          'GET',
          `/api/v1/video/series/items?name=${encodeURIComponent('Breaking Bad')}`,
          { token: owner },
        );
        ctx.assertStatus(eps, 200, '季集列表');
        const first = (eps.json().items as Array<{ season: number; episode: number | null }>)[0];
        ctx.expect(first?.season === 1 && first?.episode === 1, 'S01E01 归为 1 季 1 集');

        const movies = await ctx.request('GET', '/api/v1/video/list?series=none&limit=50', {
          token: owner,
        });
        ctx.assertStatus(movies, 200, '只看影片');
        const titles = (movies.json().items as Array<{ title: string }>).map((x) => x.title);
        ctx.expect(
          titles.includes('Alpha') && !titles.some((t) => t.includes('S01E01')),
          '影片不含剧集',
        );
      },
    },
    {
      id: 'series.anonymous-401',
      name: '匿名用户不能查看剧集列表',
      async run(ctx) {
        const res = await ctx.request('GET', '/api/v1/video/series');
        ctx.assertStatus(res, 401, '匿名剧集');
      },
    },
    {
      id: 'progress.per-user-isolation',
      name: '观看进度按用户隔离且列表按更新时间倒序',
      async run(ctx) {
        await ensureScanned(ctx);
        const owner = await ctx.token(OWNER);
        const other = await ctx.token(['video:read'], 'u2');

        const list = await ctx.request('GET', '/api/v1/video/list?limit=50', { token: owner });
        const items = list.json().items as Array<{ id: string }>;
        ctx.expect(items.length >= 2, '至少 2 条可播内容');

        const saved = await ctx.request('POST', '/api/v1/video/progress/save', {
          token: owner,
          payload: { id: items[0].id, percent: 80, position: '480s' },
        });
        ctx.assertStatus(saved, 200, '保存进度');
        ctx.expect(saved.json().percent === 80, '回写 80%');

        const mine = await ctx.request(
          `GET`,
          `/api/v1/video/progress?id=${encodeURIComponent(items[0].id)}`,
          {
            token: owner,
          },
        );
        ctx.assertStatus(mine, 200, '读自己的进度');
        ctx.expect(mine.json().percent === 80, '读到 80%');

        const theirs = await ctx.request(
          'GET',
          `/api/v1/video/progress?id=${encodeURIComponent(items[0].id)}`,
          { token: other },
        );
        ctx.assertStatus(theirs, 200, '读他人进度');
        ctx.expect(theirs.json().percent === 0, '他人看不到 80%');

        await ctx.request('POST', '/api/v1/video/progress/save', {
          token: owner,
          payload: { id: items[1].id, percent: 20 },
        });
        const mineList = await ctx.request('GET', '/api/v1/video/progress/list', { token: owner });
        ctx.assertStatus(mineList, 200, '进度列表');
        const rows = mineList.json().items as Array<{ itemId: string }>;
        ctx.expect(rows.length === 2 && rows[0].itemId === items[1].id, '最近保存的排在前面');
      },
    },
    {
      id: 'progress.reader-save-403',
      name: '只读用户不能保存观看进度',
      async run(ctx) {
        await ensureScanned(ctx);
        const reader = await ctx.token(['video:read']);
        const owner = await ctx.token(OWNER);
        const list = await ctx.request('GET', '/api/v1/video/list?limit=1', { token: owner });
        const item = (list.json().items as Array<{ id: string }>)[0];

        const res = await ctx.request('POST', '/api/v1/video/progress/save', {
          token: reader,
          payload: { id: item.id, percent: 10 },
        });
        ctx.assertStatus(res, 403, '只读保存进度');
      },
    },
    {
      id: 'subtitle.anonymous-401',
      name: '匿名用户不能查看外挂字幕',
      async run(ctx) {
        await ensureScanned(ctx);
        const owner = await ctx.token(OWNER);
        const list = await ctx.request('GET', '/api/v1/video/list?q=alpha', { token: owner });
        const item = (list.json().items as Array<{ id: string }>)[0];

        const res = await ctx.request(
          'GET',
          `/api/v1/video/subtitles?id=${encodeURIComponent(item.id)}`,
        );
        ctx.assertStatus(res, 401, '匿名字幕列表');
      },
    },
    {
      id: 'subtitle.reader-can-read',
      name: '只读用户可列出并读取外挂字幕（含 WebVTT）',
      async run(ctx) {
        await ensureScanned(ctx);
        const reader = await ctx.token(['video:read']);
        const owner = await ctx.token(OWNER);
        const list = await ctx.request('GET', '/api/v1/video/list?q=alpha', { token: owner });
        const item = (list.json().items as Array<{ id: string }>)[0];
        ctx.expect(!!item, '找到影片');

        const files = await ctx.request(
          'GET',
          `/api/v1/video/subtitles?id=${encodeURIComponent(item.id)}`,
          { token: reader },
        );
        ctx.assertStatus(files, 200, '只读字幕列表');
        const names = (files.json().items as Array<{ name: string }>).map((f) => f.name);
        ctx.expect(names.includes('Alpha.srt'), '列出 Alpha.srt');

        const body = await ctx.request(
          'GET',
          `/api/v1/video/subtitle?id=${encodeURIComponent(item.id)}&name=Alpha.srt`,
          { token: reader },
        );
        ctx.assertStatus(body, 200, '只读读字幕');
        const parsed = body.json() as { cues: Array<{ text: string }>; vtt: string };
        ctx.expect(parsed.cues.length === 1 && parsed.cues[0].text === 'Subtitle line', '解析出 1 条');
        ctx.expect(String(parsed.vtt).startsWith('WEBVTT'), '返回 WebVTT');
      },
    },
    {
      id: 'subtitle.unknown-name-404',
      name: '未收录的字幕文件名返回 404',
      async run(ctx) {
        await ensureScanned(ctx);
        const owner = await ctx.token(OWNER);
        const list = await ctx.request('GET', '/api/v1/video/list?q=alpha', { token: owner });
        const item = (list.json().items as Array<{ id: string }>)[0];

        const res = await ctx.request(
          'GET',
          `/api/v1/video/subtitle?id=${encodeURIComponent(item.id)}&name=../Alpha.srt`,
          { token: owner },
        );
        ctx.assertStatus(res, 404, '未知字幕名');
      },
    },
  ],
};

export default domain;
