import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import tls from 'node:tls';

/**
 * HTTPS 证书（用户上传方案）。
 *
 * 这里不生成自签证书：证书由用户在设置页上传 cert + key，
 * 落盘到 `<dataDir>/tls/`（私钥权限 600）。启动时若 `httpsEnabled`
 * 且证书存在，内核会额外起一个 HTTPS 入口代理到 HTTP 主监听。
 *
 * 校验两道：`tls.createSecureContext`（PEM/密钥可用）+ 公钥比对（配对）。
 */

const CERT_FILE = 'cert.pem';
const KEY_FILE = 'key.pem';

export function tlsDir(dataDir: string): string {
  return path.join(dataDir, 'tls');
}

export function hasTls(dataDir: string): boolean {
  return (
    fs.existsSync(path.join(tlsDir(dataDir), CERT_FILE)) &&
    fs.existsSync(path.join(tlsDir(dataDir), KEY_FILE))
  );
}

export function readTls(dataDir: string): { cert: string; key: string } | null {
  try {
    return {
      cert: fs.readFileSync(path.join(tlsDir(dataDir), CERT_FILE), 'utf-8'),
      key: fs.readFileSync(path.join(tlsDir(dataDir), KEY_FILE), 'utf-8'),
    };
  } catch {
    return null;
  }
}

/** 返回 null = 合法；否则返回错误说明 */
export function validateTlsPair(cert: string, key: string): string | null {
  if (!cert.includes('BEGIN CERTIFICATE') || !key.includes('PRIVATE KEY')) {
    return 'cert/key must be PEM';
  }
  try {
    tls.createSecureContext({ cert, key });
    const fromKey = crypto
      .createPublicKey(crypto.createPrivateKey(key))
      .export({ type: 'spki', format: 'pem' });
    const fromCert = new crypto.X509Certificate(cert).publicKey.export({
      type: 'spki',
      format: 'pem',
    });
    if (String(fromKey) !== String(fromCert)) {
      return 'certificate and private key do not match';
    }
    return null;
  } catch (err) {
    return String((err as Error)?.message || err).slice(0, 200);
  }
}

export function saveTls(dataDir: string, cert: string, key: string): void {
  const dir = tlsDir(dataDir);
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, CERT_FILE), cert, { encoding: 'utf-8', mode: 0o600 });
  fs.writeFileSync(path.join(dir, KEY_FILE), key, { encoding: 'utf-8', mode: 0o600 });
}

export function clearTls(dataDir: string): void {
  try {
    fs.rmSync(tlsDir(dataDir), { recursive: true, force: true });
  } catch {
    /* 已被删除 / 占用：忽略 */
  }
}

export interface TlsInfo {
  hasCert: boolean;
  subject: string;
  validFrom: string;
  validTo: string;
}

export function tlsInfo(dataDir: string): TlsInfo {
  const tlsPair = readTls(dataDir);
  if (!tlsPair) return { hasCert: false, subject: '', validFrom: '', validTo: '' };
  try {
    const cert = new crypto.X509Certificate(tlsPair.cert);
    return {
      hasCert: true,
      subject: cert.subject.replace(/\n/g, ', ').slice(0, 300),
      validFrom: cert.validFrom,
      validTo: cert.validTo,
    };
  } catch {
    return { hasCert: false, subject: '', validFrom: '', validTo: '' };
  }
}