import assert from 'node:assert/strict';
import test, { describe } from 'node:test';
import { detectTrailingJpegMp4, LIVE_MIN_BYTES } from '../src/modules/photo/live-photo';

/** 最小 JPEG：SOI + APP0 + SOS + 熵数据 + EOI（熵数据里不能出现 0xFFD9） */
function jpegBytes(): Buffer {
  const app0 = Buffer.from([
    0xff, 0xe0, 0x00, 0x10, // APP0, len=16
    0x4a, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00,
  ]);
  const sos = Buffer.from([
    0xff, 0xda, 0x00, 0x0c,
    0x03, 0x01, 0x00, 0x02, 0x11, 0x03, 0x11, 0x00, 0x3f, 0x00,
  ]);
  const scan = Buffer.from([0x12, 0x34, 0x56, 0x78, 0x9a]);
  const eoi = Buffer.from([0xff, 0xd9]);
  return Buffer.concat([Buffer.from([0xff, 0xd8]), app0, sos, scan, eoi]);
}

function ftypBox(): Buffer {
  const b = Buffer.alloc(24);
  b.writeUInt32BE(24, 0);
  b.write('ftyp', 4, 'latin1');
  b.write('isom', 8, 'latin1');
  b.writeUInt32BE(0x200, 12);
  b.write('isomiso2', 16, 'latin1');
  return b;
}

describe('detectTrailingJpegMp4', () => {
  test('JPEG EOI 之后紧跟 ftyp：识别为内嵌视频（荣耀形态）', () => {
    const jpg = jpegBytes();
    const video = Buffer.concat([ftypBox(), Buffer.alloc(LIVE_MIN_BYTES + 1024, 7)]);
    const buf = Buffer.concat([jpg, video]);
    const hit = detectTrailingJpegMp4(buf, buf.length);
    assert.ok(hit, '应命中');
    assert.equal(hit!.offset, jpg.length);
    assert.equal(hit!.size, buf.length - jpg.length);
    assert.equal(hit!.mime, 'video/mp4');
  });

  test('纯 JPEG（没有尾随负载）返回 null', () => {
    const buf = jpegBytes();
    assert.equal(detectTrailingJpegMp4(buf, buf.length), null);
  });

  test('尾随负载不是 ftyp（垃圾字节）返回 null', () => {
    const jpg = jpegBytes();
    const buf = Buffer.concat([jpg, Buffer.alloc(LIVE_MIN_BYTES + 512, 0x41)]);
    assert.equal(detectTrailingJpegMp4(buf, buf.length), null);
  });

  test('EOI 与 ftyp 之间允许厂商扩展段（荣耀 HiHonor_ExtInfo，实测 181 字节）', () => {
    const jpg = jpegBytes();
    // 模拟扩展段：4 字节长度 + 文本 + 对齐填充
    const ext = Buffer.alloc(181, 0x20);
    ext.writeUInt32BE(181, 0);
    ext.write('HiHonor_ExtInfo', 4, 'latin1');
    const buf = Buffer.concat([jpg, ext, ftypBox(), Buffer.alloc(LIVE_MIN_BYTES + 512, 7)]);
    const hit = detectTrailingJpegMp4(buf, buf.length);
    assert.ok(hit, '应命中');
    assert.equal(hit!.offset, jpg.length + 181);
  });

  test('ftyp 离 EOI 太远（>4 KB）不认，避免普通 JPEG 误判', () => {
    const jpg = jpegBytes();
    const buf = Buffer.concat([
      jpg,
      Buffer.alloc(8192, 0),
      ftypBox(),
      Buffer.alloc(LIVE_MIN_BYTES + 512, 7),
    ]);
    assert.equal(detectTrailingJpegMp4(buf, buf.length), null);
  });

  test('视频小于最小可信字节数返回 null', () => {
    const jpg = jpegBytes();
    const buf = Buffer.concat([jpg, ftypBox(), Buffer.alloc(1024, 7)]);
    assert.equal(detectTrailingJpegMp4(buf, buf.length), null);
  });
});
