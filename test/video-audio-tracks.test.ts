import assert from 'node:assert/strict';
import test from 'node:test';
import { parseAudioTracks } from '../src/modules/video/ffmpeg';

/**
 * 音轨清单解析。《匹诺曹》的真实 ffprobe 输出（3 条音轨，两条同为国语靠 title 区分）。
 * 这条链是「播放器音轨菜单显示中文/英文」的唯一数据来源，解析错了菜单就是
 * 一堆「音轨 1 / 2 / 3」。
 */
const PINOCCHIO = JSON.stringify({
  programs: [],
  streams: [
    {
      codec_name: 'truehd',
      channels: 8,
      channel_layout: '7.1',
      disposition: { default: 1 },
      tags: { language: 'eng', title: '英语' },
    },
    {
      codec_name: 'ac3',
      channels: 6,
      channel_layout: '5.1(side)',
      disposition: { default: 0 },
      tags: { language: 'chi', title: '上海领声国语' },
    },
    {
      codec_name: 'ac3',
      channels: 6,
      channel_layout: '5.1(side)',
      disposition: { default: 0 },
      tags: { language: 'chi', title: '台配国语' },
    },
  ],
});

test('parseAudioTracks：读出语言 / 音轨名 / 声道', () => {
  const tracks = parseAudioTracks(PINOCCHIO);
  assert.equal(tracks.length, 3);
  assert.deepEqual(tracks[0], {
    index: 0,
    codec: 'truehd',
    language: 'eng',
    title: '英语',
    channels: 8,
    channelLayout: '7.1',
    isDefault: true,
  });
  assert.equal(tracks[1].title, '上海领声国语');
  assert.equal(tracks[2].title, '台配国语');
  assert.equal(tracks[2].isDefault, false);
});

test('parseAudioTracks：index 是音频轨序号，不是全局流序号', () => {
  // 转码用的是 -map 0:a:N，N 必须是「第几条音频」，不能拿 ffprobe 的全局 index
  const json = JSON.stringify({
    streams: [
      { index: 3, codec_name: 'aac', channels: 2 },
      { index: 7, codec_name: 'aac', channels: 2 },
    ],
  });
  const tracks = parseAudioTracks(json);
  assert.deepEqual(
    tracks.map((t) => t.index),
    [0, 1],
  );
});

test('parseAudioTracks：缺字段 / 空 tags 不抛错', () => {
  const tracks = parseAudioTracks(JSON.stringify({ streams: [{}, { tags: {} }] }));
  assert.equal(tracks.length, 2);
  assert.equal(tracks[0].language, null);
  assert.equal(tracks[0].title, null);
  assert.equal(tracks[0].channels, null);
  assert.equal(tracks[0].isDefault, false);
});

test('parseAudioTracks：非法 JSON 返回空数组（菜单退回旧样式，不炸播放）', () => {
  assert.deepEqual(parseAudioTracks('not json'), []);
  assert.deepEqual(parseAudioTracks('{"streams": 5}'), []);
});
