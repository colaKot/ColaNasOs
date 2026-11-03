import assert from 'node:assert/strict';
import test, { describe } from 'node:test';
import { missingEpisodes } from '../src/modules/video/series';

describe('video · 整季缺集', () => {
  test('列出季内缺的集号，按季升序', () => {
    const gaps = missingEpisodes([
      { season: 2, episode: 1 },
      { season: 2, episode: 4 },
      { season: 1, episode: 1 },
      { season: 1, episode: 3 },
    ]);
    assert.deepEqual(gaps, [
      { season: 1, episodes: [2] },
      { season: 2, episodes: [2, 3] },
    ]);
  });

  test('连续集号不产生缺口', () => {
    assert.deepEqual(
      missingEpisodes([
        { season: 1, episode: 1 },
        { season: 1, episode: 2 },
        { season: 1, episode: 3 },
      ]),
      [],
    );
  });

  test('季号为 null 视为第 1 季；集号缺失或 ≤0 的文件不参与', () => {
    const gaps = missingEpisodes([
      { season: null, episode: 1 },
      { season: null, episode: 3 },
      { season: 1, episode: null },
      { season: 1, episode: 0 },
    ]);
    assert.deepEqual(gaps, [{ season: 1, episodes: [2] }]);
  });

  test('跨度异常（>500）的季跳过，避免 E01/E999 刷出上百条', () => {
    assert.deepEqual(
      missingEpisodes([
        { season: 1, episode: 1 },
        { season: 1, episode: 999 },
      ]),
      [],
    );
  });

  test('每季缺口上限 200 条', () => {
    const gaps = missingEpisodes([
      { season: 1, episode: 1 },
      { season: 1, episode: 500 },
    ]);
    assert.equal(gaps.length, 1);
    assert.equal(gaps[0].episodes.length, 200);
    assert.equal(gaps[0].episodes[0], 2);
  });
});