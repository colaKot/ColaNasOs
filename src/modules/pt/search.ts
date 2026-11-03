/**
 * PT 站点搜索：NexusPHP 兼容站点的**通用**解析。
 *
 * 站点模板差异很大，这里只依赖结构共同点：
 * - 每个种子行里有 `details.php?id=<torrentId>` 与 `download.php?id=<torrentId>`；
 * - 大小是 `1.23 GB` 这类文本；做种/下载是纯数字单元格。
 *
 * 解析失败一律返回空数组（不阻断订阅），并在结果里保留 `rawReason` 便于排障。
 */
export interface PtSearchItem {
  torrentId: string;
  title: string;
  sizeBytes: number | null;
  seeders: number | null;
  leechers: number | null;
  resolution: string | null;
  downloadUrl: string | null;
  detailUrl: string | null;
  publishedAt: string | null;
  infoHash: string | null;
}

export interface PtSearchOptions {
  baseUrl: string;
  keyword: string;
  cookie?: string;
  userAgent?: string;
  timeoutMs?: number;
  fetchImpl?: typeof fetch;
}

const SIZE_UNITS: Record<string, number> = {
  B: 1,
  KB: 1024,
  KIB: 1024,
  MB: 1024 ** 2,
  MIB: 1024 ** 2,
  GB: 1024 ** 3,
  GIB: 1024 ** 3,
  TB: 1024 ** 4,
  TIB: 1024 ** 4,
};

export function parseSize(text: string): number | null {
  const m = /([\d.]+)\s*(B|KB|KiB|MB|MiB|GB|GiB|TB|TiB)/i.exec(String(text || ''));
  if (!m) return null;
  const value = Number(m[1]);
  const unit = SIZE_UNITS[m[2].toUpperCase()];
  return Number.isFinite(value) && unit ? Math.round(value * unit) : null;
}

export function resolutionOf(title: string): string | null {
  const t = String(title || '').toLowerCase();
  if (/\b(2160p|4k|uhd)\b/.test(t)) return '2160p';
  if (/\b1440p\b/.test(t)) return '1440p';
  if (/\b1080p\b/.test(t)) return '1080p';
  if (/\b720p\b/.test(t)) return '720p';
  if (/\b480p\b/.test(t)) return '480p';
  return null;
}

/** 按 `<tr>` 切块后逐行解析（比整页一个正则稳） */
export function parseTorrentPage(html: string, baseUrl: string): PtSearchItem[] {
  const base = String(baseUrl || '').replace(/\/$/, '');
  const out: PtSearchItem[] = [];
  const rows = String(html || '')
    .split(/<tr[\s>]/i)
    .slice(1);
  for (const row of rows) {
    const detail = /href="([^"]*details\.php\?id=(\d+)[^"]*)"/i.exec(row);
    if (!detail) continue;
    const torrentId = detail[2];
    const download = /href="([^"]*download\.php\?id=\d+[^"]*)"/i.exec(row);
    const titleMatch =
      /<a[^>]+href="[^"]*details\.php\?id=\d+[^"]*"[^>]*>([\s\S]{1,300}?)<\/a>/i.exec(row) ??
      /title="([^"]{2,300})"/i.exec(row);
    const title = String(titleMatch?.[1] || '')
      .replace(/<[^>]+>/g, ' ')
      .replace(/&nbsp;/g, ' ')
      .replace(/&amp;/g, '&')
      .replace(/\s+/g, ' ')
      .trim();
    if (!title) continue;

    const cells = [...row.matchAll(/<td[^>]*>([\s\S]*?)<\/td>/gi)].map((m) =>
      m[1]
        .replace(/<[^>]+>/g, ' ')
        .replace(/&nbsp;/g, ' ')
        .trim(),
    );
    const sizeCell = cells.find((c) => /([\d.]+\s*(B|KB|KiB|MB|MiB|GB|GiB|TB|TiB))/i.test(c));
    const numbers = cells.filter((c) => /^\d+$/.test(c)).map(Number);

    out.push({
      torrentId,
      title,
      sizeBytes: sizeCell ? parseSize(sizeCell) : null,
      seeders: numbers.length >= 2 ? numbers[numbers.length - 2] : (numbers[0] ?? null),
      leechers: numbers.length >= 2 ? numbers[numbers.length - 1] : null,
      resolution: resolutionOf(title),
      downloadUrl: download
        ? download[1].startsWith('http')
          ? download[1]
          : `${base}/${download[1].replace(/^\/+/, '')}`
        : null,
      detailUrl: detail[1].startsWith('http')
        ? detail[1]
        : `${base}/${detail[1].replace(/^\/+/, '')}`,
      publishedAt: cells.find((c) => /^\d{4}-\d{2}-\d{2}/.test(c)) ?? null,
      infoHash: /([a-f0-9]{40})/i.exec(row)?.[1] ?? null,
    });
  }
  return out;
}

/** 搜索单个站点；失败返回空（不抛） */
export async function searchSite(
  opts: PtSearchOptions,
): Promise<{ items: PtSearchItem[]; reason: string }> {
  const base = String(opts.baseUrl || '').replace(/\/$/, '');
  const keyword = String(opts.keyword || '').trim();
  if (!base || !keyword) return { items: [], reason: 'bad_request' };

  const doFetch = opts.fetchImpl ?? fetch;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), Math.max(2000, opts.timeoutMs ?? 12_000));
  try {
    const url = `${base}/torrents.php?search=${encodeURIComponent(keyword)}&search_area=0&search_mode=0`;
    const res = await doFetch(url, {
      signal: controller.signal,
      headers: {
        'user-agent': opts.userAgent || 'Mozilla/5.0 (compatible; ColaNasOs/1.0)',
        ...(opts.cookie ? { cookie: opts.cookie } : {}),
      },
    });
    if (!res.ok) return { items: [], reason: `http_${res.status}` };
    const html = await res.text();
    const items = parseTorrentPage(html, base);
    return { items, reason: items.length > 0 ? 'ok' : 'empty' };
  } catch (err) {
    return { items: [], reason: String((err as Error)?.message || err).slice(0, 120) };
  } finally {
    clearTimeout(timer);
  }
}
