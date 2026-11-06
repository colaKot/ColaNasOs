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
/** 环境变量代理（HTTP_PROXY / HTTPS_PROXY）：设置页没填时兜底，抓国外 RSS 靠它 */
let envAgent: ProxyAgent | null = null;
let envChecked = false;

function envProxyAgent(): ProxyAgent | null {
  if (envChecked) return envAgent;
  envChecked = true;
  const url = (
    process.env.HTTPS_PROXY ||
    process.env.https_proxy ||
    process.env.HTTP_PROXY ||
    process.env.http_proxy ||
    ''
  ).trim();
  if (url) envAgent = new ProxyAgent(url);
  return envAgent;
}

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
  // 设置页填的代理优先；没填时用环境变量里的代理（很多人是靠 HTTP(S)_PROXY 配的）
  const dispatcher = agent ?? envProxyAgent();
  const opts = dispatcher ? { ...init, dispatcher } : init;
  return undiciFetch(url, opts as never) as unknown as Promise<Response>;
}