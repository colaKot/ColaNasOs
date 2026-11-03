import assert from 'node:assert/strict';
import test, { describe } from 'node:test';
import {
  needsAudioTranscode,
  transcodeCacheKey,
} from '../src/modules/music/transcode';

describe('music · 音频按需转码', () => {
  test('Web 不支持的容器按扩展名判定', () => {
    assert.equal(needsAudioTranscode({ rel_path: 'a.ape', codec: null }), true);
    assert.equal(needsAudioTranscode({ rel_path: 'a.wma', codec: null }), true);
    assert.equal(needsAudioTranscode({ rel_path: 'a.aiff', codec: null }), true);
    assert.equal(needsAudioTranscode({ rel_path: 'a.mp3', codec: null }), false);
    assert.equal(needsAudioTranscode({ rel_path: 'a.flac', codec: null }), false);
  });

  test('同容器里的非 Web 编码按 codec 判定', () => {
    assert.equal(needsAudioTranscode({ rel_path: 'a.m4a', codec: 'alac' }), true);
    assert.equal(needsAudioTranscode({ rel_path: 'a.m4a', codec: 'aac' }), false);
    assert.equal(needsAudioTranscode({ rel_path: 'a.mkv', codec: 'wmav2' }), true);
    assert.equal(needsAudioTranscode({ rel_path: 'a.m4a', codec: null }), false);
  });

  test('缓存键随文件内容变化（mtime）', () => {
    const a = transcodeCacheKey({ rel_path: 'x/a.mp3', mtime: 100 });
    const b = transcodeCacheKey({ rel_path: 'x/a.mp3', mtime: 101 });
    assert.notEqual(a, b);
    assert.equal(a.length, 32);
  });
});
