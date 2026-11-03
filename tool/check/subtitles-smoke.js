#!/usr/bin/env node
/**
 * 外挂字幕验收（`/api/v1/video/subtitles`、`/api/v1/video/subtitle`）：
 *   同目录同主名发现（含语言后缀）→ SRT 解析与标签 / 实体剥离 → ASS `[Events]` 按 Format 取列、
 *   覆盖标签与 `\N` 处理 → VTT 解析 → GB18030 编码 → 无字幕空列表 → 未知影片 / 未知名字 404 →
 *   超过 5 MB 返回 413 → 匿名 401 / 缺 scope 403 / 只读可读。
 *
 * 素材全部内联构造，**不依赖 ffmpeg**：占位视频照样入库。
 * 用法：node tool/check/subtitles-smoke.js
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

const SRT = [
  '1',
  '00:00:01,000 --> 00:00:03,000',
  'Hello <i>world</i> &amp; more',
  '',
  '2',
  '00:00:04,500 --> 00:00:06,000',
  'Second line',
  '',
].join('\n');

const ASS = [
  '[Script Info]',
  'Title: smoke',
  '',
  '[V4+ Styles]',
  'Format: Name, Fontname',
  'Style: Default,Arial',
  '',
  '[Events]',
  'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text',
  'Dialogue: 0,0:00:01.00,0:00:03.50,Default,,0,0,0,,{\\an8}ASS first\\Nsecond',
  'Dialogue: 0,0:00:04.00,0:00:05.00,Default,,0,0,0,,ASS with, comma',
  'Comment: 0,0:00:07.00,0:00:08.00,Default,,0,0,0,,should be skipped',
  '',
].join('\n');

const VTT = ['WEBVTT', '', '00:00:01.000 --> 00:00:02.000', 'VTT line', ''].join('\n');

/** GB18030 的「你好」= C4 E3 BA C3；用它验证非 UTF-8 字幕的编码探测 */
const GBK_SRT = Buffer.concat([
  Buffer.from('1\n00:00:01,000 --> 00:00:02,000\n', 'latin1'),
  Buffer.from([0xc4, 0xe3, 0xba, 0xc3]),
  Buffer.from('\n', 'latin1'),
]);

(async () => {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-subtitles-'));
  const filesRoot = path.join(dataDir, 'files');
  const movies = path.join(filesRoot, 'movies');
  fs.mkdirSync(movies, { recursive: true });

  const video = Buffer.alloc(2048, 3);
  fs.writeFileSync(path.join(movies, 'Alpha.mp4'), video);
  fs.writeFileSync(path.join(movies, 'Alpha.srt'), SRT);
  fs.writeFileSync(path.join(movies, 'Alpha.zh-Hans.srt'), SRT);
  fs.writeFileSync(path.join(movies, 'Alpha.eng.ass'), ASS);
  fs.writeFileSync(path.join(movies, 'Alpha.vtt'), VTT);
  // 干扰项：不同主名（不该被列出）
  fs.writeFileSync(path.join(movies, 'Alpha2.srt'), SRT);

  fs.writeFileSync(path.join(movies, 'Beta.mkv'), video);

  fs.writeFileSync(path.join(movies, 'Delta.mp4'), video);
  fs.writeFileSync(path.join(movies, 'Delta.srt'), GBK_SRT);

  fs.writeFileSync(path.join(movies, 'Gamma.mkv'), video);
  fs.writeFileSync(path.join(movies, 'Gamma.srt'), Buffer.alloc(6 * 1024 * 1024, 0x41));

  process.env.COLANAS_DEV_TOKEN = '1';
  process.env.COLANAS_FILES_ROOT = filesRoot;
  process.env.COLANAS_JWT_SECRET = 'test-secret-0123456789abcdef';

  const k = await startKernel({ dataDir, port: 0, listen: false });
  const app = k.app;

  const results = [];
  const check = (name, ok, detail) => results.push({ name, ok, detail: detail || '' });

  const mkToken = async (sub, scopes) => {
    const res = await app.inject({
      method: 'POST',
      url: '/api/v1/auth/dev-token',
      payload: { sub, scopes },
    });
    return { authorization: 'Bearer ' + res.json().token };
  };

  const owner = await mkToken('u1', ['video:read', 'video:write', 'files:read']);
  const reader = await mkToken('u2', ['video:read']);
  const outsider = await mkToken('u3', ['book:read']);

  let r = await app.inject({
    method: 'POST',
    url: '/api/v1/video/libraries',
    headers: owner,
    payload: { name: 'Movies', path: 'movies' },
  });
  check('create_library', r.statusCode === 200, 'status=' + r.statusCode);

  r = await app.inject({ method: 'POST', url: '/api/v1/video/scan', headers: owner, payload: {} });
  check('scan', r.statusCode === 200, 'status=' + r.statusCode);

  r = await app.inject({ method: 'GET', url: '/api/v1/video/list?limit=50', headers: owner });
  const items = r.json().items || [];
  const byName = (name) => items.find((x) => x.path.endsWith(name));
  const alpha = byName('Alpha.mp4');
  const beta = byName('Beta.mkv');
  const delta = byName('Delta.mp4');
  const gamma = byName('Gamma.mkv');
  check(
    'indexed_videos',
    Boolean(alpha && beta && delta && gamma),
    'n=' + items.length,
  );

  const list = (id, headers) =>
    app.inject({
      method: 'GET',
      url: `/api/v1/video/subtitles?id=${encodeURIComponent(id)}`,
      headers: headers || owner,
    });
  const read = (id, name, headers) =>
    app.inject({
      method: 'GET',
      url: `/api/v1/video/subtitle?id=${encodeURIComponent(id)}&name=${encodeURIComponent(name)}`,
      headers: headers || owner,
    });

  // 1. 鉴权三态
  r = await app.inject({ method: 'GET', url: `/api/v1/video/subtitles?id=${alpha.id}` });
  check('anonymous_401', r.statusCode === 401, 'status=' + r.statusCode);

  r = await list(alpha.id, outsider);
  check('missing_scope_403', r.statusCode === 403, 'status=' + r.statusCode);

  r = await list(alpha.id, reader);
  check('reader_can_list', r.statusCode === 200, 'status=' + r.statusCode);

  r = await list('missing');
  check('unknown_video_404', r.statusCode === 404, 'status=' + r.statusCode);

  // 2. 发现规则：同主名 + 语言后缀；不同主名（Alpha2）不算
  r = await list(alpha.id);
  const files = r.json().items || [];
  const names = files.map((f) => f.name).sort();
  check(
    'list_same_stem',
    names.length === 4 &&
      names.includes('Alpha.srt') &&
      names.includes('Alpha.zh-Hans.srt') &&
      names.includes('Alpha.eng.ass') &&
      names.includes('Alpha.vtt') &&
      !names.includes('Alpha2.srt'),
    'names=' + JSON.stringify(names),
  );
  const plain = files.find((f) => f.name === 'Alpha.srt');
  const zh = files.find((f) => f.name === 'Alpha.zh-Hans.srt');
  check(
    'language_suffix',
    Boolean(plain && plain.lang === null && zh && zh.lang === 'zh-Hans' && zh.format === 'srt'),
    `plain=${plain && plain.lang} zh=${zh && zh.lang}`,
  );

  r = await list(beta.id);
  check('no_subtitle_empty_list', (r.json().items || []).length === 0, 'status=' + r.statusCode);

  // 3. SRT：时间、多行、剥离 <i> 与实体
  r = await read(alpha.id, 'Alpha.srt');
  const srt = r.json();
  check(
    'srt_cues',
    r.statusCode === 200 &&
      srt.format === 'srt' &&
      srt.cues.length === 2 &&
      srt.cues[0].startMs === 1000 &&
      srt.cues[0].endMs === 3000 &&
      srt.cues[1].startMs === 4500,
    `cues=${JSON.stringify(srt.cues)}`,
  );
  check(
    'srt_strip_tags_and_entities',
    srt.cues[0].text === 'Hello world & more',
    'text=' + (srt.cues[0] && srt.cues[0].text),
  );
  check(
    'srt_vtt_output',
    typeof srt.vtt === 'string' &&
      srt.vtt.startsWith('WEBVTT') &&
      srt.vtt.includes('00:00:01.000 --> 00:00:03.000'),
    'head=' + String(srt.vtt).slice(0, 60),
  );

  // 4. ASS：按 Format 取列、Text 内含逗号、剥离 {\an8}、\N 转换行、Skip Comment
  r = await read(alpha.id, 'Alpha.eng.ass');
  const ass = r.json();
  check(
    'ass_events',
    r.statusCode === 200 && ass.format === 'ass' && ass.cues.length === 2,
    `n=${(ass.cues || []).length}`,
  );
  check(
    'ass_clean_text',
    ass.cues[0].text === 'ASS first\nsecond' && ass.cues[1].text === 'ASS with, comma',
    `first=${JSON.stringify(ass.cues[0] && ass.cues[0].text)} second=${JSON.stringify(ass.cues[1] && ass.cues[1].text)}`,
  );
  check(
    'ass_times',
    ass.cues[0].startMs === 1000 && ass.cues[0].endMs === 3500,
    `start=${ass.cues[0] && ass.cues[0].startMs} end=${ass.cues[0] && ass.cues[0].endMs}`,
  );

  // 5. VTT 直接解析
  r = await read(alpha.id, 'Alpha.vtt');
  const vtt = r.json();
  check(
    'vtt_parsed',
    r.statusCode === 200 && vtt.format === 'vtt' && vtt.cues.length === 1 && vtt.cues[0].text === 'VTT line',
    `format=${vtt.format} n=${(vtt.cues || []).length}`,
  );

  // 6. GB18030 编码
  r = await read(delta.id, 'Delta.srt');
  const gbk = r.json();
  check(
    'gb18030_decoded',
    r.statusCode === 200 && gbk.cues.length === 1 && gbk.cues[0].text === '你好',
    'text=' + (gbk.cues[0] && gbk.cues[0].text),
  );

  // 7. 未知字幕名 / 路径穿越 → 404
  r = await read(alpha.id, 'Nope.srt');
  check('unknown_subtitle_404', r.statusCode === 404, 'status=' + r.statusCode);

  r = await read(alpha.id, '../Alpha.srt');
  check('path_traversal_404', r.statusCode === 404, 'status=' + r.statusCode);

  // 8. 超过 5 MB → 413
  r = await read(gamma.id, 'Gamma.srt');
  check('too_large_413', r.statusCode === 413, 'status=' + r.statusCode);

  const failed = results.filter((x) => !x.ok);
  for (const x of results) {
    console.log(`${x.ok ? '[OK]  ' : '[FAIL]'} ${x.name.padEnd(28)} ${x.detail}`);
  }
  console.log(`\n[subtitles] ${results.length - failed.length}/${results.length} passed`);
  await app.close();
  process.exit(failed.length ? 1 : 0);
})();