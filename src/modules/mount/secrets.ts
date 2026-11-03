import { openSecret as open, sealSecret as seal } from '../../../kernel/secret-box';

/**
 * 远程挂载凭据加密（AES-256-GCM）：密文不含明文，密钥由进程级 secret 派生。
 *
 * 为什么不用 DB 明文：挂载配置会带 WebDAV/SMB 账号密码，落盘即可被窃取。
 * 通用加解密已抽到 `kernel/secret-box.ts`（salt 派生 + 按 salt 缓存派生密钥）；
 * 这里只固定本模块的 salt，**格式不变**（`v1:nonce:tag:cipher`），既有密文继续可解。
 */
const SALT = 'colanas-mount-v1';

export function sealSecret(plain: string): string {
  return seal(plain, SALT);
}

/** 解密失败返回 null（密钥变更 / 密文损坏），调用方按「凭据失效」处理 */
export function openSecret(sealed: string): string | null {
  return open(sealed, SALT);
}
