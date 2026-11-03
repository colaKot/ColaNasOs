import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test, { describe } from 'node:test';
import { pdfPageCount, renderPdfPage, resetPdfCache } from '../src/modules/book/pdf';

/** 生成带正确 xref 的最小 PDF（pageCount 页，200x100）。 */
function minimalPdf(pageCount: number): Buffer {
  const objs: string[] = [
    '1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n',
    `2 0 obj\n<< /Type /Pages /Kids [${Array.from({ length: pageCount }, (_, i) => `${i + 3} 0 R`).join(' ')}] /Count ${pageCount} >>\nendobj\n`,
  ];
  for (let i = 0; i < pageCount; i += 1) {
    objs.push(
      `${i + 3} 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] /Resources << >> >>\nendobj\n`,
    );
  }

  let pdf = '%PDF-1.4\n';
  const offsets = [0];
  for (const obj of objs) {
    offsets.push(Buffer.byteLength(pdf));
    pdf += obj;
  }
  const xrefPos = Buffer.byteLength(pdf);
  pdf += `xref\n0 ${objs.length + 1}\n0000000000 65535 f \n`;
  for (let i = 1; i <= objs.length; i += 1) {
    pdf += `${String(offsets[i]).padStart(10, '0')} 00000 n \n`;
  }
  pdf += `trailer\n<< /Size ${objs.length + 1} /Root 1 0 R >>\nstartxref\n${xrefPos}\n%%EOF\n`;
  return Buffer.from(pdf, 'latin1');
}

describe('book · pdf 渲染', () => {
  test('页数与渲染产出 PNG，越界返回 null', async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-pdf-'));
    const abs = path.join(dir, 'doc.pdf');
    fs.writeFileSync(abs, minimalPdf(2));
    try {
      assert.equal(await pdfPageCount(abs), 2);

      const page = await renderPdfPage(abs, 0, dir, 400);
      assert.ok(page, 'page 0 应渲染成功');
      assert.equal(page.total, 2);
      // PNG magic: 89 50 4E 47 0D 0A 1A 0A
      assert.deepEqual([...page.png.subarray(0, 8)], [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

      const cached = await renderPdfPage(abs, 0, dir, 400);
      assert.ok(cached);
      assert.equal(cached.png.length, page.png.length, '第二次应命中磁盘缓存');

      assert.equal(await renderPdfPage(abs, 5, dir, 400), null);
    } finally {
      await resetPdfCache();
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  test('损坏文件：页数 0、渲染 null（不抛错）', async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-pdf-bad-'));
    const abs = path.join(dir, 'bad.pdf');
    fs.writeFileSync(abs, Buffer.from('not a pdf at all', 'latin1'));
    try {
      assert.equal(await pdfPageCount(abs), 0);
      assert.equal(await renderPdfPage(abs, 0, dir), null);
    } finally {
      await resetPdfCache();
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });
});