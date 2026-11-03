import fs from 'node:fs';
import path from 'node:path';
import { proxyFetch } from '../../../kernel/proxy-fetch';

/**
 * TMDB 客户端（影视发现的数据源）。
 *
 * 约束：
 *   - **没有 key / 没有外网就明确返回不可用**，不做「静默空列表」——界面要能说清为什么没数据；
 *   - 所有请求 8s 超时，失败抛 `DiscoverUnavailable`，由路由降级成 `degraded + reason`；
 *   - 图片走服务端代理并落盘缓存：TMDB 图片域在部分网络下不可达，客户端也拿不到 key。
 */
export class DiscoverUnavailable extends Error {
  code = 'E_DISCOVER_UNAVAILABLE';
}

export interface TmdbConfig {
  apiKey: string;
  baseUrl: string;
  language: string;
  imageBase: string;
  proxy?: string;
}

const DEFAULT_BASE = 'https://api.themoviedb.org/3';
const DEFAULT_IMAGE = 'https://image.tmdb.org/t/p';

export function normalizeConfig(input: unknown): TmdbConfig {
  const raw = (input || {}) as Record<string, unknown>;
  return {
    apiKey: String(raw.apiKey || '').trim(),
    baseUrl: String(raw.baseUrl || DEFAULT_BASE).trim().replace(/\/+$/, ''),
    language: String(raw.language || 'zh-CN').trim() || 'zh-CN',
    imageBase: String(raw.imageBase || DEFAULT_IMAGE).trim().replace(/\/+$/, ''),
    proxy: String(raw.proxy || '').trim() || undefined,
  };
}

export function isConfigured(cfg: TmdbConfig): boolean {
  return Boolean(cfg.apiKey);
}

async function fetchJson(url: string, timeoutMs = 8000): Promise<any> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await proxyFetch(url, { signal: controller.signal });
    if (!res.ok) {
      throw new DiscoverUnavailable(`TMDB HTTP ${res.status}`);
    }
    return await res.json();
  } catch (err) {
    const msg = String((err as Error)?.message || err);
    throw new DiscoverUnavailable(`TMDB 请求失败：${msg.slice(0, 120)}`);
  } finally {
    clearTimeout(timer);
  }
}

/** 拼 TMDB 请求地址（官方同时支持 api_key 与 v4 Bearer；这里用 api_key，配置最简单） */
export function buildUrl(
  cfg: TmdbConfig,
  apiPath: string,
  params: Record<string, string | number | undefined> = {},
): string {
  const url = new URL(`${cfg.baseUrl}${apiPath}`);
  url.searchParams.set('api_key', cfg.apiKey);
  url.searchParams.set('language', cfg.language);
  for (const [key, value] of Object.entries(params)) {
    if (value === undefined || value === '') continue;
    url.searchParams.set(key, String(value));
  }
  return url.toString();
}

export async function tmdbGet(
  cfg: TmdbConfig,
  apiPath: string,
  params: Record<string, string | number | undefined> = {},
): Promise<any> {
  if (!isConfigured(cfg)) throw new DiscoverUnavailable('未配置 TMDB API Key');
  return fetchJson(buildUrl(cfg, apiPath, params));
}

/** TMDB 的图片尺寸档位（与官方一致） */
export const IMAGE_SIZES = new Set(['w92', 'w154', 'w185', 'w342', 'w500', 'w780', 'original']);

export function imageUrl(cfg: TmdbConfig, filePath: string, size = 'w342'): string {
  const sz = IMAGE_SIZES.has(size) ? size : 'w342';
  const clean = String(filePath || '').startsWith('/') ? filePath : `/${filePath}`;
  return `${cfg.imageBase}/${sz}${clean}`;
}

/** 拉一张图片到本地（已有且非空直接复用）；返回绝对路径或 null */
export async function fetchImageTo(
  cfg: TmdbConfig,
  filePath: string,
  size: string,
  dir: string,
): Promise<{ file: string; contentType: string } | null> {
  const sz = IMAGE_SIZES.has(size) ? size : 'w342';
  const url = imageUrl(cfg, filePath, sz);
  const hash = Buffer.from(`${sz}:${filePath}`).toString('base64url');
  const target = path.join(dir, sz, `${hash}.img`);
  try {
    const st = fs.statSync(target);
    if (st.size > 0) return { file: target, contentType: 'image/jpeg' };
  } catch {
    /* 未缓存 */
  }
  try {
    fs.mkdirSync(path.dirname(target), { recursive: true });
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 10_000);
    try {
      const res = await proxyFetch(url, { signal: controller.signal });
      if (!res.ok) return null;
      const buf = Buffer.from(await res.arrayBuffer());
      fs.writeFileSync(target, buf);
      return { file: target, contentType: res.headers.get('content-type') || 'image/jpeg' };
    } finally {
      clearTimeout(timer);
    }
  } catch {
    return null;
  }
}