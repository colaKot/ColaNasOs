import crypto from 'node:crypto';

/**
 * 落盘敏感字段加密（AES-256-GCM），密钥由进程级 secret + 用途 salt 派生。
 *
 * 为什么单独抽一层：远程挂载凭据（`src/modules/mount`）和 TOTP secret（`src/modules/auth`）
 * 都要「密文落库、密钥不落库」。salt 参与派生，使同一进程密钥在不同用途下得到不同子密钥，
 * 一类密文泄露不会牵连另一类。
 *
 * 密钥来源与 JWT 一致（`COLANAS_JWT_SECRET`），未配置时用固定开发值——与原先 mount 的行为
 * 保持一致（密文可跨重启解密）。派生结果按 salt 缓存：scrypt 是刻意慢的函数，
 * 不能每次登录都付一遍 cost。
 *
 * 密文格式：`v1:<nonce>:<tag>:<cipher>`，三段均为 base64url。
 */
const keys = new Map<string, Buffer>();

function key(salt: string): Buffer {
  const cached = keys.get(salt);
  if (cached) return cached;
  const secret = process.env.COLANAS_JWT_SECRET || 'colanas-dev-secret-please-set';
  const derived = crypto.scryptSync(secret, salt, 32);
  keys.set(salt, derived);
  return derived;
}

export function sealSecret(plain: string, salt: string): string {
  const nonce = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', key(salt), nonce);
  const enc = Buffer.concat([cipher.update(plain, 'utf8'), cipher.final()]);
  const tag = cipher.getAuthTag();
  return [
    'v1',
    nonce.toString('base64url'),
    tag.toString('base64url'),
    enc.toString('base64url'),
  ].join(':');
}

/** 解密失败返回 null（密钥变更 / 密文损坏），调用方按「凭据失效」处理 */
export function openSecret(sealed: string, salt: string): string | null {
  const parts = sealed.split(':');
  if (parts.length !== 4 || parts[0] !== 'v1') return null;
  try {
    const nonce = Buffer.from(parts[1], 'base64url');
    const tag = Buffer.from(parts[2], 'base64url');
    const data = Buffer.from(parts[3], 'base64url');
    const decipher = crypto.createDecipheriv('aes-256-gcm', key(salt), nonce);
    decipher.setAuthTag(tag);
    return Buffer.concat([decipher.update(data), decipher.final()]).toString('utf8');
  } catch {
    return null;
  }
}

/** 是否为本模块产出的密文（用于识别未加密的历史数据） */
export function isSealed(value: string | null | undefined): boolean {
  return typeof value === 'string' && value.startsWith('v1:') && value.split(':').length === 4;
}
