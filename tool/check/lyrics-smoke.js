#!/usr/bin/env node
/**
 * 音乐歌词验收（`/api/v1/music/lyrics`）：
 *   内嵌 ID3v2.3 USLT（UTF-8，带 LRC 时间戳）→ 旁挂 .lrc 覆盖内嵌 → LRC `[offset:]` 与一行多时间戳
 *   → `<base>.<lang>.lrc` 双语对照（缺省中文、按 lang 切换）→ flac Vorbis comment 纯文本歌词
 *   → 无歌词返回 none → 鉴权（匿名 401 / 缺 scope 403 / 未知 id 404）
 *
 * 素材全部用脚本内联构造（ID3 / fLaC 字节），**不依赖 ffmpeg**：扫描对探测失败的音频照样入库。
 * 用法：node tool/check/lyrics-smoke.js
 */
'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
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

// 测试环境不落盘日志：临时目录在 app.close() 后立刻删除，异步日志句柄会触发 ENOTEMPTY
process.env.COLANAS_LOG_FILE = '0';

process.chdir(root);

// ------------------------------------------------------------------ 素材构造

function syncsafe(n) {
  return Buffer.from([(n >> 21) & 0x7f, (n >> 14) & 0x7f, (n >> 7) & 0x7f, n & 0x7f]);
}

/** ID3v2.3（含 USLT 帧，UTF-8 编码）；`desc` 为空串表示「主歌词」 */
function id3v23Uslt(lyrics, desc = '') {
  const descBuf = Buffer.from(desc, 'utf8');
  const body = Buffer.concat([
    Buffer.from([0x03]), // encoding 3 = UTF-8
    Buffer.from('eng', 'latin1'),
    descBuf,
    Buffer.from([0x00]), // 描述终止符
    Buffer.from(lyrics, 'utf8'),
  ]);
  const frameHeader = Buffer.alloc(10);
  frameHeader.write('USLT', 0, 'latin1');
  frameHeader.writeUInt32BE(body.length, 4);
  const frames = Buffer.concat([frameHeader, body]);
  const header = Buffer.concat([Buffer.from('ID3', 'latin1'), Buffer.from([3, 0, 0]), syncsafe(frames.length)]);
  return Buffer.concat([header, frames]);
}

/** 最小 flac 头：STREAMINFO（空）+ VORBIS_COMMENT（LYRICS=...） */
function flacWithLyrics(lyrics) {
  const vendor = Buffer.from('colanas-smoke', 'utf8');
  const comment = Buffer.from(`LYRICS=${lyrics}`, 'utf8');

  const vendorLen = Buffer.alloc(4);
  vendorLen.writeUInt32LE(vendor.length, 0);
  const count = Buffer.alloc(4);
  count.writeUInt32LE(1, 0);
  const commentLen = Buffer.alloc(4);
  commentLen.writeUInt32LE(comment.length, 0);
  const vorbis = Buffer.concat([vendorLen, vendor, count, commentLen, comment]);

  const block = (type, isLast, payload) => {
    const head = Buffer.alloc(4);
    head[0] = (isLast ? 0x80 : 0) | type;
    head.writeUIntBE(payload.length, 1, 3);
    return Buffer.concat([head, payload]);
  };

  return Buffer.concat([
    Buffer.from('fLaC', 'latin1'),
    block(0, false, Buffer.alloc(34)), // STREAMINFO 占位
    block(4, true, vorbis),
  ]);
}

/** MP4 atom：size(4) + type(4) + payload */
function atom(type, payload) {
  const head = Buffer.alloc(8);
  head.writeUInt32BE(payload.length + 8, 0);
  head.write(type, 4, 'latin1');
  return Buffer.concat([head, payload]);
}

/** `©lyr` 的内容是 data atom：type(4) + locale(4) + 文本（type=1 表示 UTF-8） */
function mp4Text(text) {
  const meta = Buffer.alloc(8);
  meta.writeUInt32BE(1, 0);
  return atom('data', Buffer.concat([meta, Buffer.from(text, 'utf8')]));
}

/** 最小 m4a：ftyp + moov(udta(meta(ilst(©lyr)))) ；`moovAtEnd` 时把 mdat 放在前面 */
function m4aWithLyrics(lyrics, moovAtEnd, mdatSize = 4096) {
  const ilst = atom('ilst', atom('\u00a9lyr', mp4Text(lyrics)));
  const meta = atom('meta', Buffer.concat([Buffer.alloc(4), ilst]));
  const moov = atom('moov', atom('udta', meta));
  const ftyp = atom('ftyp', Buffer.from('M4A isomM4A mp42', 'latin1'));
  const mdat = atom('mdat', Buffer.alloc(mdatSize, 9));
  return moovAtEnd ? Buffer.concat([ftyp, mdat, moov]) : Buffer.concat([ftyp, moov, mdat]);
}

/** 单个 ogg 页（lacing 表按 255 自动分片；本例的包都很短） */
function oggPage(packet, serial, seq, headerType) {
  const lacing = [];
  let remain = packet.length;
  while (remain >= 255) {
    lacing.push(255);
    remain -= 255;
  }
  lacing.push(remain);

  const header = Buffer.alloc(27 + lacing.length);
  header.write('OggS', 0, 'latin1');
  header[4] = 0;
  header[5] = headerType;
  header.writeUInt32LE(serial, 14);
  header.writeUInt32LE(seq, 18);
  header[26] = lacing.length;
  for (let i = 0; i < lacing.length; i += 1) header[27 + i] = lacing[i];
  return Buffer.concat([header, packet]);
}

/** Vorbis comment 包体：vendorLen + vendor + count + [len + entry]… */
function vorbisComments(magic, entries) {
  const vendor = Buffer.from('colanas-smoke', 'utf8');
  const parts = [magic];
  const vendorLen = Buffer.alloc(4);
  vendorLen.writeUInt32LE(vendor.length, 0);
  parts.push(vendorLen, vendor);
  const count = Buffer.alloc(4);
  count.writeUInt32LE(entries.length, 0);
  parts.push(count);
  for (const entry of entries) {
    const buf = Buffer.from(entry, 'utf8');
    const len = Buffer.alloc(4);
    len.writeUInt32LE(buf.length, 0);
    parts.push(len, buf);
  }
  return Buffer.concat(parts);
}

/** ogg 容器：id 包 + 注释包（两页） */
function oggWithComments(kind, entries) {
  const isOpus = kind === 'opus';
  const serial = isOpus ? 9 : 7;
  const idMagic = isOpus
    ? Buffer.from('OpusHead', 'latin1')
    : Buffer.concat([Buffer.from([1]), Buffer.from('vorbis', 'latin1')]);
  const commentMagic = isOpus
    ? Buffer.from('OpusTags', 'latin1')
    : Buffer.concat([Buffer.from([3]), Buffer.from('vorbis', 'latin1')]);
  return Buffer.concat([
    oggPage(Buffer.concat([idMagic, Buffer.alloc(24, 1)]), serial, 0, 2),
    oggPage(vorbisComments(commentMagic, entries), serial, 1, 0),
  ]);
}

const EMBEDDED_LRC = [
  '[ti:内嵌标题]',
  '[ar:内嵌艺术家]',
  '[00:01.00]第一行嵌入歌词',
  '[00:05.50]第二行嵌入歌词',
  '[00:09.123]第三行嵌入歌词',
].join('\n');

const SIDECAR_LRC = ['[offset:500]', '[00:02.00][00:04.00]旁挂 LRC 覆盖内嵌'].join('\n');

(async () => {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-lyrics-'));
  const filesRoot = path.join(dataDir, 'files');
  const songs = path.join(filesRoot, 'music');
  fs.mkdirSync(songs, { recursive: true });

  const junk = Buffer.alloc(2048, 7);
  fs.writeFileSync(path.join(songs, 'Alpha.mp3'), Buffer.concat([id3v23Uslt(EMBEDDED_LRC), junk]));
  // 双语：同目录 <base>.<lang>.lrc 作为译文（时间轴与原文有百毫秒级出入）
  fs.writeFileSync(
    path.join(songs, 'Alpha.zh-CN.lrc'),
    ['[00:01.10]第一行译文', '[00:05.40]第二行译文', '[00:09.20]第三行译文'].join('\n'),
  );
  fs.writeFileSync(
    path.join(songs, 'Alpha.en.lrc'),
    ['[00:01.00]line one', '[00:05.50]line two', '[00:09.12]line three'].join('\n'),
  );
  fs.writeFileSync(
    path.join(songs, 'Beta.mp3'),
    Buffer.concat([id3v23Uslt('[00:01.00]EMBEDDED-SHOULD-LOSE'), junk]),
  );
  fs.writeFileSync(path.join(songs, 'Beta.lrc'), SIDECAR_LRC);
  fs.writeFileSync(path.join(songs, 'Gamma.flac'), flacWithLyrics('纯文本第一句\n纯文本第二句'));
  fs.writeFileSync(path.join(songs, 'Delta.mp3'), Buffer.concat([id3v23Uslt('', ''), junk]));

  // m4a：moov 在头部（faststart）/ 在尾部（>4 MB，仅靠尾部兜底才能命中）
  const MP4_LRC = '[00:02.00]m4a 第一行\n[00:06.25]m4a 第二行';
  fs.writeFileSync(path.join(songs, 'Sigma.m4a'), m4aWithLyrics(MP4_LRC, false));
  fs.writeFileSync(path.join(songs, 'Tau.m4a'), m4aWithLyrics(MP4_LRC, true, 5 * 1024 * 1024));
  // ogg（vorbis）/ opus 的注释歌词；Eta 只有普通注释，验证 none
  fs.writeFileSync(
    path.join(songs, 'Omega.ogg'),
    oggWithComments('vorbis', ['LYRICS=ogg 纯文本一\nogg 纯文本二']),
  );
  fs.writeFileSync(
    path.join(songs, 'Zeta.opus'),
    oggWithComments('opus', ['LYRICS=[00:01.50]opus 同步行']),
  );
  fs.writeFileSync(path.join(songs, 'Eta.ogg'), oggWithComments('vorbis', ['TITLE=没有歌词']));

  process.env.COLANAS_DEV_TOKEN = '1';
  process.env.COLANAS_FILES_ROOT = filesRoot;
  process.env.COLANAS_JWT_SECRET = 'test-secret-0123456789abcdef';

  const k = await startKernel({ dataDir, port: 0, listen: false });
  const app = k.app;

  const results = [];
  const check = (name, ok, detail) => results.push({ name, ok, detail: detail || '' });

  const mkToken = async (sub, scopes) => {
    const res = await app.inject({ method: 'POST', url: '/api/v1/auth/dev-token', payload: { sub, scopes } });
    return { authorization: 'Bearer ' + res.json().token };
  };

  const reader = await mkToken('u1', ['music:read']);
  const outsider = await mkToken('u2', ['book:read']);

  let r = await app.inject({
    method: 'POST',
    url: '/api/v1/music/libraries',
    headers: reader,
    payload: { name: 'Songs', path: 'music' },
  });
  check('create_library_403_for_reader', r.statusCode === 403, 'status=' + r.statusCode);

  const writer = await mkToken('u3', ['music:read', 'music:write']);
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/music/libraries',
    headers: writer,
    payload: { name: 'Songs', path: 'music' },
  });
  check('create_library', r.statusCode === 200, 'status=' + r.statusCode);

  r = await app.inject({ method: 'POST', url: '/api/v1/music/scan', headers: writer, payload: {} });
  check('scan', r.statusCode === 200, 'status=' + r.statusCode);

  r = await app.inject({ method: 'GET', url: '/api/v1/music/list?limit=50', headers: writer });
  const items = r.json().items || [];
  const byName = (name) => items.find((t) => t.path.endsWith(name));
  const alpha = byName('Alpha.mp3');
  const beta = byName('Beta.mp3');
  const gamma = byName('Gamma.flac');
  const delta = byName('Delta.mp3');
  const sigma = byName('Sigma.m4a');
  const tau = byName('Tau.m4a');
  const omega = byName('Omega.ogg');
  const zeta = byName('Zeta.opus');
  const eta = byName('Eta.ogg');
  check('indexed_four_tracks', Boolean(alpha && beta && gamma && delta), 'n=' + items.length);
  check(
    'indexed_new_formats',
    Boolean(sigma && tau && omega && zeta && eta),
    `m4a=${Boolean(sigma && tau)} ogg=${Boolean(omega)} opus=${Boolean(zeta)} eta=${Boolean(eta)}`,
  );

  const lyrics = async (id, headers, lang) =>
    app.inject({
      method: 'GET',
      url:
        `/api/v1/music/lyrics?id=${encodeURIComponent(id)}` +
        (lang ? `&lang=${encodeURIComponent(lang)}` : ''),
      headers: headers || reader,
    });

  // 1. 鉴权
  r = await app.inject({ method: 'GET', url: `/api/v1/music/lyrics?id=${alpha.id}` });
  check('anonymous_401', r.statusCode === 401, 'status=' + r.statusCode);

  r = await lyrics(alpha.id, outsider);
  check('missing_scope_403', r.statusCode === 403, 'status=' + r.statusCode);

  r = await lyrics('missing');
  check('unknown_id_404', r.statusCode === 404, 'status=' + r.statusCode);

  // 2. 内嵌 ID3 USLT（同步歌词 + 元信息）
  r = await lyrics(alpha.id);
  const a = r.json();
  check(
    'embedded_id3_synced',
    r.statusCode === 200 &&
      a.source === 'embedded' &&
      a.synced === true &&
      a.lines.length === 3 &&
      a.lines[0].timeMs === 1000 &&
      a.lines[1].timeMs === 5500 &&
      a.lines[2].timeMs === 9123,
    `source=${a.source} synced=${a.synced} times=${JSON.stringify((a.lines || []).map((l) => l.timeMs))}`,
  );
  check(
    'embedded_meta_tags',
    a.title === '内嵌标题' && a.artist === '内嵌艺术家' && a.lines[0].text === '第一行嵌入歌词',
    `title=${a.title} artist=${a.artist} first=${a.lines && a.lines[0] && a.lines[0].text}`,
  );

  // 2b. 双语：<base>.<lang>.lrc 作为译文；缺省中文优先，可按 lang 切换
  check(
    'bilingual_default_zh',
    ['第一行译文', '第二行译文', '第三行译文'].every((t, i) => a.lines[i].translation === t),
    `translations=${JSON.stringify((a.lines || []).map((l) => l.translation))}`,
  );

  r = await lyrics(alpha.id, null, 'en-US');
  const aEn = r.json();
  check(
    'bilingual_lang_en',
    ['line one', 'line two', 'line three'].every((t, i) => aEn.lines[i].translation === t),
    `translations=${JSON.stringify((aEn.lines || []).map((l) => l.translation))}`,
  );

  // 3. 旁挂 LRC 优先；offset +500 生效；一行多时间戳展开
  r = await lyrics(beta.id);
  const b = r.json();
  check(
    'sidecar_lrc_wins',
    r.statusCode === 200 && b.source === 'lrc' && b.lines.every((l) => l.text === '旁挂 LRC 覆盖内嵌'),
    `source=${b.source} texts=${JSON.stringify((b.lines || []).map((l) => l.text))}`,
  );
  check(
    'lrc_offset_and_multi_time',
    b.synced === true &&
      b.lines.length === 2 &&
      b.lines[0].timeMs === 2500 &&
      b.lines[1].timeMs === 4500,
    `times=${JSON.stringify((b.lines || []).map((l) => l.timeMs))}`,
  );
  check(
    'bilingual_absent_undefined',
    b.lines.every((l) => l.translation === undefined),
    `translations=${JSON.stringify((b.lines || []).map((l) => l.translation))}`,
  );

  // 4. flac Vorbis comment：纯文本歌词（无时间戳）
  r = await lyrics(gamma.id);
  const g = r.json();
  check(
    'flac_vorbis_unsynced',
    r.statusCode === 200 &&
      g.source === 'embedded' &&
      g.synced === false &&
      g.lines.length === 2 &&
      g.lines[0].timeMs === undefined &&
      g.lines[1].text === '纯文本第二句',
    `source=${g.source} synced=${g.synced} lines=${JSON.stringify(g.lines)}`,
  );

  // 5. 无歌词：200 + source=none（不是 404）
  r = await lyrics(delta.id);
  const d = r.json();
  check(
    'no_lyrics_none',
    r.statusCode === 200 && d.source === 'none' && d.synced === false && d.lines.length === 0,
    `status=${r.statusCode} source=${d.source} lines=${d.lines && d.lines.length}`,
  );

  // 6. m4a 的 ©lyr（moov 在头部，faststart）
  r = await lyrics(sigma.id);
  const s = r.json();
  check(
    'm4a_clyr_synced',
    r.statusCode === 200 &&
      s.source === 'embedded' &&
      s.synced === true &&
      s.lines.length === 2 &&
      s.lines[0].timeMs === 2000 &&
      s.lines[1].timeMs === 6250,
    `source=${s.source} synced=${s.synced} times=${JSON.stringify((s.lines || []).map((l) => l.timeMs))}`,
  );

  // 7. m4a 的 moov 落在文件尾部（> 4 MB）→ 只在尾部兜底读取时命中
  r = await lyrics(tau.id);
  const t = r.json();
  check(
    'm4a_moov_at_tail',
    r.statusCode === 200 && t.source === 'embedded' && t.lines.length === 2 && t.lines[0].text === 'm4a 第一行',
    `source=${t.source} first=${t.lines && t.lines[0] && t.lines[0].text}`,
  );

  // 8. ogg（vorbis）注释歌词：纯文本无时间戳
  r = await lyrics(omega.id);
  const om = r.json();
  check(
    'ogg_vorbis_unsynced',
    r.statusCode === 200 &&
      om.source === 'embedded' &&
      om.synced === false &&
      om.lines.length === 2 &&
      om.lines[1].text === 'ogg 纯文本二',
    `source=${om.source} synced=${om.synced} lines=${JSON.stringify(om.lines)}`,
  );

  // 9. opus 的 OpusTags 注释歌词：带时间戳，按 LRC 解析
  r = await lyrics(zeta.id);
  const z = r.json();
  check(
    'opus_tags_synced',
    r.statusCode === 200 &&
      z.source === 'embedded' &&
      z.synced === true &&
      z.lines.length === 1 &&
      z.lines[0].timeMs === 1500,
    `source=${z.source} synced=${z.synced} times=${JSON.stringify((z.lines || []).map((l) => l.timeMs))}`,
  );

  // 10. ogg 有注释但没有歌词键 → none
  r = await lyrics(eta.id);
  const e = r.json();
  check(
    'ogg_without_lyrics_none',
    r.statusCode === 200 && e.source === 'none' && e.lines.length === 0,
    `source=${e.source} lines=${e.lines && e.lines.length}`,
  );

  const failed = results.filter((x) => !x.ok);
  for (const x of results) {
    console.log(`${x.ok ? '[OK]  ' : '[FAIL]'} ${x.name.padEnd(28)} ${x.detail}`);
  }
  console.log(`\n[lyrics] ${results.length - failed.length}/${results.length} passed`);
  await app.close();
  process.exit(failed.length ? 1 : 0);
})();