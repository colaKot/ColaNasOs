#!/usr/bin/env node
/**
 * 影片查重 + 删除闭环验收：
 *   造 2 条同名不同分辨率 + 1 条独立 → 查重分组 → 建议保留高分辨率那条
 *   → 删掉另一条 → 文件进回收站 / 索引消失 / 库条目数重算 → 再查不再成组
 *
 * 依赖 Electron 运行时（better-sqlite3 ABI），脚本自动自举。
 */
'use strict';

const path = require('node:path');
const fs = require('node:fs');
const os = require('node:os');
const { spawnSync } = require('node:child_process');

if (!process.versions.electron) {
  const exe = path.join(
    process.cwd(),
    'node_modules',
    'electron',
    'dist',
    process.platform === 'win32' ? 'electron.exe' : 'electron',
  );
  if (!fs.existsSync(exe)) {
    console.error('[FATAL] cannot find electron');
    process.exit(2);
  }
  const r = spawnSync(exe, [__filename], {
    stdio: 'inherit',
    env: Object.assign({}, process.env, { ELECTRON_RUN_AS_NODE: '1' }),
  });
  process.exit(typeof r.status === 'number' ? r.status : 1);
}

const root = path.join(__dirname, '..', '..');
const { startKernel } = require(path.join(root, 'dist', 'kernel', 'index'));

process.env.COLANAS_LOG_FILE = '0';
process.chdir(root);

let passed = 0;
let failed = 0;
const ok = (n, d) => {
  passed += 1;
  console.log('[OK]  ', n.padEnd(30), d === undefined ? '' : d);
};
const bad = (n, d) => {
  failed += 1;
  console.log('[FAIL]', n.padEnd(30), d);
};
const check = (n, c, d) => (c ? ok(n, d) : bad(n, d));

(async () => {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-vdup-'));
  const filesRoot = path.join(dataDir, 'files');
  fs.mkdirSync(path.join(filesRoot, 'movies'), { recursive: true });
  const mk = (name, bytes) => fs.writeFileSync(path.join(filesRoot, 'movies', name), 'x'.repeat(bytes));
  mk('Movie.2020.1080p.BluRay.mkv', 100);
  mk('Movie.2020.2160p.WEB-DL.mkv', 200);
  mk('Other.Film.2019.mkv', 50);

  process.env.COLANAS_DEV_TOKEN = '1';
  process.env.COLANAS_FILES_ROOT = filesRoot;

  const k = await startKernel({ dataDir, port: 0, listen: false });
  const { app } = k;

  const bearer = {
    authorization:
      'Bearer ' +
      (await app.inject({
        method: 'POST',
        url: '/api/v1/auth/dev-token',
        payload: { sub: 'vd', scopes: ['*'] },
      })).json().token,
  };

  const libId = 'lib-movies';
  const now = Math.floor(Date.now() / 1000);
  await k.db
    .insertInto('video_libraries')
    .values({ id: libId, name: 'Movies', root_path: 'movies', created_at: now, items: 3 })
    .execute();

  const rows = [
    { id: 'v1080', name: 'Movie.2020.1080p.BluRay.mkv', w: 1920, h: 1080, size: 100, nfo: 'Movie 2020' },
    { id: 'v2160', name: 'Movie.2020.2160p.WEB-DL.mkv', w: 3840, h: 2160, size: 200, nfo: 'Movie 2020' },
    { id: 'vother', name: 'Other.Film.2019.mkv', w: 1280, h: 720, size: 50, nfo: 'Other Film 2019' },
    // 同一部片的 CD1 / CD2：NFO 同名但分片不同，**不能**合并成重复
    { id: 'vpart1', name: 'Part.Movie.CD1.mkv', w: 1280, h: 720, size: 60, nfo: 'Part Movie' },
    { id: 'vpart2', name: 'Part.Movie.CD2.mkv', w: 1280, h: 720, size: 61, nfo: 'Part Movie' },
  ];
  for (const r of rows) {
    await k.db
      .insertInto('video_items')
      .values({
        id: r.id,
        library_id: libId,
        rel_path: `movies/${r.name}`,
        title: r.name,
        width: r.w,
        height: r.h,
        duration: 6000,
        size: r.size,
        mtime: now * 1000,
        created_at: now,
        media_type: 'video',
        nfo_name: r.nfo,
        nfo_year: r.id === 'vother' ? 2019 : 2020,
        nfo_poster: r.id === 'v1080' || r.id === 'v2160' ? 'movies/poster.jpg' : null,
      })
      .execute();
  }
  // 侧车：1080 的独有 nfo / 字幕 / 专属海报；2160 的独有字幕；两条共用的 poster.jpg
  const sidecarFiles = [
    'Movie.2020.1080p.BluRay.nfo',
    'Movie.2020.1080p.BluRay.srt',
    'Movie.2020.1080p.BluRay-poster.jpg',
    'Movie.2020.2160p.WEB-DL.srt',
    'poster.jpg',
  ];
  for (const f of sidecarFiles) {
    fs.writeFileSync(path.join(filesRoot, 'movies', f), 'sidecar:' + f);
  }

  // 1. 查重：两条同名片分成一组
  let r = await app.inject({ method: 'GET', url: '/api/v1/video/duplicates', headers: bearer });
  const data = r.json();
  check('duplicates_ok', r.statusCode === 200, 'status=' + r.statusCode + ' ' + r.body.slice(0, 120));
  check('duplicates_one_group', (data.groups || []).length === 1, 'groups=' + (data.groups || []).length);
  const group = (data.groups || [])[0] || { items: [] };
  check('duplicates_two_items', group.items.length === 2, 'items=' + group.items.length);
  check('duplicates_scanned', data.scanned === 5, 'scanned=' + data.scanned);
  check(
    'cd_parts_not_grouped',
    (data.groups || []).every((g) => !g.items.some((i) => i.id === 'vpart1' || i.id === 'vpart2')),
    'groups=' + (data.groups || []).length,
  );

  // 2. 建议保留高分辨率那条
  const keep = group.items.find((i) => i.suggestedKeep);
  check('suggest_keep_4k', keep && keep.id === 'v2160', keep ? keep.id : 'none');

  // 3. 角标字段齐全（中字 / 4K / HDR / 日本片 / LTX）
  const sample = group.items[0] || {};
  const flags = ['chineseSub', 'uncensored', 'is4k', 'hdr', 'dolbyVision', 'dolbyAtmos', 'ltx', 'isJp'];
  check('item_flags_present', flags.every((f) => typeof sample[f] === 'boolean'), flags.join(','));
  check(
    'item_4k_flag_derived',
    group.items.find((i) => i.id === 'v2160').is4k === true ||
      group.items.find((i) => i.id === 'v2160').width === 3840,
    'is4k=' + group.items.find((i) => i.id === 'v2160').is4k,
  );

  // 4. 删除低分辨率那条
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/video/items/delete',
    headers: bearer,
    payload: { ids: ['v1080'] },
  });
  const del = r.json();
  check('delete_ok', r.statusCode === 200 && (del.done || []).length === 1, r.body.slice(0, 160));
  check('delete_trashed', Boolean(del.trashedTo), 'batch=' + del.trashedTo);
  check(
    'delete_sidecars',
    (del.sidecars || []).includes('Movie.2020.1080p.BluRay.nfo') &&
      (del.sidecars || []).includes('Movie.2020.1080p.BluRay.srt') &&
      (del.sidecars || []).includes('Movie.2020.1080p.BluRay-poster.jpg'),
    (del.sidecars || []).join(','),
  );
  check(
    'kept_shared_art_kept',
    fs.existsSync(path.join(filesRoot, 'movies', 'poster.jpg')),
    'shared poster removed',
  );
  check(
    'kept_sidecar_kept',
    fs.existsSync(path.join(filesRoot, 'movies', 'Movie.2020.2160p.WEB-DL.srt')),
    'kept subtitle removed',
  );

  // 5. 文件真的不在了 + 回收站里有
  check('file_gone', !fs.existsSync(path.join(filesRoot, 'movies', 'Movie.2020.1080p.BluRay.mkv')), 'still on disk');
  check(
    'file_in_trash',
    fs.existsSync(path.join(filesRoot, '.colanas-trash', del.trashedTo, 'Movie.2020.1080p.BluRay.mkv')),
    'not in trash',
  );

  // 6. 索引与库计数同步
  const left = await k.db.selectFrom('video_items').select(['id']).execute();
  check('index_row_removed', left.length === 4, 'rows=' + left.length);
  const lib = await k.db.selectFrom('video_libraries').select(['items']).where('id', '=', libId).executeTakeFirst();
  check('library_count_recomputed', Number(lib.items) === 4, 'items=' + lib.items);

  // 7. 再查不再成组
  r = await app.inject({ method: 'GET', url: '/api/v1/video/duplicates', headers: bearer });
  const again = r.json();
  check('group_gone_after_delete', (again.groups || []).length === 0, 'groups=' + (again.groups || []).length);

  // 8. 空 ids 拒绝
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/video/items/delete',
    headers: bearer,
    payload: { ids: [] },
  });
  check('delete_requires_ids', r.statusCode === 400, 'status=' + r.statusCode);

  console.log(`\n[summary] ${passed}/${passed + failed} passed`);
  await app.close();
  try {
    fs.rmSync(dataDir, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
  } catch {
    /* 句柄释放延迟 */
  }
  process.exit(failed === 0 ? 0 : 1);
})().catch((err) => {
  console.error('[FATAL]', err && err.stack ? err.stack : err);
  process.exit(1);
});
