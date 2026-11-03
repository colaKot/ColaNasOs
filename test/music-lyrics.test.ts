import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test, { after, describe } from 'node:test';
import {
  attachTranslation,
  readLyrics,
  translationLrcCandidates,
  type LyricsLine,
} from '../src/modules/music/lyrics';

const line = (timeMs: number, text: string): LyricsLine => ({ timeMs, text });

describe('music · 歌词双语对照', () => {
  test('同步歌词按时间轴最近配对（1.2s 内）', () => {
    const lines = [line(1000, 'first'), line(5000, 'second'), line(9000, 'third')];
    const trans = [line(1200, '第一句'), line(4800, '第二句'), line(9500, '第三句')];
    const out = attachTranslation(lines, trans, true);
    assert.deepEqual(
      out.map((l) => l.translation),
      ['第一句', '第二句', '第三句'],
    );
    assert.equal(out[0].text, 'first');
  });

  test('时间轴误差超出范围的行不贴译文', () => {
    const lines = [line(1000, 'first'), line(9000, 'second')];
    const trans = [line(1200, '第一句'), line(20000, '无关行')];
    const out = attachTranslation(lines, trans, true);
    assert.equal(out[0].translation, '第一句');
    assert.equal(out[1].translation, undefined);
  });

  test('纯文本歌词按行号配对', () => {
    const lines: LyricsLine[] = [{ text: 'one' }, { text: 'two' }];
    const trans: LyricsLine[] = [{ text: '一' }, { text: '二' }];
    const out = attachTranslation(lines, trans, false);
    assert.deepEqual(
      out.map((l) => l.translation),
      ['一', '二'],
    );
  });

  test('一行都没对上时保持原样', () => {
    const lines = [line(1000, 'first')];
    const trans = [line(30000, 'far away')];
    const out = attachTranslation(lines, trans, true);
    assert.equal(out, lines);
    assert.equal(out[0].translation, undefined);
  });
});

describe('music · 译文旁挂文件', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-lyrics-test-'));
  const audio = path.join(dir, 'Alpha.mp3');
  const primary = ['[00:01.00]第一行原文', '[00:05.00]第二行原文'].join('\n');
  fs.writeFileSync(audio, '');
  fs.writeFileSync(path.join(dir, 'Alpha.lrc'), primary);
  fs.writeFileSync(path.join(dir, 'Alpha.en.lrc'), '[00:01.00]line one\n[00:05.00]line two');
  fs.writeFileSync(path.join(dir, 'Alpha.zh-CN.lrc'), '[00:01.00]第一行译文\n[00:05.00]第二行译文');
  // 语言标签不合法 / 前缀不匹配的文件不该被当成译文
  fs.writeFileSync(path.join(dir, 'Alpha.remaster.lrc'), '[00:01.00]junk');
  fs.writeFileSync(path.join(dir, 'Other.zh.lrc'), '[00:01.00]junk');

  after(() => fs.rmSync(dir, { recursive: true, force: true }));

  test('候选文件只认 <base>.<lang>.lrc，并按语言偏好排序', () => {
    const picked = translationLrcCandidates(audio).map((p) => path.basename(p));
    assert.deepEqual(picked, ['Alpha.zh-CN.lrc', 'Alpha.en.lrc']);

    const byEnglish = translationLrcCandidates(audio, 'en-US').map((p) => path.basename(p));
    assert.deepEqual(byEnglish, ['Alpha.en.lrc', 'Alpha.zh-CN.lrc']);
  });

  test('readLyrics 按 lang 选中对应译文并逐行贴上', async () => {
    const zh = await readLyrics(audio, { lang: 'zh-CN' });
    assert.equal(zh.source, 'lrc');
    assert.deepEqual(
      zh.lines.map((l) => l.translation),
      ['第一行译文', '第二行译文'],
    );

    const en = await readLyrics(audio, { lang: 'en-US' });
    assert.deepEqual(
      en.lines.map((l) => l.translation),
      ['line one', 'line two'],
    );

    const dflt = await readLyrics(audio);
    assert.equal(dflt.lines[0].translation, '第一行译文');
  });
});
