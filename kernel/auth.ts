import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

export interface TokenPayload {
  sub: string;
  scopes: string[];
  iat: number;
  exp: number;
}

export interface SignOptions {
  ttlSec?: number;
}

function b64url(buf: Buffer): string {
  return buf.toString('base64').replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
}

function fromB64url(s: string): Buffer {
  const pad = s.length % 4 === 0 ? '' : '='.repeat(4 - (s.length % 4));
  return Buffer.from(s.replace(/-/g, '+').replace(/_/g, '/') + pad, 'base64');
}

/** HS256 JWT（零依赖，用于内核最小认证） */
export function signToken(
  payload: { sub: string; scopes: string[] },
  secret: string,
  opts: SignOptions = {},
): string {
  const ttl = opts.ttlSec ?? 3600;
  const now = Math.floor(Date.now() / 1000);

  const header = b64url(Buffer.from(JSON.stringify({ alg: 'HS256', typ: 'JWT' })));
  const body = b64url(
    Buffer.from(JSON.stringify({ ...payload, iat: now, exp: now + ttl }), 'utf-8'),
  );
  const sig = b64url(crypto.createHmac('sha256', secret).update(`${header}.${body}`).digest());

  return `${header}.${body}.${sig}`;
}

export function verifyToken(token: string, secret: string): TokenPayload | null {
  const parts = String(token || '').split('.');
  if (parts.length !== 3) return null;

  const [header, body, sig] = parts;
  const expected = b64url(crypto.createHmac('sha256', secret).update(`${header}.${body}`).digest());

  if (sig.length !== expected.length) return null;
  if (!crypto.timingSafeEqual(Buffer.from(sig), Buffer.from(expected))) return null;

  try {
    const payload = JSON.parse(fromB64url(body).toString('utf-8')) as TokenPayload;
    if (typeof payload.exp !== 'number') return null;
    if (payload.exp < Math.floor(Date.now() / 1000)) return null;
    if (!Array.isArray(payload.scopes)) return null;
    return payload;
  } catch {
    return null;
  }
}

export function hasScope(payload: TokenPayload, scope: string): boolean {
  if (payload.scopes.includes('*')) return true;
  if (payload.scopes.includes(scope)) return true;
  // 支持 files:* 形式
  const [group] = scope.split(':');
  return payload.scopes.includes(`${group}:*`);
}

/** 从环境读取密钥；未配置时用进程级随机值（重启后旧 token 失效） */
/**
 * 取 JWT 签名密钥。
 *
 * 优先级：环境变量 > `<dataDir>/jwt.secret` > 新生成并落盘。
 *
 * **必须持久化的原因**：旧实现不设环境变量就直接 `randomBytes` 随机生成，
 * 内核每重启一次密钥就变 —— 所有客户端手里的 token 全部作废，用户看到的现象是
 * 「明明勾了自动登录，每次打开客户端还是被踢回登录页，得重新输密码」。
 * 落盘后重启不再踢人；改密钥的需求（怀疑泄露）靠删掉 `jwt.secret` 即可。
 */
export async function resolveSecret(dataDir?: string): Promise<string> {
  const env = process.env.COLANAS_JWT_SECRET;
  if (env && env.length >= 16) return env;
  if (dataDir) {
    const file = path.join(dataDir, 'jwt.secret');
    try {
      const cached = fs.readFileSync(file, 'utf8').trim();
      if (cached.length >= 32) return cached;
    } catch {
      // 文件不存在或读不到：下面生成一份
    }
    const generated = crypto.randomBytes(32).toString('hex');
    try {
      fs.mkdirSync(path.dirname(file), { recursive: true });
      fs.writeFileSync(file, generated, { encoding: 'utf8', mode: 0o600 });
    } catch {
      // 落盘失败（只读目录等）：本次仍用内存里的密钥，下一次启动会再变一次
    }
    return generated;
  }
  return crypto.randomBytes(32).toString('hex');
}
