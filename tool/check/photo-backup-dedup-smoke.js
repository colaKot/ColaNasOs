#!/usr/bin/env node
/**
 * 手机相册备份「内容级去重」端到端验收（真实服务层，不 mock）。
 *
 * 覆盖用户明确担心的场景：服务端给已入库照片补充 GPS / 重编码之后，文件内容和
 * 字节数都变了，手机再拿**原图**的 size + md5 来问，仍然要判成「已存在」，
 * 不能重复上传一份。
 *
 * 链路：建库 → 扫描 → check_content(size) → check_content(size+md5)
 *      → 固化原始指纹 → 改写文件（模拟补 GPS）→ 再问三次 → 跨用户隔离。
 *
 * 需 Electron 运行时（better-sqlite3 为 Electron ABI），脚本自动自举。
 * 用法：node tool/check/photo-backup-dedup-smoke.js
 */
'use strict';

const path = require('node:path');
const fs = require('node:fs');
const os = require('node:os');
const crypto = require('node:crypto');
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
    console.error('[FATAL] 找不到 electron，请先 npm install');
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
const { sql } = require(path.join(root, 'node_modules', 'kysely'));
const {
  preserveOriginalFingerprint,
  photoItemAbs,
  contentMd5Of,
} = require(path.join(root, 'dist', 'src', 'modules', 'photo', 'content-md5'));
const {
  backfillContentMd5Batch,
} = require(path.join(root, 'dist', 'src', 'modules', 'photo', 'content-md5-backfill'));

process.env.COLANAS_LOG_FILE = '0';
process.chdir(root);

const md5 = (b) => crypto.createHash('md5').update(b).digest('hex');

/** 取 photo-smoke.js 里已验证过可解码的灰度 JPEG，避免重复内联 base64。 */
function realJpeg() {
  try {
    const src = fs.readFileSync(path.join(__dirname, 'photo-smoke.js'), 'utf8');
    const m = /const GRAY_JPEG_BASE64\s*=\s*'([^']+)'/.exec(src);
    if (m) return Buffer.from(m[1], 'base64');
  } catch {
    /* 退化到最小 JPEG */
  }
  return Buffer.from([0xff, 0xd8, 0xff, 0xd9]);
}

async function main() {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-backup-dedup-'));
  const dataDir = tmp;
  const filesRoot = path.join(tmp, 'files');
  const photos = path.join(filesRoot, 'photos');
  fs.mkdirSync(photos, { recursive: true });

  const jpeg = realJpeg();
  const original = Buffer.concat([jpeg, Buffer.alloc(4096, 0x5a)]);
  const originalSize = original.length;
  const originalMd5 = md5(original);
  fs.writeFileSync(path.join(photos, 'IMG_ORIG.JPG'), original);
  // 独立的一张，size 与上面不同，用于 absent 断言
  const other = Buffer.concat([jpeg, Buffer.alloc(8192, 0x33)]);
  fs.writeFileSync(path.join(photos, 'IMG_OTHER.JPG'), other);

  process.env.COLANAS_DEV_TOKEN = '1';
  process.env.COLANAS_FILES_ROOT = filesRoot;
  process.env.COLANAS_JWT_SECRET = 'test-secret-0123456789abcdef';
  // 关掉后台回填循环：扫描接口末尾会 kick 一次补码（生产上是对的），
  // 但它在后台异步跑，会把本用例第 6 步「只剩 1 张缺码」的前提提前吃掉，
  // 让 backfill_fills_missing_only 恒失败。这里只测 backfillContentMd5Batch
  // 这个纯函数本身，后台调度不该参与。
  process.env.COLANAS_MD5_BACKFILL = '0';

  const k = await startKernel({ dataDir, port: 0, listen: false });
  const app = k.app;
  const results = [];
  const check = (name, ok, detail) => results.push({ name, ok: !!ok, detail: detail || '' });

  const token = async (sub) => {
    const r = await app.inject({
      method: 'POST',
      url: '/api/v1/auth/dev-token',
      payload: { sub, scopes: ['photo:read', 'photo:write', 'files:read'] },
    });
    return { authorization: 'Bearer ' + r.json().token };
  };
  const bearer = await token('u1');
  const otherBearer = await token('u2');

  const post = async (items, headers) =>
    app.inject({
      method: 'POST',
      url: '/api/v1/photo/backup/check_content',
      headers: headers || bearer,
      payload: { items },
    });

  try {
    await app.inject({
      method: 'POST',
      url: '/api/v1/photo/ai/config',
      headers: bearer,
      payload: {
        faceEnabled: false,
        placeEnabled: false,
        activityEnabled: false,
        ocrEnabled: false,
        similarEnabled: false,
      },
    });

    let r = await app.inject({
      method: 'POST',
      url: '/api/v1/photo/libraries',
      headers: bearer,
      payload: { name: 'Media', path: '/photos' },
    });
    check('library_create', r.statusCode === 200, 'status=' + r.statusCode);

    r = await app.inject({
      method: 'POST',
      url: '/api/v1/photo/scan',
      headers: bearer,
      payload: {},
    });
    check('scan_ok', r.statusCode === 200, 'status=' + r.statusCode + ' ' + r.body.slice(0, 120));

    // ---- 0) 真库形态回归：老库 rel_path 存的是绝对路径（G:/...），
    //        不能用 resolveInRoot(filesRoot, relPath) 去拼，否则会 403 而算不出码 ----
    const absRelPath = path.join(photos, 'IMG_ORIG.JPG').replace(/\\/g, '/');
    const resolvedAbs = photoItemAbs('photos', absRelPath);
    check(
      'absolute_rel_path_resolves',
      path.resolve(resolvedAbs) === path.resolve(absRelPath),
      'resolved=' + resolvedAbs,
    );
    const absMd5 = await contentMd5Of(resolvedAbs);
    check('absolute_rel_path_md5_matches', absMd5 === originalMd5, 'md5=' + absMd5);

    // ---- 1) size 预检：存在的 size 不能判 absent；不存在的必须判 absent ----
    const missingSize = originalSize + 12345;
    r = await post([{ size: originalSize }, { size: missingSize }]);
    check('precheck_200', r.statusCode === 200, 'status=' + r.statusCode + ' ' + r.body.slice(0, 160));
    const pre = r.statusCode === 200 ? r.json() : { absent: [], matched: [] };
    check(
      'precheck_existing_size_present',
      !pre.absent.includes(originalSize),
      'absent=' + JSON.stringify(pre.absent),
    );
    check(
      'precheck_unknown_size_absent',
      pre.absent.includes(missingSize),
      'absent=' + JSON.stringify(pre.absent),
    );

    // ---- 2) 内容比对：content_md5 惰性补齐后命中 matched ----
    r = await post([{ size: originalSize, md5: originalMd5 }]);
    const first = r.statusCode === 200 ? r.json() : { matched: [] };
    check(
      'content_matched_after_lazy_hash',
      first.matched.includes(originalMd5),
      'matched=' + JSON.stringify(first.matched) + ' hashed=' + first.hashed,
    );
    check('lazy_hash_wrote_one_row', first.hashed === 1, 'hashed=' + first.hashed);

    // ---- 3) 模拟「服务端补充 GPS」：改写前先固化原始指纹 ----
    const rows = (
      await sql`
        select p.id, p.rel_path, p.size, p.orig_size, p.content_md5, l.root_path
          from photo_items p join photo_libraries l on l.id = p.library_id
         where p.rel_path like '%IMG_ORIG.JPG%'
      `.execute(k.db)
    ).rows;
    check('fingerprint_row_found', rows.length === 1, 'rows=' + rows.length);
    const row = rows[0];
    const fp = await preserveOriginalFingerprint(k.db, row);
    check('fingerprint_md5_preserved', fp.md5 === originalMd5, 'md5=' + fp.md5);
    check('fingerprint_orig_size_preserved', fp.origSize === originalSize, 'orig=' + fp.origSize);

    // sharp 重编码会同时改变字节内容和大小；这里追加一段 EXIF 模拟
    const rewritten = Buffer.concat([
      original,
      Buffer.from('GPS-REWRITE-SIMULATION', 'latin1'),
      Buffer.alloc(2048, 0x11),
    ]);
    fs.writeFileSync(path.join(photos, 'IMG_ORIG.JPG'), rewritten);
    const rewrittenSize = rewritten.length;
    const rewrittenMd5 = md5(rewritten);
    check('gps_rewrite_changed_bytes', rewrittenMd5 !== originalMd5, 'md5=' + rewrittenMd5);
    check('gps_rewrite_changed_size', rewrittenSize !== originalSize, 'size=' + rewrittenSize);
    await sql`update photo_items set size = ${rewrittenSize} where id = ${row.id}`.execute(k.db);

    // ---- 4) 手机拿原图来问：仍要命中，不能重传 ----
    r = await post([{ size: originalSize }]);
    const afterPre = r.statusCode === 200 ? r.json() : { absent: [originalSize] };
    check(
      'gps_rewrite_size_not_absent',
      !afterPre.absent.includes(originalSize),
      'absent=' + JSON.stringify(afterPre.absent),
    );

    r = await post([{ size: originalSize, md5: originalMd5 }]);
    const after = r.statusCode === 200 ? r.json() : { matched: [] };
    check(
      'gps_rewrite_still_matched',
      after.matched.includes(originalMd5),
      'matched=' + JSON.stringify(after.matched),
    );

    // 二次补充必须幂等：不能把指纹刷新成改写后的 md5
    const twice = Buffer.concat([rewritten, Buffer.alloc(1024, 0x22)]);
    fs.writeFileSync(path.join(photos, 'IMG_ORIG.JPG'), twice);
    await sql`update photo_items set size = ${twice.length} where id = ${row.id}`.execute(k.db);
    r = await post([{ size: originalSize, md5: originalMd5 }]);
    const afterTwice = r.statusCode === 200 ? r.json() : { matched: [] };
    check(
      'second_rewrite_idempotent',
      afterTwice.matched.includes(originalMd5),
      'matched=' + JSON.stringify(afterTwice.matched),
    );
    const finalRow = (
      await sql`select content_md5, orig_size from photo_items where id = ${row.id}`.execute(k.db)
    ).rows[0];
    check(
      'content_md5_never_overwritten',
      String(finalRow.content_md5) === originalMd5,
      'md5=' + finalRow.content_md5,
    );
    check(
      'orig_size_never_overwritten',
      Number(finalRow.orig_size) === originalSize,
      'orig_size=' + finalRow.orig_size,
    );

    // ---- 5) 去重没被搞失灵 / 用户隔离 ----
    r = await post([{ size: missingSize, md5: md5(Buffer.from('never-seen')) }]);
    const fresh = r.statusCode === 200 ? r.json() : { absent: [], matched: [] };
    check(
      'genuinely_new_photo_still_absent',
      fresh.absent.includes(missingSize) && fresh.matched.length === 0,
      'absent=' + JSON.stringify(fresh.absent),
    );

    r = await post([{ size: originalSize, md5: originalMd5 }], otherBearer);
    const crossUser = r.statusCode === 200 ? r.json() : { absent: [], matched: [] };
    check(
      'other_user_cannot_see_photo',
      crossUser.matched.length === 0 && crossUser.absent.includes(originalSize),
      'matched=' + JSON.stringify(crossUser.matched) + ' absent=' + JSON.stringify(crossUser.absent),
    );

    // ---- 6) 自动全库回填：老库码全空就靠它补，且必须可续跑 / 不覆盖已固化指纹 ----
    // 本测试库共 2 张：IMG_ORIG 前面已被惰性补齐，只剩 IMG_OTHER 缺码。
    const bf = await backfillContentMd5Batch(k, 10);
    check(
      'backfill_fills_missing_only',
      bf.done === 1 && bf.remaining === 0,
      JSON.stringify(bf),
    );
    const bf2 = await backfillContentMd5Batch(k, 10);
    check('backfill_resumable_idempotent', bf2.done === 0 && bf2.remaining === 0, JSON.stringify(bf2));
    const allMd5 = (
      await sql`select rel_path, content_md5 from photo_items where in_trash = 0`.execute(k.db)
    ).rows;
    check(
      'backfill_all_rows_have_md5',
      allMd5.length === 2 && allMd5.every((x) => /^[0-9a-f]{32}$/.test(String(x.content_md5 || ''))),
      JSON.stringify(allMd5),
    );
    check(
      'backfill_did_not_overwrite_fingerprint',
      String(
        allMd5.find((x) => String(x.rel_path).includes('IMG_ORIG'))?.content_md5 || '',
      ) === originalMd5,
      'md5 应保持改写前固化的原图指纹',
    );

    // ---- 7) 在 NAS 上删掉的照片，以后不能再被手机传上来 ----
    // 用户口径：「就当传过就行了，不要说我在 NAS 上删了，以后又天天给我传上去。」
    // 关键在清空回收站之后：行被物理删除，photo_items 里已经查不到，
    // 只能靠 photo_deleted_fp 墓碑拦住重传。
    const otherSize = other.length;
    const otherMd5 = md5(other);
    const otherId = (
      await sql`select id from photo_items where rel_path like '%IMG_OTHER.JPG'`.execute(k.db)
    ).rows[0].id;

    r = await post([{ size: otherSize, md5: otherMd5 }]);
    check(
      'before_delete_matched',
      (r.json().matched || []).includes(otherMd5),
      JSON.stringify(r.json().matched),
    );

    r = await app.inject({
      method: 'POST',
      url: '/api/v1/photo/delete',
      headers: bearer,
      payload: { ids: [otherId], toTrash: true },
    });
    check(
      'trash_ok',
      r.statusCode === 200 && Number(r.json().count) === 1,
      r.body.slice(0, 120),
    );

    r = await post([{ size: otherSize, md5: otherMd5 }]);
    check(
      'trashed_photo_still_matched',
      (r.json().matched || []).includes(otherMd5),
      JSON.stringify(r.json()),
    );

    r = await app.inject({
      method: 'POST',
      url: '/api/v1/photo/trash/empty',
      headers: bearer,
      payload: {},
    });
    check('trash_empty_ok', r.statusCode === 200, r.body.slice(0, 120));

    const gone = (
      await sql`select count(*) as c from photo_items where id = ${otherId}`.execute(k.db)
    ).rows[0];
    check('purge_removed_row', Number(gone.c) === 0, 'rows=' + gone.c);

    const tomb = (
      await sql`select count(*) as c from photo_deleted_fp where owner_id = 'u1'`.execute(k.db)
    ).rows[0];
    check('tombstone_written', Number(tomb.c) >= 1, 'rows=' + tomb.c);

    r = await post([{ size: otherSize, md5: otherMd5 }]);
    check(
      'purged_photo_still_matched',
      (r.json().matched || []).includes(otherMd5),
      JSON.stringify(r.json()),
    );

    // 墓碑按 owner 隔离：别人的删除记录不能影响这个账号
    r = await post([{ size: otherSize, md5: otherMd5 }], otherBearer);
    check(
      'tombstone_isolated_by_user',
      (r.json().matched || []).length === 0 &&
        (r.json().absent || []).includes(otherSize),
      JSON.stringify(r.json()),
    );
  } finally {
    await app.close();
    fs.rmSync(tmp, { recursive: true, force: true });
  }

  let bad = 0;
  for (const x of results) {
    console.log(`${x.ok ? 'PASS' : 'FAIL'}  ${x.name}${x.detail ? '  ' + x.detail : ''}`);
    if (!x.ok) bad += 1;
  }
  console.log(`[backup-dedup] ${results.length - bad}/${results.length} passed`);
  process.exit(bad ? 1 : 0);
}

main().catch((err) => {
  console.error('[backup-dedup] FATAL', err && err.stack ? err.stack : err);
  process.exit(1);
});
