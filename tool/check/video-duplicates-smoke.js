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
  // 同番号一律同组，但**全是分片且每个分片只有一份**时不是重复（2026-11-03 反馈）：
  // 一部片被切成 CD1 + CD2 是正常发行形态，不该出现在「重复视频」里。
  check('duplicates_one_group', (data.groups || []).length === 1, 'groups=' + (data.groups || []).length);
  const group = (data.groups || []).find((g) => g.items.some((i) => i.id === 'v1080')) || { items: [] };
  check('duplicates_two_items', group.items.length === 2, 'items=' + group.items.length);
  check('duplicates_scanned', data.scanned === 5, 'scanned=' + data.scanned);
  check(
    'cd_parts_not_duplicate',
    !(data.groups || []).some((g) => g.items.some((i) => i.id === 'vpart1' || i.id === 'vpart2')),
    'groups=' + (data.groups || []).map((g) => g.items.map((i) => i.id).join('+')).join(' | '),
  );

  // 2. 演员键：NFO 演员归一化后，查重条目与 /video/actors 必须是同一个键
  //    （查重页的「演员排除」靠它把「三上悠亜 / 三上悠亚」认成一个人）
  await k.db
    .updateTable('video_items')
    .set({ nfo_actors: '["三上悠亜","Yua Mikami"]' })
    .where('id', '=', 'v1080')
    .execute();
  r = await app.inject({ method: 'GET', url: '/api/v1/video/duplicates', headers: bearer });
  const tagged =
    ((r.json().groups || [])[0] || { items: [] }).items.find((i) => i.id === 'v1080') || {};
  check(
    'dup_actor_keys',
    Array.isArray(tagged.actorKeys) && tagged.actorKeys.includes('三上悠亚'),
    JSON.stringify(tagged.actorKeys),
  );
  r = await app.inject({ method: 'GET', url: '/api/v1/video/actors?q=悠', headers: bearer });
  const actorList = r.json();
  check(
    'actors_search',
    r.statusCode === 200 && (actorList.items || []).some((a) => a.key === '三上悠亚'),
    'status=' + r.statusCode + ' items=' + (actorList.items || []).length,
  );

  // 3. 演员排除：命中就整组不返回（组里没 NFO / 没封面的那份也跟着消失）
  r = await app.inject({
    method: 'GET',
    url: '/api/v1/video/duplicates?excludeActors=' + encodeURIComponent('三上悠亜'),
    headers: bearer,
  });
  check(
    'exclude_actor_hides_group',
    (r.json().groups || []).length === 0,
    'groups=' + (r.json().groups || []).length,
  );
  r = await app.inject({
    method: 'GET',
    url: '/api/v1/video/duplicates?excludeActors=' + encodeURIComponent('无关的人'),
    headers: bearer,
  });
  check(
    'exclude_actor_keeps_others',
    (r.json().groups || []).length === 1,
    'groups=' + (r.json().groups || []).length,
  );

  // 5. 同一个分片有两份 → 这才算重复（CD1 去重，CD2 不参与）
  await k.db
    .insertInto('video_items')
    .values({
      id: 'vpart1b',
      library_id: libId,
      rel_path: 'movies/Part.Movie.CD1.1080p.mkv',
      title: 'Part.Movie.CD1.1080p.mkv',
      width: 1920,
      height: 1080,
      duration: 6000,
      size: 62,
      mtime: now * 1000,
      created_at: now,
      media_type: 'video',
      nfo_name: 'Part Movie',
      nfo_year: 2020,
    })
    .execute();
  r = await app.inject({ method: 'GET', url: '/api/v1/video/duplicates', headers: bearer });
  const cdGroup = (r.json().groups || []).find((g) => g.items.some((i) => i.id === 'vpart1')) || { items: [] };
  // 同番号仍然同组：CD1 / CD1 副本 / CD2 三条在一组里，但「建议保留」按分片各留一条
  // → CD2 保留（只有一份）、CD1 里留一条，只剩 1 条待删。
  check(
    'cd_same_part_duplicate',
    cdGroup.items.length === 3 &&
      cdGroup.items.filter((i) => i.part === 'cd1').length === 2 &&
      cdGroup.items.filter((i) => i.suggestedKeep).length === 2 &&
      cdGroup.items.filter((i) => !i.suggestedKeep).length === 1 &&
      cdGroup.items.filter((i) => !i.suggestedKeep)[0].part === 'cd1',
    'items=' + cdGroup.items.map((i) => i.id + ':' + i.part + (i.suggestedKeep ? ':keep' : ':del')).join(','),
  );

  // 4. 建议保留高分辨率那条
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

  // 6. 索引与库计数同步（6 行 = 5 条原始 + 步骤 5 补的 CD1 副本；删掉 1 条后 5 行）
  const left = await k.db.selectFrom('video_items').select(['id']).execute();
  check('index_row_removed', left.length === 5, 'rows=' + left.length);
  const lib = await k.db.selectFrom('video_libraries').select(['items']).where('id', '=', libId).executeTakeFirst();
  check('library_count_recomputed', Number(lib.items) === 5, 'items=' + lib.items);

  // 7. 再查不再成组
  r = await app.inject({ method: 'GET', url: '/api/v1/video/duplicates', headers: bearer });
  const again = r.json();
  // Movie 组已消失（只剩 Part.Movie 那组，它是同一部片的两段，属于预期）
  check(
    'group_gone_after_delete',
    !(again.groups || []).some((g) => g.items.some((i) => i.id === 'v2160')),
    'groups=' + (again.groups || []).length,
  );

  // 8. 空 ids 拒绝
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/video/items/delete',
    headers: bearer,
    payload: { ids: [] },
  });
  check('delete_requires_ids', r.statusCode === 400, 'status=' + r.statusCode);

  // 后台删除任务：入队 → 轮询 → 完成（查重页的进度弹窗走的就是这条链路）
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/video/items/delete-task',
    payload: { ids: ['v2160'] },
    headers: bearer,
  });
  const taskId = r.json().taskId || '';
  check(
    'delete_task_created',
    r.statusCode === 200 && !!taskId,
    'status=' + r.statusCode + ' task=' + taskId,
  );
  let taskState = 'pending';
  let taskDone = 0;
  let taskTotal = 0;
  for (let i = 0; i < 80; i += 1) {
    await new Promise((res) => setTimeout(res, 100));
    const t = await app.inject({
      method: 'GET',
      url: '/api/v1/tasks/' + taskId,
      headers: bearer,
    });
    if (t.statusCode !== 200) break;
    const j = t.json();
    taskState = j.state;
    taskDone = j.done_count || 0;
    taskTotal = j.total_count || 0;
    if (['done', 'failed', 'canceled'].includes(taskState)) break;
  }
  check(
    'delete_task_done',
    taskState === 'done' && taskTotal === 1 && taskDone === 1,
    `state=${taskState} ${taskDone}/${taskTotal}`,
  );

  // 永久删除（用户勾掉「放入回收站」）：文件直接消失，不进回收站
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/video/items/delete',
    payload: { ids: ['vother'], permanent: true },
    headers: bearer,
  });
  const perm = r.json();
  check(
    'permanent_delete_ok',
    r.statusCode === 200 && (perm.done || []).includes('vother'),
    'status=' + r.statusCode + ' done=' + JSON.stringify(perm.done),
  );
  check(
    'permanent_file_gone',
    !fs.existsSync(path.join(filesRoot, 'movies', 'Other.Film.2019.mkv')),
    'still on disk',
  );
  check('permanent_no_trash_batch', perm.trashedTo === '', 'trashedTo=' + perm.trashedTo);

  // 9. 「完整版 + CD1 + CD2」同样不算重复：三段各只有一份，没有任何"多出来的那份"
  for (const r2 of [
    { id: 'vfull2', name: 'Full.Movie.2021.mkv' },
    { id: 'vfull2cd1', name: 'Full.Movie.2021.CD1.mkv' },
    { id: 'vfull2cd2', name: 'Full.Movie.2021.CD2.mkv' },
  ]) {
    await k.db
      .insertInto('video_items')
      .values({
        id: r2.id,
        library_id: libId,
        rel_path: 'movies/' + r2.name,
        title: r2.name,
        width: 1920,
        height: 1080,
        duration: 6000,
        size: 70,
        mtime: now * 1000,
        created_at: now,
        media_type: 'video',
        nfo_name: 'Full Movie',
        nfo_year: 2021,
      })
      .execute();
  }
  r = await app.inject({ method: 'GET', url: '/api/v1/video/duplicates', headers: bearer });
  const withFull = r.json().groups || [];
  check(
    'full_plus_parts_not_duplicate',
    !withFull.some((g) => g.items.some((i) => i.id === 'vfull2' || i.id === 'vfull2cd1')),
    'groups=' + withFull.map((g) => g.items.map((i) => i.id).join('+')).join(' | '),
  );

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
