import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test, { describe } from 'node:test';
import { fileURLToPath } from 'node:url';

/**
 * `bindLibraryWatch` 只建空壳（定时器 + 空 Map），**订阅关系要 refresh() 才建立**。
 *
 * 漏调的后果不是「慢一点」，而是两条路同时断：
 *   1. `k.watch.subscribe` 从没被调用 → fs.watch 根本没盯库根目录，丢文件不刷新；
 *   2. `libs` 一直是空的 → 6 小时周期校验遍历 0 个库，永远不补。
 * 用户看到的就是「前几天拷进去的照片/影片一直不出现，只有手动点扫描才出来」。
 *
 * 2026-11-26 真实事故：photo 和 video 都漏了这一步（music 早就补过），
 * 相册最后入库时间停在 11 月 14 日，而磁盘上 11 月 19 日之后还有 225 个新文件。
 *
 * 这个测试守住「每个调用方都要 refresh」这条约定 —— 新模块接监听时别再踩。
 */
const here = path.dirname(fileURLToPath(import.meta.url));
const modulesDir = path.resolve(here, '..', 'src', 'modules');

/** 所有调用 bindLibraryWatch 的模块入口（不含 library-watch 自己） */
function callers(): string[] {
  const out: string[] = [];
  for (const dir of fs.readdirSync(modulesDir)) {
    const file = path.join(modulesDir, dir, 'index.ts');
    if (!fs.existsSync(file)) continue;
    const src = fs.readFileSync(file, 'utf8');
    if (src.includes('bindLibraryWatch')) out.push(file);
  }
  return out;
}

describe('library-watch：调用方必须 refresh', () => {
  test('每个 bindLibraryWatch 调用方都在注册模块前调用了 libWatch.refresh()', () => {
    const files = callers();
    assert.ok(files.length >= 3, `应当至少有 photo / video / music 三个调用方，实际 ${files.length}`);

    for (const file of files) {
      const src = fs.readFileSync(file, 'utf8');
      const name = path.relative(path.resolve(here, '..'), file);
      assert.match(
        src,
        /(await\s+)?libWatch\.refresh\(\)/,
        `${name} 调用了 bindLibraryWatch 但没有 libWatch.refresh()：` +
          '订阅不会建立，文件监控与周期校验都是死的',
      );
    }
  });
});
