import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test, { describe } from 'node:test';
import {
  coalesceEvents,
  isIgnoredPath,
  mergeBatches,
  mergeKind,
  WatchService,
  type FsBatch,
  type FsEvent,
} from '../kernel/fs-watch';

const ev = (kind: FsEvent['kind'], p: string, isDir = false): FsEvent => ({ kind, path: p, isDir });

function tmpDir(tag: string): string {
  return fs.mkdtempSync(path.join(os.tmpdir(), `colanas-watch-${tag}-`));
}

async function waitUntil(fn: () => boolean, timeoutMs = 4000): Promise<void> {
  const start = Date.now();
  while (!fn()) {
    if (Date.now() - start > timeoutMs) throw new Error('timeout waiting for condition');
    await new Promise((r) => setTimeout(r, 20));
  }
}

describe('fs-watch · 事件合并（纯逻辑）', () => {
  test('同路径多次事件收敛到最终态', () => {
    assert.equal(mergeKind('deleted', 'created'), 'modified'); // 覆盖写入
    assert.equal(mergeKind('created', 'deleted'), 'deleted'); // 临时文件消失
    assert.equal(mergeKind('created', 'modified'), 'created'); // 新建后写入仍是新建
    assert.equal(mergeKind('modified', 'deleted'), 'deleted');
    assert.equal(mergeKind('modified', 'rescan'), 'rescan');
  });

  test('合批按路径排序，不改变事件条数', () => {
    const pending = new Map<string, FsEvent>([
      ['/b', ev('created', '/b')],
      ['/a', ev('modified', '/a')],
      ['/c', ev('deleted', '/c')],
    ]);
    const batch = coalesceEvents(pending, { root: '/r', debounceMs: 500 });
    assert.equal(batch.storm, false);
    assert.deepEqual(
      batch.events.map((e) => e.path),
      ['/a', '/b', '/c'],
    );
  });

  test('超阈值降级为一条目录级重扫', () => {
    const pending = new Map<string, FsEvent>();
    for (let i = 0; i < 60; i += 1) pending.set(`/r/${i}`, ev('created', `/r/${i}`));
    const batch = coalesceEvents(pending, { root: '/r', debounceMs: 100, stormPerSecond: 200 });
    assert.equal(batch.storm, true);
    assert.equal(batch.events.length, 1);
    assert.equal(batch.events[0].kind, 'rescan');
    assert.equal(batch.events[0].path, '/r');
  });

  test('小窗口有 40 条下限，正常批量写入不误判为风暴', () => {
    const pending = new Map<string, FsEvent>();
    for (let i = 0; i < 30; i += 1) pending.set(`/r/${i}`, ev('created', `/r/${i}`));
    // 理论阈值 = 200 * 0.05 = 10，但下限 40，所以 30 条不算风暴
    const batch = coalesceEvents(pending, { root: '/r', debounceMs: 50, stormPerSecond: 200 });
    assert.equal(batch.storm, false);
    assert.equal(batch.events.length, 30);
  });

  test('排队批合并：任一批风暴即整批重扫', () => {
    const a: FsBatch = { root: '/r', at: 1, storm: false, events: [ev('created', '/r/a')] };
    const b: FsBatch = { root: '/r', at: 2, storm: true, events: [ev('rescan', '/r', true)] };
    const merged = mergeBatches(a, b);
    assert.equal(merged.storm, true);
    assert.equal(merged.events.length, 1);
    assert.equal(merged.events[0].kind, 'rescan');
  });

  test('排队批合并：同路径收敛', () => {
    const a: FsBatch = { root: '/r', at: 1, storm: false, events: [ev('deleted', '/r/x')] };
    const b: FsBatch = { root: '/r', at: 2, storm: false, events: [ev('created', '/r/x')] };
    const merged = mergeBatches(a, b);
    assert.equal(merged.events.length, 1);
    assert.equal(merged.events[0].kind, 'modified');
  });
});

describe('fs-watch · 忽略规则', () => {
  test('系统垃圾文件与回收站目录被忽略', () => {
    assert.equal(isIgnoredPath('/data/.DS_Store'), true);
    assert.equal(isIgnoredPath('/data/Thumbs.db'), true);
    assert.equal(isIgnoredPath('/data/@eaDir/thumb.jpg'), true);
    assert.equal(isIgnoredPath('/data/#recycle/x.jpg'), true);
    assert.equal(isIgnoredPath('/data/upload/a.jpg.part'), true);
    assert.equal(isIgnoredPath('/data/~$draft.docx'), true);
    assert.equal(isIgnoredPath('/data/photo/a.jpg'), false);
  });
});

describe('fs-watch · 真实文件系统', () => {
  test('新建文件触发 created；相同 root 共享一个 watcher（引用计数）', async () => {
    const root = tmpDir('create');
    const service = new WatchService();
    const got: FsBatch[] = [];
    const off1 = service.subscribe(root, (b) => void got.push(b), { debounceMs: 60 });
    const off2 = service.subscribe(root, (b) => void got.push(b), { debounceMs: 60 });
    assert.equal(service.stats().roots, 1);
    assert.equal(service.stats().subscribers, 2);

    fs.writeFileSync(path.join(root, 'hello.jpg'), 'x');
    await waitUntil(() => got.length >= 2, 5000);

    const paths = got.flatMap((b) => b.events.map((e) => path.basename(e.path)));
    assert.ok(paths.includes('hello.jpg'));

    off1();
    off2();
    assert.equal(service.stats().roots, 0);
    service.stopAll();
    fs.rmSync(root, { recursive: true, force: true });
  });

  test('删除文件记为 deleted', async () => {
    const root = tmpDir('delete');
    const target = path.join(root, 'gone.jpg');
    fs.writeFileSync(target, 'x');

    const service = new WatchService();
    const got: FsEvent[] = [];
    service.subscribe(root, (b) => void got.push(...b.events), { debounceMs: 60 });

    // 等第一次写入事件落定，避免与删除事件混批
    await new Promise((r) => setTimeout(r, 250));
    got.length = 0;
    fs.unlinkSync(target);

    await waitUntil(() => got.some((e) => path.basename(e.path) === 'gone.jpg'), 5000);
    const hit = got.filter((e) => path.basename(e.path) === 'gone.jpg').pop()!;
    assert.equal(hit.kind, 'deleted');
    service.stopAll();
    fs.rmSync(root, { recursive: true, force: true });
  });

  test('handler 抛错不影响后续批次，也不阻塞其它订阅者', async () => {
    const root = tmpDir('error');
    const service = new WatchService();
    let ok = 0;
    service.subscribe(
      root,
      () => {
        throw new Error('boom');
      },
      { debounceMs: 50 },
    );
    service.subscribe(root, () => void (ok += 1), { debounceMs: 50 });

    fs.writeFileSync(path.join(root, 'a.jpg'), 'x');
    await waitUntil(() => ok > 0, 5000);
    service.stopAll();
    fs.rmSync(root, { recursive: true, force: true });
  });

  test('风暴保护：大量文件同时写入（同目录）只跑很少几次目录扫描', async () => {
    const root = tmpDir('storm');
    const service = new WatchService();
    const got: FsBatch[] = [];
    service.subscribe(root, (b) => void got.push(b), {
      debounceMs: 300,
      stormPerSecond: 5,
      stormMinEvents: 5,
      stormMinDirs: 5,
    });

    for (let i = 0; i < 120; i += 1) fs.writeFileSync(path.join(root, `f${i}.jpg`), 'x');
    await waitUntil(() => got.length > 0, 5000);
    // 再等一个窗口，确认不会持续不断地触发
    await new Promise((r) => setTimeout(r, 700));

    // Windows 的 recursive watcher 会合并同目录变更：无论系统上报几条，
    // 下游只应拿到极少数批次（每批再被合成一次目录扫描），而不是一次文件一条
    assert.ok(got.length <= 3, `batches=${got.length}`);
    assert.ok(got.every((b) => b.events.length <= 40), 'single batch too large');
    service.stopAll();
    fs.rmSync(root, { recursive: true, force: true });
  });
});