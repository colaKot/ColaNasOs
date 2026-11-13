import assert from 'node:assert/strict';
import test from 'node:test';
import { mergePlaylists, playlistDurationMs } from '../src/modules/videoPlayer/playlist';

/**
 * 分段续转的播放列表拼接：真 Chrome + hls.js 1.4.10 验证过的格式，
 * 这里把「头只写一次 / init MAP 只声明一次并指向 p0 / 接缝 DISCONTINUITY /
 * 末尾不写 ENDLIST / URI 带 part 参数」钉死。
 */
const part = (n: number, segs = 2) =>
  [
    '#EXTM3U',
    '#EXT-X-VERSION:7',
    '#EXT-X-TARGETDURATION:6',
    '#EXT-X-MEDIA-SEQUENCE:0',
    '#EXT-X-PLAYLIST-TYPE:EVENT',
    '#EXT-X-MAP:URI="init.mp4"',
    ...Array.from({ length: segs }, () => ['#EXTINF:6.000000,', `seg${String(n).padStart(5, '0')}.m4s`]).flat(),
    '#EXT-X-ENDLIST',
    '',
  ].join('\n');

test('playlistDurationMs：按 EXTINF 累加，不按分片数估', () => {
  assert.equal(playlistDurationMs(part(0, 2)), 12000);
  assert.equal(playlistDurationMs('#EXTM3U\n#EXTINF:2.500000,\na.ts\n'), 2500);
  assert.equal(playlistDurationMs('#EXTM3U\n'), 0);
});

test('单段：头只留一份，各段自己的头/ENDLIST 被丢掉', () => {
  const text = mergePlaylists([{ name: 'p0', text: part(0) }]);
  assert.equal((text.match(/#EXTM3U/g) || []).length, 1);
  assert.equal((text.match(/#EXT-X-PLAYLIST-TYPE/g) || []).length, 1);
  assert.equal((text.match(/#EXT-X-MEDIA-SEQUENCE:0/g) || []).length, 1);
  assert.ok(!text.includes('ENDLIST'), '末尾不能写 ENDLIST，否则续段时 hls.js 会当成播完了');
  assert.ok(text.includes('#EXT-X-MAP:URI="init.mp4?part=p0"'));
  assert.ok(text.includes('seg00000.m4s?part=p0'));
});

test('两段：接缝插 DISCONTINUITY，MAP 只声明一次并指向 p0', () => {
  const text = mergePlaylists([
    { name: 'p0', text: part(0) },
    { name: 'p1', text: part(1) },
  ]);
  assert.equal((text.match(/#EXT-X-DISCONTINUITY/g) || []).length, 1);
  // 各段 init.mp4 逐字节相同（同一套编码参数，实测 20+ 段 MD5 一致），
  // 只写一次 MAP。每段重复声明会让 libmpv 跨段重置 demuxer 却不重新拉
  // init，直接 Failed to recognize file format（4K DV + AV1 实测）。
  assert.equal((text.match(/#EXT-X-MAP/g) || []).length, 1);
  assert.ok(text.includes('#EXT-X-MAP:URI="init.mp4?part=p0"'));
  assert.ok(!text.includes('init.mp4?part=p1'));
  assert.equal((text.match(/#EXTINF/g) || []).length, 4);
  assert.equal(playlistDurationMs(text), 24000);
  // 顺序：p0 的两片 → DISCONTINUITY → p1 分片（中间不再有 p1 的 MAP）
  const disc = text.indexOf('#EXT-X-DISCONTINUITY');
  assert.ok(disc > text.indexOf('seg00001.m4s?part=p0'));
  assert.ok(disc < text.indexOf('seg00001.m4s?part=p1'));
  assert.ok(text.indexOf('#EXT-X-MAP') < disc, 'MAP 必须在第一个接缝之前');
});

test('绝对路径的 init / 分片 URI 只留文件名，防止把服务器路径泄漏给播放器', () => {
  const text = mergePlaylists([
    {
      name: 'p0',
      text: '#EXTM3U\n#EXT-X-MAP:URI="G:\\hls\\p0\\init.mp4"\n' +
        '#EXTINF:6.000000,\nG:\\hls\\p0\\seg00000.m4s\n',
    },
  ]);
  assert.ok(text.includes('URI="init.mp4?part=p0"'), text);
  assert.ok(text.includes('seg00000.m4s?part=p0'), text);
  assert.ok(!text.includes('G:'), text);
});

test('空分段：给出合法的空 EVENT 头', () => {
  const text = mergePlaylists([]);
  assert.ok(text.startsWith('#EXTM3U'));
  assert.ok(!text.includes('#EXTINF'));
  assert.ok(!text.includes('ENDLIST'));
});
