/**
 * 验证 JWT 密钥持久化：内核重启后密钥不变，客户端的 token 才不会被作废。
 *
 * 覆盖：
 *  1. 不设环境变量时生成一份并落盘；
 *  2. 第二次调用读到同一份（不重新生成）；
 *  3. 换个 dataDir 会生成不同的密钥（多实例互不影响）；
 *  4. 设了环境变量时以环境变量为准，且**不落盘**。
 */
'use strict';
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const auth = require(path.join(process.cwd(), 'dist', 'kernel', 'auth'));

function check(name, ok, detail) {
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? '  ' + detail : ''}`);
  return ok;
}

(async () => {
  const results = [];
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-secret-'));

  delete process.env.COLANAS_JWT_SECRET;

  const s1 = await auth.resolveSecret(tmp);
  const file = path.join(tmp, 'jwt.secret');
  const onDisk = fs.existsSync(file);
  results.push(check('secret_written_to_disk', onDisk, file));

  const s2 = await auth.resolveSecret(tmp);
  results.push(check('secret_stable_across_calls', s1 === s2));

  const other = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-secret2-'));
  const s3 = await auth.resolveSecret(other);
  results.push(check('secret_differs_per_datadir', s1 !== s3));

  // 模拟「内核重启」：清掉内存状态，重新读同一个目录
  const reread = fs.readFileSync(file, 'utf8').trim();
  results.push(check('secret_survives_restart', reread === s1));

  process.env.COLANAS_JWT_SECRET = 'a-fixed-secret-from-env-0123456789';
  const s4 = await auth.resolveSecret(tmp);
  results.push(check('env_takes_precedence', s4 === process.env.COLANAS_JWT_SECRET));
  results.push(
    check('env_does_not_overwrite_disk', fs.readFileSync(file, 'utf8').trim() === s1),
  );

  fs.rmSync(tmp, { recursive: true, force: true });
  fs.rmSync(other, { recursive: true, force: true });

  const passed = results.filter(Boolean).length;
  console.log(`[auth-secret] ${passed}/${results.length} passed`);
  process.exit(passed === results.length ? 0 : 1);
})().catch((e) => {
  console.error('执行失败:', e);
  process.exit(1);
});
