import assert from 'node:assert/strict';
import test from 'node:test';
import {
  absoluteInput,
  clearExtraRoots,
  isAbsoluteInput,
  registerExtraRoot,
  resolveAnyPath,
  resolveInRoot,
} from '../src/modules/files/fs-root';

/**
 * SMB（UNC）路径解析的回归测试。
 *
 * 背景：`isAbsoluteInput` 旧实现先 `replace(/^[/\\]+/, '')` 剥掉前导斜杠，再判
 * `startsWith('\\\\')` —— 剥完永远不成立，UNC 一律被当成相对路径。后果是
 * 影视来源根从不登记进 extraRoots，`\\host\share\x.jpg` 被拼到 filesRoot 下面，
 * stat 直接 ENOENT，表现为「SMB 里的海报明明在，页面全是占位图」（2026-11-04）。
 */

const winOnly = process.platform === 'win32' ? {} : { skip: 'UNC 的 path 语义只在 Windows 上成立' };

const UNC_IMG = '\\\\192.168.2.188\\unity\\高橋しょう子\\MIDE-360-poster.jpg';
const UNC_ROOT = '\\\\192.168.2.188\\unity';

test('UNC 被识别为绝对路径', () => {
  assert.equal(isAbsoluteInput(UNC_IMG), true);
  assert.equal(isAbsoluteInput(UNC_ROOT), true);
  assert.equal(isAbsoluteInput('D:/x/a.jpg'), true);
  // 前端 URL 会把 `D:/x` 编码成 `/D:/x`
  assert.equal(isAbsoluteInput('/D:/x/a.jpg'), true);
  assert.equal(isAbsoluteInput('a/b.jpg'), false);
  assert.equal(isAbsoluteInput(''), false);
});

test('absoluteInput 原样保留 UNC，不被剥成 host\\share', () => {
  assert.equal(absoluteInput(UNC_IMG), UNC_IMG);
  assert.equal(absoluteInput('/D:/x/a.jpg'), 'D:/x/a.jpg');
  assert.equal(absoluteInput('a/b.jpg'), 'a/b.jpg');
});

test('resolveInRoot 不把 UNC 当相对路径拼到 root 下', winOnly, () => {
  assert.throws(() => resolveInRoot('C:\\files', UNC_IMG), /outside allowed root/);
});

test('已登记的 SMB 根能解析出原 UNC 路径', winOnly, () => {
  clearExtraRoots();
  try {
    registerExtraRoot(UNC_ROOT);
    assert.equal(resolveAnyPath('C:\\files', UNC_IMG), UNC_IMG);
  } finally {
    clearExtraRoots();
  }
});

test('未登记的 UNC 仍然拒绝（不能借 UNC 绕过白名单）', winOnly, () => {
  clearExtraRoots();
  try {
    assert.throws(
      () => resolveAnyPath('C:\\files', '\\\\192.168.2.188\\other\\a.jpg'),
      /outside allowed root/,
    );
  } finally {
    clearExtraRoots();
  }
});
