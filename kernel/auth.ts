import crypto from 'node:crypto';

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
export function resolveSecret(): string {
  const env = process.env.COLANAS_JWT_SECRET;
  if (env && env.length >= 16) return env;
  return crypto.randomBytes(32).toString('hex');
}
