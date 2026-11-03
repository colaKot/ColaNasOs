import test from 'node:test';
import assert from 'node:assert/strict';
import Fastify from 'fastify';
import { EventBus } from '../kernel/bus';
import { I18nRegistry } from '../kernel/i18n';
import { ModuleRegistry } from '../kernel/registry';
import { hasScope, signToken, verifyToken } from '../kernel/auth';
import { checkMigrationOrder, orderMigrations } from '../kernel/migrations/manifest';
import { appKeysForPath, checkAppAccess, checkPathAccess } from '../kernel/access-policy';
import { buildPlan } from '../src/modules/sync/plan';
import { WatchdogSupervisor } from '../kernel/watchdog-supervisor';
import { DEFAULT_PARAMS, clusterSamples, validateParams } from '../src/modules/photo/ai/cluster-v2';
import { buildUnc, normalizeScanPath, parseUnc } from '../src/modules/video/smb';
import { parseJpTagsFromName } from '../src/modules/video/media-type';
import { looksJunkTmdbMatch, pickExactCodeLink } from '../src/modules/video/jp-scrape';
import type { ServerModule } from '../kernel/types';

test('EventBus: 订阅、分发、退订', () => {
  const bus = new EventBus();
  const got: unknown[] = [];
  const off = bus.on('x', (p) => got.push(p));

  assert.equal(bus.emit('x', 1), 1);
  assert.deepEqual(got, [1]);

  off();
  assert.equal(bus.emit('x', 2), 0);
  assert.deepEqual(got, [1]);
});

test('EventBus: 单个监听器异常不影响其他', () => {
  const bus = new EventBus();
  let ok = 0;
  bus.on('e', () => {
    throw new Error('boom');
  });
  bus.on('e', () => {
    ok++;
  });

  assert.equal(bus.emit('e'), 1);
  assert.equal(ok, 1);
});

test('I18nRegistry: 注册、查询、语言清单', () => {
  const i18n = I18nRegistry.fromJSON([
    { code: 'zh-CN', native: '简体中文', enabled: true, files: {} },
    { code: 'en-US', native: 'English', enabled: false, files: {} },
  ]);

  i18n.register('files', ['list', 'upload']);

  assert.equal(i18n.has('files', 'list'), true);
  assert.equal(i18n.has('files', 'missing'), false);
  assert.deepEqual(i18n.enabledCodes(), ['zh-CN']);
  assert.equal(i18n.allKeys().length, 2);
});

test('ModuleRegistry: 单模块失败隔离且其他模块可用', async () => {
  const app = Fastify();
  const registry = new ModuleRegistry();

  const okModule: ServerModule = {
    id: 'ok',
    prefix: '/x',
    register(a) {
      a.get('/x/ping', async () => ({ ok: true }));
    },
  };
  const badModule: ServerModule = {
    id: 'bad',
    prefix: '/y',
    register() {
      throw new Error('register failed');
    },
  };

  registry.add(okModule).add(badModule);

  const errors: unknown[] = [];
  const k = { log: { error: (e: unknown) => errors.push(e) } } as any;

  const mounted = await registry.mount(app, k);

  assert.deepEqual(mounted.loaded, ['ok']);
  assert.deepEqual(mounted.degraded, ['bad']);
  assert.equal(errors.length, 1);

  const res = await app.inject({ method: 'GET', url: '/x/ping' });
  assert.equal(res.statusCode, 200);

  await app.close();
});

test('ModuleRegistry: dependsOn 拓扑排序', async () => {
  const app = Fastify();
  const registry = new ModuleRegistry();
  const order: string[] = [];

  const make = (id: string, deps: string[] = []): ServerModule => ({
    id,
    prefix: '/' + id,
    dependsOn: deps,
    register() {
      order.push(id);
    },
  });

  // 故意乱序注册
  registry
    .add(make('c', ['b']))
    .add(make('b', ['a']))
    .add(make('a'));

  const mounted = await registry.mount(app, {} as any);

  assert.deepEqual(order, ['a', 'b', 'c']);
  assert.deepEqual(mounted.loaded, ['a', 'b', 'c']);

  await app.close();
});

test('ModuleRegistry: 缺失依赖在启动期报错', async () => {
  const registry = new ModuleRegistry();
  registry.add({ id: 'b', prefix: '/b', dependsOn: ['missing'], register() {} });

  await assert.rejects(
    () => registry.mount(Fastify() as any, {} as any),
    /missing module dependencies/,
  );
});

test('ModuleRegistry: 环形依赖在启动期报错', async () => {
  const registry = new ModuleRegistry();
  registry.add({ id: 'a', prefix: '/a', dependsOn: ['b'], register() {} });
  registry.add({ id: 'b', prefix: '/b', dependsOn: ['a'], register() {} });

  await assert.rejects(
    () => registry.mount(Fastify() as any, {} as any),
    /circular module dependencies/,
  );
});

test('ModuleRegistry: 上游失败则下游跳过', async () => {
  const app = Fastify();
  const registry = new ModuleRegistry();

  registry.add({
    id: 'a',
    prefix: '/a',
    register() {
      throw new Error('a failed');
    },
  });
  registry.add({ id: 'b', prefix: '/b', dependsOn: ['a'], register() {} });
  registry.add({ id: 'c', prefix: '/c', register() {} });

  const mounted = await registry.mount(app, { log: { error: () => {} } } as any);

  assert.deepEqual(mounted.degraded, ['a']);
  assert.deepEqual(mounted.skipped, ['b']);
  assert.deepEqual(mounted.loaded, ['c']);

  await app.close();
});

test('auth: 签发与校验', () => {
  const secret = 'k'.repeat(32);
  const token = signToken({ sub: 'u1', scopes: ['files:read'] }, secret, { ttlSec: 60 });
  const payload = verifyToken(token, secret);

  assert.ok(payload);
  assert.equal(payload.sub, 'u1');
  assert.deepEqual(payload.scopes, ['files:read']);
  assert.equal(hasScope(payload, 'files:read'), true);
  assert.equal(hasScope(payload, 'files:write'), false);
});

test('auth: 篡改、错误密钥、过期均拒绝', () => {
  const secret = 'k'.repeat(32);
  const token = signToken({ sub: 'u1', scopes: ['*'] }, secret, { ttlSec: 60 });

  assert.equal(verifyToken(token.slice(0, -2) + 'xx', secret), null);
  assert.equal(verifyToken(token, 'z'.repeat(32)), null);
  assert.equal(verifyToken('not-a-jwt', secret), null);

  const expired = signToken({ sub: 'u1', scopes: ['*'] }, secret, { ttlSec: -10 });
  assert.equal(verifyToken(expired, secret), null);
});

test('auth: 通配 scope 语义', () => {
  const base = { sub: 'u', iat: 0, exp: 9e9 };

  assert.equal(hasScope({ ...base, scopes: ['*'] }, 'tasks:read'), true);
  assert.equal(hasScope({ ...base, scopes: ['files:*'] }, 'files:write'), true);
  assert.equal(hasScope({ ...base, scopes: ['files:*'] }, 'tasks:read'), false);
  assert.equal(hasScope({ ...base, scopes: [] }, 'files:read'), false);
});

test('migrations: 清单外迁移被判定为未登记', () => {
  const check = checkMigrationOrder(['001_config', '061_new'], ['001_config']);
  assert.deepEqual(check.unregistered, ['061_new']);
  assert.equal(check.duplicated.length, 0);
});

test('migrations: 清单已登记但模块缺失只告警', () => {
  const check = checkMigrationOrder(['001_config'], ['001_config', '002_gone']);
  assert.deepEqual(check.unregistered, []);
  assert.deepEqual(check.missing, ['002_gone']);
});

test('migrations: 重复登记被发现', () => {
  const check = checkMigrationOrder(['001_config'], ['001_config', '001_config']);
  assert.deepEqual(check.duplicated, ['001_config']);
});

test('migrations: 按清单顺序执行而不是字典序', () => {
  const mk = (id: string) => ({ id, up: async () => {} });
  const ordered = orderMigrations([mk('010_b'), mk('002_a')], ['002_a', '010_b']);
  assert.deepEqual(
    ordered.map((m) => m.id),
    ['002_a', '010_b'],
  );
});

test('access-policy: 未配置白名单不限制', () => {
  assert.equal(checkAppAccess(null, '/api/v1/photo/timeline').ok, true);
  assert.equal(checkAppAccess([], '/api/v1/photo/timeline').ok, true);
});

test('access-policy: 白名单命中与拒绝', () => {
  assert.equal(checkAppAccess(['photo'], '/api/v1/photo/timeline').ok, true);
  const denied = checkAppAccess(['photo'], '/api/v1/files/list');
  assert.equal(denied.ok, false);
  assert.equal(denied.appKey, 'files');
});

test('access-policy: 公共通道与未登记前缀放行', () => {
  assert.equal(checkAppAccess(['photo'], '/api/v1/auth/login').ok, true);
  assert.equal(checkAppAccess(['photo'], '/api/v1/mcp/tools').ok, true);
  assert.equal(checkAppAccess(['photo'], '/api/v1/unknown/new').ok, true);
});

test('access-policy: 前缀按段匹配，不误伤同名前缀', () => {
  assert.deepEqual(appKeysForPath('/api/v1/photos'), []);
  assert.deepEqual(appKeysForPath('/api/v1/photo/ai/analyze').sort(), ['ai', 'photo']);
});

test('access-policy: 路径 ACL 前缀与读写', () => {
  const rules = [{ path: '/pub', access: 'ro' as const }];
  assert.equal(checkPathAccess(rules, 'read', '/pub').ok, true);
  assert.equal(checkPathAccess(rules, 'read', '/pub/2026/a.jpg').ok, true);
  assert.equal(checkPathAccess(rules, 'write', '/pub/a.jpg').ok, false);
  assert.equal(checkPathAccess(rules, 'read', '/secret/a.jpg').ok, false);
  assert.equal(checkPathAccess(rules, 'read', '/publichidden').ok, false);
});

test('access-policy: 最深规则优先 + 空规则不限制', () => {
  const rules = [
    { path: '/', access: 'ro' as const },
    { path: '/pub', access: 'rw' as const },
  ];
  assert.equal(checkPathAccess(rules, 'write', '/pub/a.jpg').ok, true);
  assert.equal(checkPathAccess(rules, 'write', '/other/a.jpg').ok, false);
  assert.equal(checkPathAccess([], 'write', '/anywhere').ok, true);
  assert.equal(checkPathAccess(rules, 'read', '/../etc/passwd').ok, false);
});

test('sync plan: 三向比对的核心分支', () => {
  const t = 1_700_000_000_000;
  const base = [{ path: 'a.txt', size: 3, mtimeMs: t }];

  // 两端一致（mtime 差 1.5s 在容差内）
  let p = buildPlan([{ path: 'a.txt', size: 3, mtimeMs: t + 1500 }], base, base, 'bidirectional');
  assert.equal(p.stats.skip, 1);

  // 本地变了 ⇒ upload
  p = buildPlan([{ path: 'a.txt', size: 4, mtimeMs: t + 10_000 }], base, base, 'bidirectional');
  assert.equal(p.actions[0].kind, 'upload');

  // 远端变了 ⇒ download
  p = buildPlan(base, base, [{ path: 'a.txt', size: 4, mtimeMs: t + 10_000 }], 'bidirectional');
  assert.equal(p.actions[0].kind, 'download');

  // 两边都变 ⇒ conflict
  p = buildPlan(
    [{ path: 'a.txt', size: 4, mtimeMs: t + 10_000 }],
    base,
    [{ path: 'a.txt', size: 5, mtimeMs: t + 20_000 }],
    'bidirectional',
  );
  assert.equal(p.stats.conflict, 1);

  // 本地删除、基线有 ⇒ 删远端
  p = buildPlan([], base, base, 'bidirectional');
  assert.equal(p.actions[0].kind, 'deleteRemote');

  // 远端删除、基线有 ⇒ 删本地
  p = buildPlan(base, base, [], 'bidirectional');
  assert.equal(p.actions[0].kind, 'deleteLocal');

  // 新文件按方向
  assert.equal(buildPlan([{ path: 'n.txt', size: 1, mtimeMs: t }], [], [], 'bidirectional').actions[0].kind, 'upload');
  assert.equal(buildPlan([], [], [{ path: 'n.txt', size: 1, mtimeMs: t }], 'bidirectional').actions[0].kind, 'download');
});

test('sync plan: 单向模式不反向动作', () => {
  const t = 1_700_000_000_000;
  // download_only：本地新增只 skip
  let p = buildPlan([{ path: 'n.txt', size: 1, mtimeMs: t }], [], [], 'download_only');
  assert.equal(p.stats.upload, 0);
  assert.equal(p.actions[0].kind, 'skip');

  // upload_only：远端新增只 skip
  p = buildPlan([], [], [{ path: 'n.txt', size: 1, mtimeMs: t }], 'upload_only');
  assert.equal(p.stats.download, 0);
  assert.equal(p.actions[0].kind, 'skip');
});

test('watchdog supervisor: 启动期不动作，超硬阈值才重启', () => {
  const g = new WatchdogSupervisor({ mode: 'hang', hardMs: 1000, softMs: 600, maxRestarts: 2, windowMs: 60_000 });
  assert.equal(g.check(0).action, 'none');

  g.beat(1000, { cpuPct: 10 });
  assert.equal(g.check(1500).reason, 'ok');
  assert.equal(g.check(1800).reason, 'slow');
  assert.equal(g.check(2100).action, 'restart');
});

test('watchdog supervisor: 重启退避到上限后 GIVE UP', () => {
  const g = new WatchdogSupervisor({ mode: 'hang', hardMs: 100, maxRestarts: 2, windowMs: 60_000 });
  g.beat(0, {});
  assert.equal(g.check(200).action, 'restart');
  g.beat(300, {});
  assert.equal(g.check(500).action, 'restart');
  g.beat(600, {});
  assert.equal(g.check(800).action, 'giveup');
  assert.equal(g.restartCount(900), 2);
});

test('watchdog supervisor: off 模式只记账；always 模式 CPU 持续也重启', () => {
  const off = new WatchdogSupervisor({ mode: 'off', hardMs: 100 });
  off.beat(0, {});
  assert.equal(off.check(10_000).action, 'none');

  const always = new WatchdogSupervisor({
    mode: 'always',
    hardMs: 100_000,
    cpuHoldMs: 1000,
  });
  always.beat(0, { cpuPct: 99 });
  always.beat(2000, { cpuPct: 99 });
  assert.equal(always.check(2500).action, 'restart');
});

test('face cluster v2: 两组近似向量分成两簇且可复现', () => {
  const mk = (id: string, photoId: string, vec: number[], quality = 90, oldClusterId?: string) => ({
    id,
    photoId,
    photoKey: photoId,
    vec,
    quality,
    oldClusterId,
  });
  const samples = [
    mk('a1', 'p1', [1, 0, 0, 0]),
    mk('a2', 'p2', [0.99, 0.02, 0, 0]),
    mk('a3', 'p3', [0.98, 0.03, 0.01, 0]),
    mk('a4', 'p4', [0.97, 0.04, 0, 0.01]),
    mk('b1', 'p5', [0, 1, 0, 0]),
    mk('b2', 'p6', [0.02, 0.99, 0, 0]),
    mk('b3', 'p7', [0.01, 0.98, 0.02, 0]),
    mk('b4', 'p8', [0, 0.97, 0.03, 0]),
  ];
  const params = {
    ...DEFAULT_PARAMS,
    topK: 4,
    consensusMinSupport: 1,
    cwSeeds: [1, 7, 13],
    centerEmbeddings: false,
    maxClusterSize: 100,
  };
  const r1 = clusterSamples(samples, params);
  const r2 = clusterSamples(samples, params);

  assert.equal(r1.clusterCount, 2);
  assert.equal(r1.usedCount, 8);
  assert.deepEqual(
    r1.clusters.map((c) => c.members.slice().sort()),
    r2.clusters.map((c) => c.members.slice().sort()),
  );

  const aCluster = r1.clusters.find((c) => c.members.includes('a1'));
  assert.ok(aCluster);
  assert.equal(aCluster!.members.includes('b1'), false);
});

test('face cluster v2: 低质量样本不参与聚类、参数越界直接抛错', () => {
  const samples = [
    { id: 'x1', photoId: 'p1', vec: [1, 0], quality: 30 },
    { id: 'x2', photoId: 'p2', vec: [1, 0], quality: 90 },
  ];
  const r = clusterSamples(samples, {
    ...DEFAULT_PARAMS,
    consensusMinSupport: 1,
    centerEmbeddings: false,
  });
  assert.equal(r.usedCount, 1);
  assert.equal(r.assignments.find((a) => a.sampleId === 'x1')!.clusterKey, null);

  assert.throws(() => validateParams({ topK: 1 }), /out of bounds/);
});
test('smb: UNC 归一化与扫描路径规整', () => {
  assert.equal(buildUnc('\\\\nas\\', '\\media\\', 'movies/2026'), '\\\\nas\\media\\movies\\2026');
  const parsed = parseUnc('\\\\nas\\media\\movies');
  assert.deepEqual(parsed, { host: 'nas', share: 'media', subPath: 'movies' });
  // 盘符根不能去尾斜杠，否则变成非法路径 D:
  assert.equal(normalizeScanPath('D:\\'), 'D:\\');
  assert.equal(normalizeScanPath('\\\\nas\\media\\'), '\\\\nas\\media');
});

test('jp: 结尾 -U/-C/-UC 标记优先于关键词', () => {
  assert.deepEqual(parseJpTagsFromName('ABP-123-UC.mkv'), {
    uncensored: 1,
    chineseSub: 1,
    cleaned: 'ABP-123.mkv',
  });
  assert.equal(parseJpTagsFromName('ABP-123-U.mp4').uncensored, 1);
  assert.equal(parseJpTagsFromName('ABP-123-C.mp4').chineseSub, 1);
  assert.equal(parseJpTagsFromName('ABP-123.mp4').uncensored, 0);
});

test('jp-scrape: 只认番号精确匹配的详情链接', () => {
  const html = [
    '<a href="/v/aaa" ><strong>ABP-12</strong></a>',
    '<a href="/v/bbb" ><strong>ABP-123</strong></a>',
    '<a href="/actor/xxx">演员</a>',
  ].join('');
  assert.equal(pickExactCodeLink(html, 'ABP-123'), 'https://javdb.com/v/bbb');
  assert.equal(pickExactCodeLink(html, 'ABP-999'), null);
});

test('jp-scrape: TMDB 垃圾条目过滤', () => {
  assert.equal(looksJunkTmdbMatch({ title: 'ABP-123', overview: '11111' }, 'ABP-123'), true);
  assert.equal(looksJunkTmdbMatch({ title: 'Real Title', overview: '11111' }, 'ABP-123'), false);
  assert.equal(looksJunkTmdbMatch({ title: 'Real Title', overview: '剧情简介' }, 'ABP-123'), false);
});
test('jp-actor: 归一化与精确匹配（模糊结果不认）', async () => {
  const m = await import('../src/modules/video/jp-actor');
  assert.equal(m.actorKey(' 三上 悠亚 '), m.actorKey('三上悠亜'));
  assert.equal(m.sameActorName('三上悠亚', '三上悠亜'), true);
  assert.equal(m.sameActorName('汁系', '三上悠亚'), false);
  assert.equal(m.isDeadActorThumb(''), true);
  assert.equal(m.isDeadActorThumb('D:\\pic\\a.jpg'), true);
  assert.equal(m.isDeadActorThumb('https://x.test/a.webp'), false);

  const html =
    '<a href="/actors/1"><img src="https://x.test/a.jpg">三上悠亚</a>' +
    '<a href="/actors/2"><img src="https://x.test/b.jpg">汁系</a>';
  const picked = m.pickExactActor(html, '三上悠亜');
  assert.ok(picked);
  assert.equal(picked!.name, '三上悠亚');
  assert.equal(m.pickExactActor(html, '丸一二三'), null);
});

test('jp-actor: 维基 raw 解析三围与身高', async () => {
  const m = await import('../src/modules/video/jp-actor');
  const p = m.parseWikiProfile('|身長 = 159\n|スリーサイズ = B88 W58 H88\n|生年月日 = 1993年8月29日\n|出身地 = 東京都');
  assert.equal(p.heightCm, 159);
  assert.equal(p.bust, 88);
  assert.equal(p.waist, 58);
  assert.equal(p.hips, 88);
  assert.equal(p.birthday, '1993年8月29日');
});

test('jp-rank: 榜单解析与封面清洗', async () => {
  const m = await import('../src/modules/video/jp-rank');
  const html =
    '<a href="/v/abc" title="ABP-123 某标题"><img src="http://c.test/a.jpg"></a>' +
    '<a href="/v/def" title="ABC-9 另一部"><img src="https://c.test/b.jpg"></a>';
  const items = m.parseRanking(html);
  assert.equal(items.length, 2);
  assert.equal(items[0].code, 'ABP-123');
  assert.equal(items[0].coverUrl, 'https://c.test/a.jpg');
  assert.equal(m.cleanCoverUrl('javascript:alert(1)'), null);
});

test('subtitle: 解析下载页链接与最新中文字幕', async () => {
  const m = await import('../src/modules/video/subtitle-fetch');
  const searchHtml = '<a href="/movie123/some-slug">ABP-123</a>';
  assert.equal(m.pickMovieLink(searchHtml, 'ABP-123'), '/movie123/some-slug');
  const subHtml =
    '<a href="/movie123/x/subtitles/zh/11">旧</a>' +
    '<a href="/movie123/x/subtitles/zh/42">新</a>';
  assert.deepEqual(m.pickLatestChineseSub(subHtml), {
    subId: '42',
    href: '/movie123/x/subtitles/zh/42',
  });
  // UTF-16LE BOM
  const utf16 = Buffer.concat([Buffer.from([0xff, 0xfe]), Buffer.from('你好', 'utf16le')]);
  assert.equal(m.decodeSubtitle(utf16), '你好');
});

test('pt selection: 关键词变体与标题匹配', async () => {
  const s = await import('../src/modules/pt/selection');
  assert.deepEqual(s.buildKeywordVariants({ title: '罗小黑战记', originalTitle: 'The Legend of Hei', year: '2019' }), [
    'The Legend of Hei 2019',
    '罗小黑战记 2019',
    'The Legend of Hei',
    '罗小黑战记',
  ]);
  assert.deepEqual(s.buildKeywordVariants({ title: '某剧' }, 2), ['某剧 S02', '某剧 Season 2']);
  assert.ok(s.titleMatchScore('The Legend of Hei 2 2026 1080p', { title: '罗小黑战记', originalTitle: 'The Legend of Hei' }) >= 0.5);
  assert.ok(s.titleMatchScore('Completely Different', { title: '罗小黑战记' }) < 0.5);
});

test('pt selection: 硬过滤与择种排序', async () => {
  const s = await import('../src/modules/pt/selection');
  const base = { siteId: 'a', torrentId: '1', title: 'Movie 2024 1080p' };
  assert.equal(s.hardFilter({ maxSizeBytes: 100 }, { ...base, sizeBytes: 200 }, null).reason, 'SIZE_EXCEEDED');
  assert.equal(s.hardFilter({ minSeeders: 5 }, { ...base, seeders: 2 }, null).reason, 'SEEDERS_TOO_LOW');
  assert.equal(
    s.hardFilter({ excludedKeywords: ['cam'] }, { ...base, title: 'Movie CAM 1080p' }, null).reason,
    'EXCLUDED_KEYWORD:cam',
  );
  assert.equal(
    s.hardFilter({ season: 2 }, { ...base, title: 'Movie S01 1080p' }, null).reason,
    'SEASON_MISMATCH',
  );
  // 2160p 优先于 1080p，其次做种多
  const rule = { minSeeders: 0 };
  const picked = s.selectBest(rule, [
    { ...base, torrentId: 'a', title: 'M 1080p', resolution: '1080p', seeders: 99, sizeBytes: 1 },
    { ...base, torrentId: 'b', title: 'M 2160p', resolution: '2160p', seeders: 1, sizeBytes: 9 },
  ], null);
  assert.equal(picked.selected?.torrentId, 'b');
  assert.ok(picked.reason.includes('选中'));
});

test('pt selection: 动画原声豁免音轨要求', async () => {
  const s = await import('../src/modules/pt/selection');
  const pass = s.applySmartFilter({
    filter: { audioLangs: ['zh'] },
    candidate: { siteId: 'a', torrentId: '1', title: 'Movie 2024 1080p' },
    isAnimation: true,
    originalLanguage: 'zh',
  });
  assert.equal(pass.pass, true);
  const fail = s.applySmartFilter({
    filter: { audioLangs: ['zh'] },
    candidate: { siteId: 'a', torrentId: '1', title: 'Movie 2024 1080p' },
    isAnimation: true,
    originalLanguage: 'ja',
  });
  assert.equal(fail.reason, 'AUDIO_MISSING');
});

test('pt search: NexusPHP 行解析', async () => {
  const m = await import('../src/modules/pt/search');
  assert.equal(m.parseSize('1.5 GB'), Math.round(1.5 * 1024 ** 3));
  const html =
    '<table><tr><td><a href="details.php?id=11&hit=1">Movie 2024 1080p</a></td>' +
    '<td>1.5 GB</td><td>12</td><td>3</td><td>2026-01-01</td>' +
    '<td><a href="download.php?id=11">DL</a></td></tr>' +
    '<tr><td><a href="details.php?id=12&hit=1">Movie 2024 2160p</a></td>' +
    '<td>8 GB</td><td>40</td><td>1</td><td>2026-01-02</td>' +
    '<td><a href="download.php?id=12">DL</a></td></tr></table>';
  const items = m.parseTorrentPage(html, 'http://pt.local');
  assert.equal(items.length, 2);
  assert.equal(items[0].torrentId, '11');
  assert.equal(items[0].resolution, '1080p');
  assert.equal(items[0].seeders, 12);
  assert.equal(items[0].downloadUrl, 'http://pt.local/download.php?id=11');
});

test('pt transmission: 409 取 session 后重试', async () => {
  const m = await import('../src/modules/pt/transmission');
  let calls = 0;
  const fakeFetch = async (_url, init) => {
    calls += 1;
    const headers = (init && init.headers) || {};
    if (!headers['x-transmission-session-id']) {
      return new Response('', { status: 409, headers: { 'x-transmission-session-id': 'abc' } });
    }
    return new Response(
      JSON.stringify({ result: 'success', arguments: { 'torrent-added': { id: 7, name: 't' } } }),
      { status: 200, headers: { 'content-type': 'application/json' } },
    );
  };
  const r = await m.addTorrent({ url: 'http://tr.local' }, 'http://pt.local/download.php?id=1', {
    fetchImpl: fakeFetch,
  });
  assert.equal(r.ok, true);
  assert.equal(r.id, 7);
  assert.equal(calls, 2);
});


test('douban: 榜单与评分解析（同名不同年不认）', async () => {
  const d = await import('../src/modules/discover/douban');
  const items = d.parseChart({
    subjects: [
      { id: '1', title: '甲', rate: '8.7', cover: 'https://img/1.jpg', url: 'https://movie.douban.com/subject/1/' },
      { id: '2', title: '乙', rate: '', cover: '', url: '' },
    ],
  });
  assert.equal(items.length, 2);
  assert.equal(items[0].rating, 8.7);
  assert.equal(items[1].rating, null);

  const list = [
    { id: '11', title: '流浪地球', year: '2019' },
    { id: '12', title: '流浪地球', year: '2023' },
    { id: '13', title: '完全不同的片', year: '2019' },
  ];
  assert.equal(d.pickExactSubject(list, '流浪地球', '2023')?.id, '12');
  assert.equal(d.pickExactSubject(list, '流浪地球', '2021'), null);
  assert.equal(d.parseRating({ rating: { value: 7.9 } }), 7.9);
  assert.equal(d.parseRating({}), null);
});

test('pt mteam: 专有 API 解析与下载链接', async () => {
  const m = await import('../src/modules/pt/mteam');
  const items = m.parseMTeam(
    {
      data: {
        data: [
          {
            id: '99',
            name: 'Movie 2024 2160p WEB-DL',
            size: 8589934592,
            status: { seeders: 12, leechers: 3 },
            infoHash: 'a'.repeat(40),
          },
        ],
      },
    },
    'http://mt.local',
    'KEY123',
  );
  assert.equal(items.length, 1);
  assert.equal(items[0].seeders, 12);
  assert.equal(items[0].downloadUrl, 'http://mt.local/api/torrent/download/99?apiKey=KEY123');
  assert.deepEqual(m.categoryIds('movie'), ['401']);
  assert.deepEqual(m.categoryIds('all'), []);
});
