#!/usr/bin/env node
/**
 * 动态照片 / 视频元数据验收（真实服务层，不 mock）：
 *   扫描识别 motion（JPEG 尾部附 mp4）与 apple（同名 .mov 配对）
 *   → /photo/live 的 200 全量 / Range 206 / ETag 304 / 越界 416 / 404
 *   → 逐字节比对「虚拟文件」与原 JPEG 尾部，确认偏移没有错位
 *
 * 需 Electron 运行时（better-sqlite3 为 Electron ABI），脚本自动自举。
 * 用法：node tool/check/photo-media-smoke.js
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

process.env.COLANAS_LOG_FILE = '0';
process.chdir(root);

const md5 = (b) => crypto.createHash('md5').update(b).digest('hex');

/**
 * 复用 photo-smoke.js 里已经验证过「ffmpeg 能真解码」的 640x480 灰度 JPEG，
 * 避免在这儿再内联一份 6KB base64。取不到就直接用最小 SOI/EOI —— 本用例
 * 只关心动态照片的字节区间，不关心尺寸解析。
 */
function realJpeg() {
  try {
    const src = fs.readFileSync(path.join(__dirname, 'photo-smoke.js'), 'utf8');
    const m = /const GRAY_JPEG_BASE64\s*=\s*'([^']+)'/.exec(src);
    if (m) return Buffer.from(m[1], 'base64');
  } catch {
    /* 退化路径见下 */
  }
  return Buffer.from([0xff, 0xd8, 0xff, 0xd9]);
}

/** 在 SOI 之后插一个 APP1/XMP 段；Motion Photo 的 Item:Length 就写在里面 */
function jpegWithXmp(jpeg, xmp) {
  const body = Buffer.concat([
    Buffer.from('http://ns.adobe.com/xap/1.0/\0', 'latin1'),
    Buffer.from(xmp, 'latin1'),
  ]);
  const seg = Buffer.alloc(4 + body.length);
  seg.writeUInt16BE(0xffe1, 0);
  seg.writeUInt16BE(body.length + 2, 2);
  body.copy(seg, 4);
  return Buffer.concat([jpeg.subarray(0, 2), seg, jpeg.subarray(2)]);
}

/** 确定性填充，前后都能按字节比对；开头塞 ftyp 让它像个 mp4 */
function payload(n) {
  const b = Buffer.alloc(n);
  for (let i = 0; i < n; i += 1) b[i] = (i * 31 + 7) & 0xff;
  b.write('ftyp', 0, 'latin1');
  return b;
}

const LIVE_N = 100 * 1024; // 必须 >= exif.ts 的 LIVE_MIN_BYTES(64KB)
const MOV_N = 40 * 1024; // 必须 >= media-meta.ts 的 LIVE_MOV_MIN_BYTES(32KB)
const live = payload(LIVE_N);
const mov = payload(MOV_N).subarray();
mov.write('moov', 0, 'latin1');

const xmp = (n) =>
  '<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">' +
  '<rdf:Description xmlns:GCamera="http://ns.google.com/photos/1.0/camera/" ' +
  'GCamera:MotionPhoto="1" GCamera:MotionPhotoVersion="1">' +
  '<GCamera:ContainerItem><Container:Directory ' +
  'xmlns:Container="http://ns.google.com/photos/1.0/container/" ' +
  'xmlns:Item="http://ns.google.com/photos/1.0/container/item/">' +
  `<Container:Item Item:Mime="video/mp4" Item:Semantic="MotionPhoto" Item:Length="${n}"/>` +
  '</Container:Directory></GCamera:ContainerItem>' +
  '</rdf:Description></rdf:RDF></x:xmpmeta>';

/**
 * 旧 MicroVideoOffset：N 是从 EOF 回退的字节数（即视频长度），
 * 不是「从文件开头的偏移」。PresentationTimestampUs 是微秒时间戳，
 * 故意放在 Offset 前面（且取一个明显不同的值），验证不会把它当偏移量。
 */
const microXmp = (n, ts) =>
  '<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">' +
  '<rdf:Description xmlns:GCamera="http://ns.google.com/photos/1.0/camera/" ' +
  `GCamera:MicroVideo="1" GCamera:MicroVideoPresentationTimestampUs="${ts}" ` +
  `GCamera:MicroVideoOffset="${n}"/>` +
  '</rdf:Description></rdf:RDF></x:xmpmeta>';

/** 显式声明 MotionPhoto="0"：即便带 Item:Length 和尾部 mp4 也不能认 */
const offXmp = (n) => xmp(n).replace('GCamera:MotionPhoto="1"', 'GCamera:MotionPhoto="0"');

/** 合法 ISO BMFF ftyp box：4 字节大端 size + 'ftyp' + major_brand，后接确定性填充 */
function mp4WithFtyp(n) {
  const b = payload(n);
  b.writeUInt32BE(24, 0);
  b.write('ftyp', 4, 'latin1');
  b.write('isom', 8, 'latin1');
  b.writeUInt32BE(0, 12);
  b.write('isom', 16, 'latin1');
  b.write('mp41', 20, 'latin1');
  return b;
}

const MICRO_N = 100 * 1024;
const SAMSUNG_N = 100 * 1024;
const microPayload = payload(MICRO_N);
const samsungPayload = mp4WithFtyp(SAMSUNG_N);
const SEFT_TAG = Buffer.from('MotionPhoto_Data\0', 'latin1');

(async () => {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-photo-media-'));
  const filesRoot = path.join(dataDir, 'files');
  const photos = path.join(filesRoot, 'photos');
  fs.mkdirSync(photos, { recursive: true });

  const jpeg = realJpeg();
  const motionFile = Buffer.concat([jpegWithXmp(jpeg, xmp(LIVE_N)), live]);
  const microFile = Buffer.concat([jpegWithXmp(jpeg, microXmp(MICRO_N, 9999999)), microPayload]);
  const off0File = Buffer.concat([jpegWithXmp(jpeg, offXmp(LIVE_N)), live]);
  const samsungFile = Buffer.concat([jpeg, SEFT_TAG, samsungPayload]);
  const decoyFile = Buffer.concat([jpeg, mp4WithFtyp(SAMSUNG_N)]);
  fs.writeFileSync(path.join(photos, 'plain.jpg'), jpeg);
  fs.writeFileSync(path.join(photos, 'motion.jpg'), motionFile);
  fs.writeFileSync(path.join(photos, 'apple.jpg'), jpeg);
  fs.writeFileSync(path.join(photos, 'apple.mov'), mov);
  // ① 旧 MicroVideoOffset：offset 必须 = fileSize - N
  fs.writeFileSync(path.join(photos, 'MVIMG_micro.jpg'), microFile);
  // ② 显式 MotionPhoto="0" 不认
  fs.writeFileSync(path.join(photos, 'off0.jpg'), off0File);
  // ③ 三星/无 XMP 的 ftyp 兜底；random_photo 是「普通 JPEG + 尾部二进制」负向对照
  fs.writeFileSync(path.join(photos, 'MVIMG_samsung.jpg'), samsungFile);
  fs.writeFileSync(path.join(photos, 'random_photo.jpg'), decoyFile);
  // ④ 双文件配对：大小写混写 .Mov / .m4v
  fs.writeFileSync(path.join(photos, 'appleCase.JPG'), jpeg);
  fs.writeFileSync(path.join(photos, 'appleCase.Mov'), mov);
  fs.writeFileSync(path.join(photos, 'appleM4v.JPG'), jpeg);
  fs.writeFileSync(path.join(photos, 'appleM4v.m4v'), mov);
  // 独立视频：不被任何图片配对，应照常入库
  fs.writeFileSync(path.join(photos, 'standalone.mp4'), mov);

  process.env.COLANAS_DEV_TOKEN = '1';
  process.env.COLANAS_FILES_ROOT = filesRoot;
  process.env.COLANAS_JWT_SECRET = 'test-secret-0123456789abcdef';

  const k = await startKernel({ dataDir, port: 0, listen: false });
  const app = k.app;
  const results = [];
  const check = (name, ok, detail) => results.push({ name, ok: !!ok, detail: detail || '' });

  const token = async (sub, scopes) => {
    const r = await app.inject({
      method: 'POST',
      url: '/api/v1/auth/dev-token',
      payload: { sub, scopes },
    });
    return { authorization: 'Bearer ' + r.json().token };
  };
  const bearer = await token('u1', ['photo:read', 'photo:write', 'files:read']);
  const other = await token('u2', ['photo:read']);

  // 后台 AI 识别会逐张跑 ffmpeg，与本用例无关，先整体关掉
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

  r = await app.inject({ method: 'POST', url: '/api/v1/photo/scan', headers: bearer, payload: {} });
  check('scan_ok', r.statusCode === 200, 'status=' + r.statusCode + ' ' + r.body.slice(0, 120));

  r = await app.inject({
    method: 'GET',
    url: '/api/v1/photo/timeline?limit=50',
    headers: bearer,
  });
  const items = r.json().items || [];
  const byName = (n) => items.find((x) => String(x.path).endsWith(n));
  const plain = byName('plain.jpg');
  const motion = byName('motion.jpg');
  const apple = byName('apple.jpg');
  const micro = byName('MVIMG_micro.jpg');
  const off0 = byName('off0.jpg');
  const samsung = byName('MVIMG_samsung.jpg');
  const decoy = byName('random_photo.jpg');
  const appleCase = byName('appleCase.JPG');
  const appleM4v = byName('appleM4v.JPG');
  const standalone = byName('standalone.mp4');

  check('scan_motion_detected', motion && motion.liveKind === 'motion', JSON.stringify(motion));
  check('scan_apple_detected', apple && apple.liveKind === 'apple', JSON.stringify(apple));
  check(
    'scan_plain_not_live',
    plain && plain.liveKind === '' && plain.mediaKind === 'image',
    JSON.stringify(plain),
  );

  const liveOf = (id, headers) =>
    app.inject({
      method: 'GET',
      url: '/api/v1/photo/live?id=' + encodeURIComponent(id),
      headers,
    });

  // 1. 非动态照片 / 匿名 / 别人的库
  r = await liveOf(plain.id, bearer);
  check('plain_404', r.statusCode === 404, 'status=' + r.statusCode);
  r = await liveOf(motion.id, undefined);
  check('anonymous_401', r.statusCode === 401, 'status=' + r.statusCode);
  r = await liveOf(motion.id, other);
  check('other_owner_404', r.statusCode === 404, 'status=' + r.statusCode);

  // 2. motion：对外只有尾部 LIVE_N 字节，且必须逐字节等于原文件尾部
  const tail = motionFile.subarray(motionFile.length - LIVE_N);
  r = await liveOf(motion.id, bearer);
  const etag = r.headers.etag;
  check(
    'motion_200_headers',
    r.statusCode === 200 &&
      Number(r.headers['content-length']) === LIVE_N &&
      r.headers['content-type'] === 'video/mp4' &&
      r.headers['accept-ranges'] === 'bytes' &&
      !!etag,
    `status=${r.statusCode} len=${r.headers['content-length']} type=${r.headers['content-type']} etag=${etag}`,
  );
  check(
    'motion_200_bytes_exact',
    r.rawPayload.length === LIVE_N && md5(r.rawPayload) === md5(tail),
    `got=${r.rawPayload.length} ${md5(r.rawPayload)} want=${md5(tail)}`,
  );

  // 3. Range：开头 / 后缀 / 尾段 / 越界
  const ranged = (range, extra) =>
    app.inject({
      method: 'GET',
      url: '/api/v1/photo/live?id=' + encodeURIComponent(motion.id),
      headers: Object.assign({ authorization: bearer.authorization, range }, extra || {}),
    });

  r = await ranged('bytes=0-99');
  check(
    'range_prefix_206',
    r.statusCode === 206 &&
      r.headers['content-range'] === `bytes 0-99/${LIVE_N}` &&
      Number(r.headers['content-length']) === 100 &&
      md5(r.rawPayload) === md5(tail.subarray(0, 100)),
    `status=${r.statusCode} cr=${r.headers['content-range']} len=${r.rawPayload.length}`,
  );

  r = await ranged('bytes=-64');
  check(
    'range_suffix_206',
    r.statusCode === 206 &&
      r.headers['content-range'] === `bytes ${LIVE_N - 64}-${LIVE_N - 1}/${LIVE_N}` &&
      md5(r.rawPayload) === md5(tail.subarray(LIVE_N - 64)),
    `status=${r.statusCode} cr=${r.headers['content-range']} len=${r.rawPayload.length}`,
  );

  r = await ranged(`bytes=${LIVE_N - 10}-`);
  check(
    'range_open_ended_206',
    r.statusCode === 206 &&
      r.headers['content-range'] === `bytes ${LIVE_N - 10}-${LIVE_N - 1}/${LIVE_N}` &&
      r.rawPayload.length === 10 &&
      md5(r.rawPayload) === md5(tail.subarray(LIVE_N - 10)),
    `status=${r.statusCode} cr=${r.headers['content-range']} len=${r.rawPayload.length}`,
  );

  r = await ranged(`bytes=${LIVE_N}-`);
  check(
    'range_unsatisfiable_416',
    r.statusCode === 416 && r.headers['content-range'] === `bytes */${LIVE_N}`,
    `status=${r.statusCode} cr=${r.headers['content-range']}`,
  );

  // 4. 条件请求
  r = await ranged('bytes=0-9', { 'if-none-match': etag });
  check('etag_304', r.statusCode === 304, 'status=' + r.statusCode);
  r = await ranged('bytes=0-9', { 'if-range': '"stale"' });
  check(
    'if_range_stale_falls_back_200',
    r.statusCode === 200 && r.rawPayload.length === LIVE_N,
    `status=${r.statusCode} len=${r.rawPayload.length}`,
  );

  // 5. apple：直接发同名 .mov
  r = await liveOf(apple.id, bearer);
  check(
    'apple_200_bytes_exact',
    r.statusCode === 200 &&
      Number(r.headers['content-length']) === MOV_N &&
      r.headers['content-type'] === 'video/quicktime' &&
      md5(r.rawPayload) === md5(mov),
    `status=${r.statusCode} len=${r.rawPayload.length} type=${r.headers['content-type']}`,
  );

  // ===== 多品牌识别扩展用例 =====

  // ① 旧 MicroVideoOffset：视频长度 = N，起点 = fileSize - N（字节级比对尾部载荷）
  check('scan_micro_detected', micro && micro.liveKind === 'motion', JSON.stringify(micro));
  r = await liveOf(micro.id, bearer);
  const microTail = microFile.subarray(microFile.length - MICRO_N);
  check(
    'micro_200_bytes_exact',
    r.statusCode === 200 && r.rawPayload.length === MICRO_N && md5(r.rawPayload) === md5(microTail),
    `status=${r.statusCode} len=${r.rawPayload.length} got=${md5(r.rawPayload)} want=${md5(microTail)}`,
  );
  // 若把 off 误当成「从开头偏移」，对外尺寸会变成 fileSize - N（约几 KB）而非 N
  const buggySize = microFile.length - MICRO_N;
  check(
    'micro_offset_not_misread',
    r.rawPayload.length === MICRO_N && r.rawPayload.length !== buggySize,
    `correct=${MICRO_N} buggy=${buggySize} got=${r.rawPayload.length}`,
  );

  // ② 显式 MotionPhoto="0" 不认
  check('scan_off0_not_live', off0 && off0.liveKind === '', JSON.stringify(off0));
  r = await liveOf(off0.id, bearer);
  check('off0_live_404', r.statusCode === 404, 'status=' + r.statusCode);

  // ③ 三星 / 无 XMP 的 ftyp 兜底
  check('scan_samsung_detected', samsung && samsung.liveKind === 'motion', JSON.stringify(samsung));
  r = await liveOf(samsung.id, bearer);
  check(
    'samsung_200_bytes_exact',
    r.statusCode === 200 &&
      r.rawPayload.length === SAMSUNG_N &&
      md5(r.rawPayload) === md5(samsungPayload),
    `status=${r.statusCode} len=${r.rawPayload.length} got=${md5(r.rawPayload)} want=${md5(samsungPayload)}`,
  );
  // 负向：普通 JPEG 尾部即便有合法 ftyp，缺动态照片线索也不能认
  check('scan_decoy_not_live', decoy && decoy.liveKind === '', JSON.stringify(decoy));

  // ④ 双文件配对：大小写混写 .Mov / .m4v
  check(
    'scan_apple_case_detected',
    appleCase && appleCase.liveKind === 'apple',
    JSON.stringify(appleCase),
  );
  r = await liveOf(appleCase.id, bearer);
  check(
    'apple_case_200_bytes_exact',
    r.statusCode === 200 && r.rawPayload.length === MOV_N && md5(r.rawPayload) === md5(mov),
    `status=${r.statusCode} len=${r.rawPayload.length} got=${md5(r.rawPayload)} want=${md5(mov)}`,
  );
  check(
    'scan_apple_m4v_detected',
    appleM4v && appleM4v.liveKind === 'apple',
    JSON.stringify(appleM4v),
  );
  r = await liveOf(appleM4v.id, bearer);
  check(
    'apple_m4v_200_bytes_exact',
    r.statusCode === 200 && r.rawPayload.length === MOV_N && md5(r.rawPayload) === md5(mov),
    `status=${r.statusCode} len=${r.rawPayload.length} got=${md5(r.rawPayload)} want=${md5(mov)}`,
  );

  // ⑤ 被配对引用的视频不出现在时间轴；独立视频照常入库
  const pairedNames = ['apple.mov', 'appleCase.Mov', 'appleM4v.m4v'];
  const leaked = items.filter((x) => pairedNames.some((n) => String(x.path).endsWith(n)));
  check(
    'paired_videos_hidden_in_timeline',
    leaked.length === 0,
    JSON.stringify(leaked.map((x) => x.path)),
  );
  check(
    'standalone_video_kept',
    standalone && standalone.mediaKind === 'video',
    JSON.stringify(standalone),
  );

  await app.close();
  try {
    fs.rmSync(dataDir, { recursive: true, force: true });
  } catch {
    /* 临时目录清理失败不影响结论 */
  }

  const failed = results.filter((x) => !x.ok);
  for (const x of results) console.log(`${x.ok ? 'PASS' : 'FAIL'}  ${x.name}  ${x.detail}`);
  console.log(`[photo-media] ${results.length - failed.length}/${results.length} passed`);
  process.exit(failed.length ? 1 : 0);
})().catch((e) => {
  console.error('[photo-media] fatal', e);
  process.exit(1);
});
