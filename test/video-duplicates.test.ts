import assert from 'node:assert/strict';
import test, { describe } from 'node:test';
import { duplicateKey, extractDupCode, hasWord } from '../src/modules/video/routes/duplicates';

describe('video · 重复片名归一化', () => {
  test('画质 / 编码 / 发布组 / 日系标记都归一到同一个 key', () => {
    const key = 'alpha';
    for (const title of [
      'Alpha',
      'Alpha 1080p x264-GROUP',
      'Alpha 2160p HDR10+HDR',
      'Alpha 4K HEVC 10bit',
      'Alpha-UC',
      'Alpha [2020]',
      'Alpha WEB-DL',
    ]) {
      assert.equal(duplicateKey(title), key, title);
    }
  });

  test('不同片子不被合并', () => {
    assert.notEqual(duplicateKey('Alpha'), duplicateKey('Beta'));
  });

  test('只有噪声的文件名归一化为空（不参与分组）', () => {
    assert.equal(duplicateKey('1080p x264'), '');
  });
});

describe('video · 排重四钥匙辅助', () => {
  test('番号必须带分隔符，且数字不能是年份', () => {
    assert.equal(extractDupCode('IPZ-947.mkv'), 'IPZ-947');
    assert.equal(extractDupCode('abc_123.mp4'), 'ABC-123');
    // 年份不当番号
    assert.equal(extractDupCode('Movie 2020 1080p.mkv'), '');
    assert.equal(extractDupCode('Interstellar.2014.mkv'), '');
    // 技术标记不当番号
    assert.equal(extractDupCode('Show.S01E02.1080p.mkv'), '');
  });

  test('纯数字 / 纯符号标题不参与判重', () => {
    assert.equal(hasWord('-02-24 17 51'), false);
    assert.equal(hasWord('2024-02-24 17.51.25'), false);
    assert.equal(hasWord('银翼杀手'), true);
    assert.equal(hasWord('Blade Runner'), true);
  });
});
