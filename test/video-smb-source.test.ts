import assert from 'node:assert/strict';
import test from 'node:test';
import { normalizeSourceInput } from '../src/modules/video/sources';

test('SMB 主机里直接粘完整 UNC：拆成 host / share / subPath', () => {
  const out = normalizeSourceInput({
    connType: 'smb',
    host: '\\\\192.168.2.188\\unity\\Movies',
    share: '',
    subPath: '',
    username: 'cola',
    password: 'pw',
  });
  assert.equal(out.conn_type, 'smb');
  assert.equal(out.host, '192.168.2.188');
  assert.equal(out.share, 'unity');
  assert.equal(out.sub_path, 'Movies');
  assert.equal(out.root_path, '\\\\192.168.2.188\\unity\\Movies');
});

test('SMB 主机带前导反斜杠、共享名单独填写', () => {
  const out = normalizeSourceInput({
    connType: 'smb',
    host: '\\\\192.168.2.188',
    share: '\\unity',
  });
  assert.equal(out.host, '192.168.2.188');
  assert.equal(out.share, 'unity');
  assert.equal(out.root_path, '\\\\192.168.2.188\\unity');
});
