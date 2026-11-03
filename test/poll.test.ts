import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test, { describe } from 'node:test';
import { EventBus } from '../kernel/bus';
import { diffSnapshot, PollService, type SnapshotEntry } from '../kernel/poll';

const snap = (entries: Record<string, SnapshotEntry>): Map<string, SnapshotEntry> => new Map(Object.entries(entries));
const e = (size: number, mtime: number): SnapshotEntry => ({ size, mtime });

async function waitUntil(fn: () => boolean, timeoutMs = 4000): Promise<void> {
  const started = Date.now();
  while (!fn()) {
    if (Date.now() - started > timeoutMs) throw new Error('timeout');
    await new Promise((r) => setTimeout(r, 20));
  }
}

describe('poll · 快照差异（纯逻辑）', () => {
  test('新增 / 修改 / 删除分别产出 created / modified / deleted', () => {
    const prev = snap({ 'a.jpg': e(1, 100), 'b.jpg': e(2, 100), 'c.jpg': e(3, 100) });
    const next = snap({ 'a.jpg': e(1, 100), 'b.jpg': e(2, 999), 'd.jpg': e(4, 100) });
    const diff = diffSnapshot(prev, next);
    const byKind = diff.reduce<Record<string, string[]>>((acc, item) => {
      (acc[item.kind] ??= []).push(item.path);
      return acc;
    }, {});
    assert.deepEqual(byKind.created, ['d.jpg']);
    assert.deepEqual(byKind.modified, ['b.jpg']);
    assert.deepEqual(byKind.deleted, ['c.jpg']);
  });

  test('size 与 mtime 都没变时无差异', () => {
    assert.equal(diffSnapshot(snap({ 'a.jpg': e(1, 100) }), snap({ 'a.jpg': e(1, 100) })).length, 0);
  });

  test('首轮空基线把全部文件视为新增', () => {
    const diff = diffSnapshot(new Map(), snap({ 'a.jpg': e(1, 1), 'b.jpg': e(2, 2) }));
    assert.equal(diff.length, 2);
    assert.ok(diff.every((d) => d.kind === 'created'));
  });
});

describe('poll · 真实文件系统', () => {
  test('首轮只建基线不产出事件；之后新增/删除各产出一批', async () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-poll-'));
    fs.writeFileSync(path.join(root, 'a.jpg'), 'aaaa');

    const service = new PollService(undefined, { intervalMs: 120 });
    const batches: string[][] = [];
    const off = service.subscribe(root, (b) => void batches.push(b.events.map((x) => `${x.kind}:${path.basename(x.path)}`)));

    // 首轮基线：不发事件
    await new Promise((r) => setTimeout(r, 300));
    assert.equal(batches.length, 0);

    fs.writeFileSync(path.join(root, 'b.jpg'), 'bbbbbb');
    await waitUntil(() => batches.some((b) => b.includes('created:b.jpg')), 5000);

    fs.unlinkSync(path.join(root, 'b.jpg'));
    await waitUntil(() => batches.some((b) => b.includes('deleted:b.jpg')), 5000);

    off();
    assert.equal(service.stats().roots, 0);
    service.stopAll();
    fs.rmSync(root, { recursive: true, force: true });
  });

  test('订阅不存在的目录：失败计数，但不抛出', async () => {
    const service = new PollService(undefined, { intervalMs: 80 });
    const off = service.subscribe(path.join(os.tmpdir(), 'colanas-poll-missing-' + Date.now()), () => {});
    await new Promise((r) => setTimeout(r, 250));
    assert.ok(service.stats().failures >= 1);
    off();
    service.stopAll();
  });
});

describe('bus · 事件历史（客户端增量拉取）', () => {
  test('eventsSince 按序号返回并推进 nextSeq', () => {
    const bus = new EventBus();
    bus.emit('scan.done', { domain: 'photo' });
    bus.emit('scan.done', { domain: 'video' });
    bus.emit('other', {});

    const first = bus.eventsSince(0, 10);
    assert.equal(first.items.length, 3);
    assert.equal(first.nextSeq, 3);
    assert.equal(first.items[0].topic, 'scan.done');

    const second = bus.eventsSince(first.nextSeq, 10);
    assert.equal(second.items.length, 0);
    assert.equal(second.nextSeq, first.nextSeq);

    bus.emit('scan.done', { domain: 'music' });
    const third = bus.eventsSince(second.nextSeq, 10);
    assert.equal(third.items.length, 1);
    assert.deepEqual(third.items[0].data, { domain: 'music' });
  });

  test('序列表达 cursor，且历史有上限（不会无限增长）', () => {
    const bus = new EventBus();
    for (let i = 0; i < 300; i += 1) bus.emit('tick', { i });
    assert.equal(bus.cursor, 300);
    const items = bus.eventsSince(0, 300).items;
    assert.ok(items.length <= 256, `history=${items.length}`);
    // 保留的是最近的那批
    assert.equal(items[items.length - 1].seq, 300);
  });
});