/**
 * Transmission RPC 客户端（只做本项目需要的两件事：加种、探活）。
 *
 * 坑：Transmission 要求先拿 `X-Transmission-Session-Id`（首次请求返回 409 并带该头），
 * 第二次请求必须带上它；忘记重试会得到 409 而不是明确错误。
 */
export interface TransmissionConfig {
  url: string;
  username?: string | null;
  password?: string | null;
}

export interface TransmissionResult {
  ok: boolean;
  id?: number | string;
  name?: string;
  /** torrent 的 info hash（暂停/恢复/删除要用） */
  hash?: string;
  message: string;
}

function basicAuth(cfg: TransmissionConfig): Record<string, string> {
  if (!cfg.username) return {};
  const token = Buffer.from(`${cfg.username}:${cfg.password ?? ''}`).toString('base64');
  return { authorization: `Basic ${token}` };
}

async function rpc(
  cfg: TransmissionConfig,
  body: unknown,
  opts: { timeoutMs?: number; fetchImpl?: typeof fetch; sessionId?: string | null } = {},
): Promise<{ status: number; sessionId: string | null; json: any }> {
  const doFetch = opts.fetchImpl ?? fetch;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), Math.max(2000, opts.timeoutMs ?? 10_000));
  try {
    const res = await doFetch(String(cfg.url || '').replace(/\/$/, ''), {
      method: 'POST',
      signal: controller.signal,
      headers: {
        'content-type': 'application/json',
        ...basicAuth(cfg),
        ...(opts.sessionId ? { 'x-transmission-session-id': opts.sessionId } : {}),
      },
      body: JSON.stringify(body),
    });
    const sessionId = res.headers.get('x-transmission-session-id');
    let json: any = null;
    try {
      json = await res.json();
    } catch {
      json = null;
    }
    return { status: res.status, sessionId, json };
  } finally {
    clearTimeout(timer);
  }
}

export async function addTorrent(
  cfg: TransmissionConfig,
  filename: string,
  opts: {
    timeoutMs?: number;
    fetchImpl?: typeof fetch;
    downloadDir?: string;
    /** true = 只加种不开始（RSS「不立即下载」时用：先把种子挂上去，等用户手动开始） */
    paused?: boolean;
  } = {},
): Promise<TransmissionResult> {
  if (!cfg.url) return { ok: false, message: 'transmission url not configured' };
  if (!filename) return { ok: false, message: 'torrent url required' };

  const args: Record<string, unknown> = { filename, paused: opts.paused === true };
  // download-dir 是「下载器所在机器」的绝对路径；单机 NAS 口径下由服务端
  // 把影视库根解析成绝对路径再传，跨机部署不保证一致。
  if (opts.downloadDir) args['download-dir'] = opts.downloadDir;
  const payload = {
    method: 'torrent-add',
    arguments: args,
  };

  try {
    let res = await rpc(cfg, payload, opts);
    if (res.status === 409 && res.sessionId) {
      res = await rpc(cfg, payload, { ...opts, sessionId: res.sessionId });
    }
    if (res.status !== 200) {
      return { ok: false, message: `transmission http ${res.status}` };
    }
    const result = res.json?.result;
    if (result !== 'success') {
      return { ok: false, message: String(res.json?.result || 'rpc failed') };
    }
    const added =
      res.json?.arguments?.['torrent-added'] ?? res.json?.arguments?.['torrent-duplicate'];
    return {
      ok: true,
      id: added?.id,
      name: added?.name,
      hash: added?.hashString ? String(added.hashString) : undefined,
      message: res.json?.arguments?.['torrent-duplicate'] ? 'duplicate' : 'added',
    };
  } catch (err) {
    return { ok: false, message: String((err as Error)?.message || err).slice(0, 160) };
  }
}

/**
 * 对已加种的 torrent 做暂停 / 恢复 / 删除。
 * 删除只移除任务，**不删本地数据**（delete-local-data=false），避免误删下载完成的文件。
 */
export async function torrentAction(
  cfg: TransmissionConfig,
  action: 'start' | 'stop' | 'remove',
  hash: string,
  opts: { timeoutMs?: number; fetchImpl?: typeof fetch } = {},
): Promise<TransmissionResult> {
  if (!cfg.url) return { ok: false, message: 'transmission url not configured' };
  if (!hash) return { ok: false, message: 'torrent hash required' };
  const method =
    action === 'start' ? 'torrent-start' : action === 'stop' ? 'torrent-stop' : 'torrent-remove';
  const args: Record<string, unknown> = { ids: [hash] };
  if (action === 'remove') args['delete-local-data'] = false;
  try {
    const payload = { method, arguments: args };
    let res = await rpc(cfg, payload, opts);
    if (res.status === 409 && res.sessionId) {
      res = await rpc(cfg, payload, { ...opts, sessionId: res.sessionId });
    }
    if (res.status !== 200) {
      return { ok: false, message: `transmission http ${res.status}` };
    }
    if (res.json?.result !== 'success') {
      return { ok: false, message: String(res.json?.result || 'rpc failed') };
    }
    return { ok: true, message: 'ok' };
  } catch (err) {
    return { ok: false, message: String((err as Error)?.message || err).slice(0, 160) };
  }
}

export async function transmissionStatus(
  cfg: TransmissionConfig,
  opts: { timeoutMs?: number; fetchImpl?: typeof fetch } = {},
): Promise<{ ok: boolean; message: string; version?: string }> {
  if (!cfg.url) return { ok: false, message: 'transmission url not configured' };
  try {
    const payload = { method: 'session-get' };
    let res = await rpc(cfg, payload, opts);
    if (res.status === 409 && res.sessionId) {
      res = await rpc(cfg, payload, { ...opts, sessionId: res.sessionId });
    }
    if (res.status !== 200 || res.json?.result !== 'success') {
      return { ok: false, message: `transmission http ${res.status}` };
    }
    return { ok: true, message: 'ok', version: String(res.json?.arguments?.version || '') };
  } catch (err) {
    return { ok: false, message: String((err as Error)?.message || err).slice(0, 160) };
  }
}

/**
 * 批量读取 torrent 实时状态（参考实现 1:1 的 downloads/sync-status 用）。
 * Transmission status: 0=已暂停, 1~5=排队/下载/做种, 6=完成。
 */
export async function torrentGet(
  cfg: TransmissionConfig,
  hashes: string[],
  opts: { timeoutMs?: number; fetchImpl?: typeof fetch } = {},
): Promise<{
  ok: boolean;
  message: string;
  items: Array<{ hashString: string; status: number; percentDone: number; name: string }>;
}> {
  if (!cfg.url) return { ok: false, message: 'transmission url not configured', items: [] };
  if (!hashes.length) return { ok: true, message: 'ok', items: [] };
  try {
    const payload = {
      method: 'torrent-get',
      arguments: { ids: hashes, fields: ['hashString', 'status', 'percentDone', 'name'] },
    };
    let res = await rpc(cfg, payload, opts);
    if (res.status === 409 && res.sessionId) {
      res = await rpc(cfg, payload, { ...opts, sessionId: res.sessionId });
    }
    if (res.status !== 200 || res.json?.result !== 'success') {
      return { ok: false, message: `transmission http ${res.status}`, items: [] };
    }
    const list = (res.json?.arguments?.torrents ?? []) as Array<Record<string, unknown>>;
    return {
      ok: true,
      message: 'ok',
      items: list.map((t) => ({
        hashString: String(t.hashString ?? ''),
        status: Number(t.status ?? 0),
        percentDone: Number(t.percentDone ?? 0),
        name: String(t.name ?? ''),
      })),
    };
  } catch (err) {
    return {
      ok: false,
      message: String((err as Error)?.message || err).slice(0, 160),
      items: [],
    };
  }
}

export interface TorrentInfo {
  hashString: string;
  name: string;
  /** Transmission: 0=暂停 1~2=校验 3~4=下载 5~6=做种 */
  status: number;
  percentDone: number;
  rateDownload: number;
  rateUpload: number;
  totalSize: number;
  downloadedEver: number;
  uploadRatio: number;
  /** 预计剩余秒数；-1 = 未知，-2 = 不会完成 */
  eta: number;
  addedDate: number;
  error: number;
  errorString: string;
  downloadDir: string;
}

/** 读全部 torrent 的实时状态（Transmission 一级页面用；不带 ids 即「全部」） */
export async function torrentList(
  cfg: TransmissionConfig,
  opts: { timeoutMs?: number; fetchImpl?: typeof fetch } = {},
): Promise<{ ok: boolean; message: string; items: TorrentInfo[] }> {
  if (!cfg.url) return { ok: false, message: 'transmission url not configured', items: [] };
  const payload = {
    method: 'torrent-get',
    arguments: {
      fields: [
        'hashString',
        'name',
        'status',
        'percentDone',
        'rateDownload',
        'rateUpload',
        'totalSize',
        'downloadedEver',
        'uploadRatio',
        'eta',
        'addedDate',
        'error',
        'errorString',
        'downloadDir',
      ],
    },
  };
  try {
    let res = await rpc(cfg, payload, opts);
    if (res.status === 409 && res.sessionId) {
      res = await rpc(cfg, payload, { ...opts, sessionId: res.sessionId });
    }
    if (res.status !== 200 || res.json?.result !== 'success') {
      return { ok: false, message: `transmission http ${res.status}`, items: [] };
    }
    const list = (res.json?.arguments?.torrents ?? []) as Array<Record<string, unknown>>;
    return {
      ok: true,
      message: 'ok',
      items: list.map((t) => ({
        hashString: String(t.hashString ?? ''),
        name: String(t.name ?? ''),
        status: Number(t.status ?? 0),
        percentDone: Number(t.percentDone ?? 0),
        rateDownload: Number(t.rateDownload ?? 0),
        rateUpload: Number(t.rateUpload ?? 0),
        totalSize: Number(t.totalSize ?? 0),
        downloadedEver: Number(t.downloadedEver ?? 0),
        uploadRatio: Number(t.uploadRatio ?? 0),
        eta: Number(t.eta ?? -1),
        addedDate: Number(t.addedDate ?? 0),
        error: Number(t.error ?? 0),
        errorString: String(t.errorString ?? ''),
        downloadDir: String(t.downloadDir ?? ''),
      })),
    };
  } catch (err) {
    return {
      ok: false,
      message: String((err as Error)?.message || err).slice(0, 160),
      items: [],
    };
  }
}
