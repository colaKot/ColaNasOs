/**
 * M-Team 专有 API（非 NexusPHP HTML）。
 *
 * `POST {base}/api/torrent/search`，头 `x-api-key`；分页 JSON。
 * 下载链接用 `/api/torrent/download/{id}?apiKey=...`（transmission 直接拉）。
 *
 * 失败一律返回空 + 原因（订阅不会被一个站点的 API 变更拖死）。
 */
export interface MTeamTorrent {
  torrentId: string;
  title: string;
  sizeBytes: number | null;
  seeders: number | null;
  leechers: number | null;
  downloadUrl: string | null;
  infoHash: string | null;
  publishedAt: string | null;
}

export interface MTeamOptions {
  baseUrl: string;
  apiKey: string;
  keyword: string;
  timeoutMs?: number;
  fetchImpl?: typeof fetch;
}

const CATEGORY_MAP: Record<string, string[]> = {
  movie: ['401'],
  tv: ['402'],
  animation: ['404'],
  documentary: ['403'],
};

export function categoryIds(kind: 'movie' | 'tv' | 'animation' | 'documentary' | 'all'): string[] {
  if (kind === 'all') return [];
  return CATEGORY_MAP[kind] ?? [];
}

export function downloadUrl(baseUrl: string, torrentId: string, apiKey: string): string {
  const base = String(baseUrl || '').replace(/\/$/, '');
  return `${base}/api/torrent/download/${encodeURIComponent(torrentId)}?apiKey=${encodeURIComponent(apiKey)}`;
}

/** 解析 M-Team 搜索响应（结构可能微调，字段都做可选处理） */
export function parseMTeam(json: unknown, baseUrl: string, apiKey: string): MTeamTorrent[] {
  const root = json as { data?: { data?: unknown[] } } | null;
  const list = root?.data?.data;
  if (!Array.isArray(list)) return [];
  const out: MTeamTorrent[] = [];
  for (const raw of list) {
    const item = raw as Record<string, any>;
    const id = String(item.id ?? '').trim();
    const title = String(item.name ?? '').trim();
    if (!id || !title) continue;
    const size = Number(item.size);
    const status = (item.status || {}) as Record<string, unknown>;
    const seeders = Number(status.seeders ?? item.seeders);
    const leechers = Number(status.leechers ?? item.leechers);
    out.push({
      torrentId: id,
      title,
      sizeBytes: Number.isFinite(size) && size > 0 ? size : null,
      seeders: Number.isFinite(seeders) ? seeders : null,
      leechers: Number.isFinite(leechers) ? leechers : null,
      downloadUrl: downloadUrl(baseUrl, id, apiKey),
      infoHash: String(item.infoHash ?? item.info_hash ?? '') || null,
      publishedAt: String(item.createdDate ?? item.created_at ?? '') || null,
    });
  }
  return out;
}

export async function searchMTeam(
  opts: MTeamOptions,
  kind: 'movie' | 'tv' | 'animation' | 'documentary' | 'all' = 'all',
): Promise<{ items: MTeamTorrent[]; reason: string }> {
  const base = String(opts.baseUrl || '').replace(/\/$/, '');
  const keyword = String(opts.keyword || '').trim();
  if (!base || !opts.apiKey || !keyword) return { items: [], reason: 'bad_request' };

  const doFetch = opts.fetchImpl ?? fetch;
  const controller = new globalThis.AbortController();
  const timer = setTimeout(() => controller.abort(), Math.max(3000, opts.timeoutMs ?? 12_000));
  try {
    const res = await doFetch(`${base}/api/torrent/search`, {
      method: 'POST',
      signal: controller.signal,
      headers: {
        'content-type': 'application/json',
        'x-api-key': opts.apiKey,
        'user-agent': 'Mozilla/5.0 (compatible; ColaNasOs/1.0)',
      },
      // ⚠️ 关键词字段是 `keyword`，不是 `searchEntry`。
      // 早先写成 searchEntry 时接口**不报错**、只是忽略关键词，直接回最新 50 条，
      // 于是「搜生化危机」拿到一堆无关种子 → 全被判 TITLE_MISMATCH 排除 →
      // 页面表现为「搜索什么都没有」。
      // 分页字段各版本叫法不同（page/size 与 pageNumber/pageSize 都出现过），一起带上，
      // 多传的字段接口会忽略。
      body: JSON.stringify({
        mode: 'normal',
        categories: categoryIds(kind),
        keyword,
        page: 1,
        size: 50,
        pageNumber: 1,
        pageSize: 50,
        visible: 1,
      }),
    });
    if (!res.ok) return { items: [], reason: `http_${res.status}` };
    const json = await res.json();
    // M-Team 用 `{code, message, data}` 包一层：code!==0（0 或 1 视版本）都是业务错误，
    // 直接把 message 带回去，页面「站点异常」区块能显示「key無效」这种真实原因，
    // 而不是含糊的 empty。
    const root = json as { code?: number | string; message?: string; data?: unknown } | null;
    const apiCode = Number(root?.code ?? 0);
    if (apiCode !== 0 && !root?.data) {
      return { items: [], reason: `api_${apiCode}:${String(root?.message || '').slice(0, 60)}` };
    }
    const items = parseMTeam(json, base, opts.apiKey);
    return { items, reason: items.length > 0 ? 'ok' : 'empty' };
  } catch (err) {
    return { items: [], reason: String((err as Error)?.message || err).slice(0, 120) };
  } finally {
    clearTimeout(timer);
  }
}
