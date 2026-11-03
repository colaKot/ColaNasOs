import { ProxyAgent, fetch as undiciFetch } from 'undici';

/**
 * 全局代理出口：设置页保存后调用 `configureProxy` 立即生效。
 *
 * 只影响使用 `proxyFetch` 的出站请求（TMDB / IMDb / 番号源 / 海报下载）；
 * 不走代理的请求（本机 files 等）不受影响。代理进程内只创建一次，
 * 换地址时替换 agent（旧的交给 GC，undici 会自行关闭空闲连接）。
 */
let agent: ProxyAgent | null = null;
let active = '';

export function configureProxy(url: string): void {
  const clean = String(url ?? '').trim();
  if (clean === active) return;
  active = clean;
  agent = clean ? new ProxyAgent(clean) : null;
}

export function activeProxy(): string {
  return active;
}

/** 与全局 `fetch` 同签名，带代理时自动走 dispatcher */
export async function proxyFetch(
  url: string,
  init: Record<string, unknown> = {},
): Promise<Response> {
  const opts = agent ? { ...init, dispatcher: agent } : init;
  return undiciFetch(url, opts as never) as unknown as Promise<Response>;
}