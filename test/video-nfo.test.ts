import assert from 'node:assert/strict';
import test, { describe } from 'node:test';
import path from 'node:path';
import fsp from 'node:fs/promises';
import os from 'node:os';
import {
  buildNfo,
  decodeEntities,
  findLocalPoster,
  findNfoFile,
  parseActorNames,
  parseNfo,
  tagAll,
  tagText,
  tagTextWithAttr,
  uniqueId,
} from '../src/modules/video/nfo';
import { ingestNfo } from '../src/modules/video/nfo-ingest';

const MOVIE_NFO = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<movie>
  <title>银翼杀手 2049</title>
  <originaltitle>Blade Runner 2049</originaltitle>
  <sorttitle>Blade Runner 2049</sorttitle>
  <year>2017</year>
  <ratings>
    <rating name="imdb" max="10"><value>8.0</value><votes>600000</votes></rating>
    <rating name="themoviedb" max="10"><value>7.6</value></rating>
  </ratings>
  <plot>一名新的银翼杀手揭开了尘封三十年的秘密。</plot>
  <runtime>164</runtime>
  <premiered>2017-10-06</premiered>
  <studio>Warner Bros.</studio>
  <genre>科幻</genre>
  <genre>剧情</genre>
  <country>美国</country>
  <country>英国</country>
  <director>丹尼斯·维伦纽瓦</director>
  <uniqueid type="imdb">tt1856101</uniqueid>
  <uniqueid type="tmdb">335984</uniqueid>
  <uniqueid type="douban">10577880</uniqueid>
  <thumb aspect="poster">poster.jpg</thumb>
  <fanart><thumb>fanart.jpg</thumb></fanart>
  <actor><name>瑞恩·高斯林</name><role>K</role><order>0</order></actor>
  <actor><name>哈里森·福特</name><role>Deckard</role></actor>
</movie>`;

describe('video · NFO 解析', () => {
  test('标准 Kodi movie nfo：片名 / 年份 / 评分 / 类型 / 地区 / 人物 / 外部 id 全部解析', () => {
    const meta = parseNfo(MOVIE_NFO);
    assert.ok(meta);
    assert.equal(meta!.title, '银翼杀手 2049');
    assert.equal(meta!.originalTitle, 'Blade Runner 2049');
    assert.equal(meta!.year, 2017);
    // 优先 imdb 评分
    assert.equal(meta!.score, 8);
    assert.equal(meta!.runtimeMin, 164);
    assert.equal(meta!.releaseDate, '2017-10-06');
    assert.equal(meta!.studio, 'Warner Bros.');
    assert.deepEqual(meta!.genres, ['科幻', '剧情']);
    assert.deepEqual(meta!.regions, ['美国', '英国']);
    assert.deepEqual(meta!.directors, ['丹尼斯·维伦纽瓦']);
    assert.deepEqual(meta!.actors, ['瑞恩·高斯林', '哈里森·福特']);
    assert.equal(meta!.imdbId, 'tt1856101');
    assert.equal(meta!.tmdbId, 335984);
    assert.equal(meta!.doubanId, '10577880');
    assert.equal(meta!.poster, 'poster.jpg');
    assert.equal(meta!.fanart, 'fanart.jpg');
    assert.equal(meta!.source, 'nfo');
  });

  test('老式平铺 <rating> 与 <imdbid> 也能读', () => {
    const meta = parseNfo(
      '<movie><title>Old</title><year>1999</year><rating>6.5</rating><imdbid>tt0123456</imdbid></movie>',
    );
    assert.ok(meta);
    assert.equal(meta!.score, 6.5);
    assert.equal(meta!.imdbId, 'tt0123456');
  });

  test('空 nfo 返回 null（不能把空结果当成「已刮削」）', () => {
    assert.equal(parseNfo('<movie></movie>'), null);
    assert.equal(parseNfo(''), null);
    assert.equal(parseNfo('   '), null);
  });

  test('实体与 CDATA 还原', () => {
    assert.equal(decodeEntities('A &amp; B &lt;x&gt; &#65; &#x42;'), 'A & B <x> A B');
    assert.equal(tagText('<a><plot><![CDATA[1 & 2 <b>]]></plot></a>', 'plot'), '1 & 2 <b>');
  });

  test('同名标签重复 + 带属性标签', () => {
    const xml = '<r><genre>A</genre><genre>B</genre><genre>A</genre></r>';
    assert.deepEqual(tagAll(xml, 'genre'), ['A', 'B']);
    assert.equal(tagTextWithAttr('<x><thumb aspect="poster">p.jpg</thumb></x>', 'thumb', 'aspect', 'poster'), 'p.jpg');
    assert.equal(uniqueId('<x><uniqueid type="tmdb">42</uniqueid></x>', 'tmdb'), '42');
  });

  test('演员块里只有 <name> 被抽出来，role 不污染', () => {
    assert.deepEqual(
      parseActorNames('<a><actor><name>甲</name><role>乙</role></actor></a>'),
      ['甲'],
    );
  });

  test('写出后再读回，字段不丢', () => {
    const meta = parseNfo(MOVIE_NFO)!;
    const back = parseNfo(buildNfo(meta));
    assert.ok(back);
    assert.equal(back!.title, meta.title);
    assert.equal(back!.year, meta.year);
    assert.equal(back!.score, meta.score);
    assert.deepEqual(back!.genres, meta.genres);
    assert.deepEqual(back!.regions, meta.regions);
    assert.deepEqual(back!.actors, meta.actors);
    assert.equal(back!.imdbId, meta.imdbId);
    assert.equal(back!.tmdbId, meta.tmdbId);
    assert.equal(back!.doubanId, meta.doubanId);
  });
});

describe('video · NFO 落盘与本地图片发现', () => {
  async function tmpDir(): Promise<string> {
    const dir = await fsp.mkdtemp(path.join(os.tmpdir(), 'colanas-nfo-'));
    return dir;
  }

  test('findNfoFile 优先同名，其次 movie.nfo', async () => {
    const dir = await tmpDir();
    try {
      const video = path.join(dir, 'Alpha.2020.mkv');
      await fsp.writeFile(video, '');
      assert.equal(await findNfoFile(video), null);

      await fsp.writeFile(path.join(dir, 'movie.nfo'), '<movie><title>Dir</title></movie>');
      const dirNfo = await findNfoFile(video);
      assert.equal(dirNfo?.scope, 'dir');

      await fsp.writeFile(path.join(dir, 'Alpha.2020.nfo'), '<movie><title>Item</title></movie>');
      const itemNfo = await findNfoFile(video);
      assert.equal(itemNfo?.scope, 'item');
      assert.ok(itemNfo!.file.endsWith('Alpha.2020.nfo'));
    } finally {
      await fsp.rm(dir, { recursive: true, force: true });
    }
  });

  test('findLocalPoster 认 poster.jpg / <同名>.jpg', async () => {
    const dir = await tmpDir();
    try {
      const video = path.join(dir, 'Beta.mkv');
      await fsp.writeFile(video, '');
      assert.equal(await findLocalPoster(video), null);
      await fsp.writeFile(path.join(dir, 'poster.jpg'), 'x');
      assert.equal(await findLocalPoster(video), path.join(dir, 'poster.jpg'));
    } finally {
      await fsp.rm(dir, { recursive: true, force: true });
    }
  });

  test('ingestNfo：nfo 的相对图片解析到 nfo 同目录；无 nfo 时 source=none', async () => {
    const dir = await tmpDir();
    try {
      const withNfo = path.join(dir, 'Gamma.2021.mkv');
      await fsp.writeFile(withNfo, '');
      await fsp.writeFile(
        path.join(dir, 'Gamma.2021.nfo'),
        '<movie><title>Gamma</title><year>2021</year><thumb aspect="poster">p.jpg</thumb></movie>',
      );
      const ing = await ingestNfo(withNfo);
      assert.equal(ing.name, 'Gamma');
      assert.equal(ing.year, 2021);
      assert.equal(ing.source, 'nfo');
      // 本地不存在 p.jpg → 回退约定文件名（也没有）→ null
      assert.equal(ing.poster, null);

      await fsp.writeFile(path.join(dir, 'Gamma.2021-poster.jpg'), 'x');
      const ing2 = await ingestNfo(withNfo);
      assert.equal(ing2.poster, path.join(dir, 'Gamma.2021-poster.jpg'));

      const noNfo = path.join(dir, 'Delta.mkv');
      await fsp.writeFile(noNfo, '');
      const ing3 = await ingestNfo(noNfo);
      assert.equal(ing3.source, 'none');
      assert.equal(ing3.name, null);
    } finally {
      await fsp.rm(dir, { recursive: true, force: true });
    }
  });
});
