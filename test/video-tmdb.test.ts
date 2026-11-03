import assert from 'node:assert/strict';
import test, { describe } from 'node:test';
import { guessTitle, pickBestCandidate, toCandidates } from '../src/modules/video/tmdb';

describe('video · 刮削标题猜测', () => {
  test('年份与发布组 / 画质标记都剥掉', () => {
    assert.deepEqual(guessTitle('Blade.Runner.2049.2017.2160p.UHD.BluRay.x265-GROUP'), {
      title: 'Blade Runner 2049',
      year: 2017,
    });
    assert.deepEqual(guessTitle('银翼杀手2049.2017.1080p.WEB-DL'), {
      title: '银翼杀手2049',
      year: 2017,
    });
  });

  test('季集标记不进片名（剧集按 show 名去搜）', () => {
    assert.deepEqual(guessTitle('The.Bear.S02E03.1080p.WEB-DL'), {
      title: 'The Bear',
      year: null,
    });
  });

  test('没有年份时不给年份，不瞎猜', () => {
    assert.deepEqual(guessTitle('Some.Movie.1080p'), { title: 'Some Movie', year: null });
  });
});

describe('video · 候选打分', () => {
  const mk = (over: Partial<Parameters<typeof pickBestCandidate>[0][number]>) => {
    const base = {
      tmdbId: 1,
      mediaType: 'movie' as const,
      title: 'Alpha',
      originalTitle: 'Alpha',
      year: 2020,
      score: 7,
      overview: '',
      posterPath: '/a.jpg',
    };
    // 覆盖标题时原名片名同步改，否则 originalTitle 会把「匹配」这一项白送分
    const merged = { ...base, ...over };
    if (over.title && !over.originalTitle) merged.originalTitle = over.title;
    return merged;
  };

  test('年份与标题都匹配的胜出', () => {
    const { best } = pickBestCandidate(
      [mk({ tmdbId: 1, year: 1999 }), mk({ tmdbId: 2, year: 2020, title: 'Beta' }), mk({ tmdbId: 3, year: 2020 })],
      { title: 'Alpha', year: 2020 },
    );
    assert.equal(best?.tmdbId, 3);
  });

  test('空候选返回 null（调用方据此走 notfound，而不是瞎写一条）', () => {
    assert.equal(pickBestCandidate([], { title: 'x', year: null }).best, null);
  });

  test('完全没有匹配时仍然给一条（有结果比没有强），分数用于门槛判断', () => {
    const { best, score } = pickBestCandidate([mk({ title: 'Zeta', originalTitle: 'Zeta', year: 1970 })], {
      title: 'Alpha',
      year: 2020,
    });
    assert.ok(best);
    assert.ok(score < 2, 'score=' + score);
  });
});

describe('video · 搜索结果归一', () => {
  test('movie 与 tv 的字段名差异都能吃下', () => {
    const movie = toCandidates(
      { results: [{ id: 603, title: '致命魔术', original_title: 'The Prestige', release_date: '2006-10-19', vote_average: 8.2, overview: 'x', poster_path: '/p.jpg' }] },
      'movie',
    );
    assert.equal(movie[0].year, 2006);
    assert.equal(movie[0].title, '致命魔术');
    assert.equal(movie[0].originalTitle, 'The Prestige');

    const tv = toCandidates(
      { results: [{ id: 1396, name: '绝命毒师', original_name: 'Breaking Bad', first_air_date: '2008-01-20', vote_average: 8.9 }] },
      'tv',
    );
    assert.equal(tv[0].year, 2008);
    assert.equal(tv[0].title, '绝命毒师');
    assert.equal(tv[0].mediaType, 'tv');
  });

  test('坏 payload 不抛错', () => {
    assert.deepEqual(toCandidates(null, 'movie'), []);
    assert.deepEqual(toCandidates({ results: 'nope' }, 'movie'), []);
  });
});
