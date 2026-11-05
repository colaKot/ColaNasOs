import { sql } from 'kysely';
import { Type } from '@sinclair/typebox';
import fs from 'node:fs';
import { secured } from '../../../../kernel/route';
import { proxyFetch } from '../../../../kernel/proxy-fetch';
import { TAG } from '../util';
import { xunleiSubtitleUrl } from '../subtitle-normal';
import type { FastifyInstance } from 'fastify';
import type { KernelApi } from '../../../../kernel/types';

/**
 * 影视设置（**服务端级**）的读写：字幕抓取 + 转码。
 *
 * 存哪：`k.config`（内核 KV，跟 `video.tmdb` 同一套），不新建表 —— 这些是低频配置，
 * 一行 JSON 比一张表更省事，也不会在迁移里反复加列。
 *
 * 为什么不拆成两个接口：设置页一次要拿全部（字幕 8 项 + 转码 2 项），
 * 两个 GET 就是两次往返；写入按 section 合并，也不会互相覆盖。
 */

const SUB_CFG = 'video.subtitle';
const TRANS_CFG = 'video.transcode';

export interface SubtitleConf {
  /** 预提取：入库时先把视频里的内嵌字幕抽出来，避免播放时才现抽 */
  preExtract: boolean;
  /** 默认字幕语言（播放器没记住上次选择时用） */
  defaultLang: string;
  /** JAV 字幕站账号（日本片专用源） */
  javUser: string;
  /** JAV 字幕站密码；明文存 config，GET 也明文回显（与 TMDB Key 一致，本机自用） */
  javPass: string;
  /** Assrt（伪射手）API Token */
  assrtToken: string;
  /** OpenSubtitles API Key */
  openSubtitlesKey: string;
  /** 迅雷字幕免配置源：作为最后兜底 */
  xunlei: boolean;
  /** 每日自动补全 */
  dailyEnable: boolean;
  /** 每日补全时间（0~23 整点） */
  dailyHour: number;
}

export interface TranscodeConf {
  /** 首选硬件解码/编码器：auto | nvenc | qsv | amf | cpu */
  hwaccel: string;
  /** 转码临时目录；空 = 用 dataDir/hls */
  tempDir: string;
}

const SUB_DEFAULTS: SubtitleConf = {
  preExtract: false,
  defaultLang: 'zh-CN',
  javUser: '',
  javPass: '',
  assrtToken: '',
  openSubtitlesKey: '',
  xunlei: true,
  dailyEnable: true,
  dailyHour: 4,
};

const TRANS_DEFAULTS: TranscodeConf = { hwaccel: 'auto', tempDir: '' };

export function subtitleConf(k: KernelApi): SubtitleConf {
  const raw = (k.config.get<Partial<SubtitleConf>>(SUB_CFG) || {}) as Partial<SubtitleConf>;
  // 明文返回：设置页要能把已配的账号 / Token 显示出来，
  // 只回「已配置」的话用户根本看不出自己配过（2026-11-03 反馈）。
  return { ...SUB_DEFAULTS, ...raw };
}

export function transcodeConf(k: KernelApi): TranscodeConf {
  const raw = (k.config.get<Partial<TranscodeConf>>(TRANS_CFG) || {}) as Partial<TranscodeConf>;
  return { ...TRANS_DEFAULTS, ...raw };
}

/** 转码目录：配置里给了就用（必须存在且可写），否则回落 dataDir/hls */
export function hlsRoot(k: KernelApi): string {
  const conf = transcodeConf(k);
  const custom = String(conf.tempDir || '').trim();
  if (custom) {
    try {
      if (fs.statSync(custom).isDirectory()) {
        fs.accessSync(custom, fs.constants.W_OK);
        return custom;
      }
    } catch {
      // 配了个不存在的目录：静默回落，不让转码整个失败
    }
  }
  return `${k.paths.dataDir}/hls`;
}

const PROBE_UA = 'Mozilla/5.0 (compatible; ColaNasOs/1.0)';

/** 字幕源连通性探测：拿到 HTTP 响应就算「可达」，超时 / DNS 失败返回 status=0 */
async function probeSource(
  url: string,
  init: RequestInit = {},
  timeoutMs = 8000,
): Promise<{ status: number; ms: number; body: string; error?: string }> {
  const t0 = Date.now();
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), timeoutMs);
  try {
    const res = await proxyFetch(url, {
      ...init,
      signal: ctrl.signal,
      headers: {
        'user-agent': PROBE_UA,
        ...(init.headers as Record<string, string> | undefined),
      },
    });
    const body = await res.text().catch(() => '');
    return { status: res.status, ms: Date.now() - t0, body };
  } catch (e) {
    return { status: 0, ms: Date.now() - t0, body: '', error: String((e as Error)?.message || e) };
  } finally {
    clearTimeout(timer);
  }
}

const TestSourcesBody = Type.Object({
  assrtToken: Type.Optional(Type.String({ maxLength: 200 })),
  openSubtitlesKey: Type.Optional(Type.String({ maxLength: 200 })),
});

const TestSourceItem = Type.Object({
  id: Type.String({ description: 'jav / assrt / openSub / xunlei' }),
  ok: Type.Boolean(),
  status: Type.Integer(),
  latencyMs: Type.Integer(),
  message: Type.String(),
});

const SubtitleFields = {
  preExtract: Type.Optional(Type.Boolean()),
  defaultLang: Type.Optional(Type.String({ maxLength: 20 })),
  javUser: Type.Optional(Type.String({ maxLength: 100 })),
  javPass: Type.Optional(Type.String({ maxLength: 200, description: '空字符串 = 不修改' })),
  assrtToken: Type.Optional(Type.String({ maxLength: 200 })),
  openSubtitlesKey: Type.Optional(Type.String({ maxLength: 200 })),
  xunlei: Type.Optional(Type.Boolean()),
  dailyEnable: Type.Optional(Type.Boolean()),
  dailyHour: Type.Optional(Type.Integer({ minimum: 0, maximum: 23 })),
};

const TranscodeFields = {
  hwaccel: Type.Optional(
    Type.String({ description: 'auto / nvenc / qsv / amf / cpu' }),
  ),
  tempDir: Type.Optional(Type.String({ maxLength: 400, description: '空 = 用默认缓存目录' })),
};

export async function registerVideoSettings(
  app: FastifyInstance,
  k: KernelApi,
): Promise<void> {
  app.get(
    '/api/v1/video/settings',
    secured('video:read', {
      schema: {
        operationId: 'videoSettingsGet',
        tags: TAG,
        summary: '影视设置（字幕抓取 + 转码）',
        response: {
          200: Type.Object({
            subtitle: Type.Object({
              preExtract: Type.Boolean(),
              defaultLang: Type.String(),
              javUser: Type.String(),
              /** 明文回显（本机自用）：用户要能看见自己配了什么 */
              javPass: Type.String(),
              javConfigured: Type.Boolean({ description: '密码是否已存（同 javPass 非空）' }),
              assrtToken: Type.String({ description: 'Assrt Token，明文回显' }),
              assrtConfigured: Type.Boolean(),
              openSubtitlesKey: Type.String({ description: 'OpenSubtitles Key，明文回显' }),
              openSubtitlesConfigured: Type.Boolean(),
              xunlei: Type.Boolean(),
              dailyEnable: Type.Boolean(),
              dailyHour: Type.Integer(),
            }),
            transcode: Type.Object({
              hwaccel: Type.String(),
              tempDir: Type.String(),
              effectiveTempDir: Type.String({ description: '实际生效目录（配置无效时回落）' }),
            }),
          }),
        },
      },
    }),
    async () => {
      const s = subtitleConf(k);
      const t = transcodeConf(k);
      return {
        subtitle: {
          preExtract: s.preExtract,
          defaultLang: s.defaultLang,
          javUser: s.javUser,
          javPass: s.javPass,
          javConfigured: Boolean(s.javPass),
          assrtToken: s.assrtToken,
          assrtConfigured: Boolean(s.assrtToken),
          openSubtitlesKey: s.openSubtitlesKey,
          openSubtitlesConfigured: Boolean(s.openSubtitlesKey),
          xunlei: s.xunlei,
          dailyEnable: s.dailyEnable,
          dailyHour: s.dailyHour,
        },
        transcode: { ...t, effectiveTempDir: hlsRoot(k) },
      };
    },
  );

  app.put(
    '/api/v1/video/settings',
    secured('video:write', {
      schema: {
        operationId: 'videoSettingsSet',
        tags: TAG,
        summary: '写影视设置（只传要改的段 / 字段）',
        body: Type.Object({
          subtitle: Type.Optional(Type.Object(SubtitleFields)),
          transcode: Type.Optional(Type.Object(TranscodeFields)),
        }),
        response: { 200: Type.Object({ ok: Type.Boolean() }) },
      },
    }),
    async (req) => {
      const body = (req.body || {}) as {
        subtitle?: Partial<SubtitleConf>;
        transcode?: Partial<TranscodeConf>;
      };
      if (body.subtitle) {
        const cur = (k.config.get<Partial<SubtitleConf>>(SUB_CFG) || {}) as Partial<SubtitleConf>;
        const next: Partial<SubtitleConf> = { ...cur };
        const b = body.subtitle;
        if (b.preExtract !== undefined) next.preExtract = b.preExtract === true;
        if (b.defaultLang !== undefined) next.defaultLang = String(b.defaultLang).trim() || 'zh-CN';
        if (b.javUser !== undefined) next.javUser = String(b.javUser).trim();
        // 空字符串 = 不修改（前端把明文回显原样传回来，空值只可能是用户手动清空后没重填）
        if (b.javPass !== undefined && String(b.javPass).length > 0) {
          next.javPass = String(b.javPass);
        }
        if (b.assrtToken !== undefined) next.assrtToken = String(b.assrtToken).trim();
        if (b.openSubtitlesKey !== undefined) {
          next.openSubtitlesKey = String(b.openSubtitlesKey).trim();
        }
        if (b.xunlei !== undefined) next.xunlei = b.xunlei === true;
        if (b.dailyEnable !== undefined) next.dailyEnable = b.dailyEnable === true;
        if (b.dailyHour !== undefined) {
          const h = Number(b.dailyHour);
          if (Number.isFinite(h) && h >= 0 && h <= 23) next.dailyHour = Math.floor(h);
        }
        await k.config.set(SUB_CFG, next);
      }
      if (body.transcode) {
        const cur = (k.config.get<Partial<TranscodeConf>>(TRANS_CFG) || {}) as Partial<TranscodeConf>;
        const next: Partial<TranscodeConf> = { ...cur };
        const b = body.transcode;
        if (b.hwaccel !== undefined) {
          const v = String(b.hwaccel).trim();
          next.hwaccel = ['auto', 'nvenc', 'qsv', 'amf', 'cpu'].includes(v) ? v : 'auto';
        }
        if (b.tempDir !== undefined) next.tempDir = String(b.tempDir).trim();
        await k.config.set(TRANS_CFG, next);
      }
      return { ok: true };
    },
  );

  // 字幕源连通性自检：把 JAV / Assrt / OpenSubtitles / 迅雷 都打一遍，结果逐条返回。
  // 只探测「链接是否通」，不做真实搜索下载；凭据从输入框传进来（没保存也能测）。
  app.post(
    '/api/v1/video/subtitle/test-sources',
    secured('video:write', {
      schema: {
        operationId: 'videoSubtitleSourcesTest',
        tags: TAG,
        summary: '测试各字幕源链接（连通性，不下载）',
        body: TestSourcesBody,
        response: {
          200: Type.Object({ sources: Type.Array(TestSourceItem) }),
        },
      },
    }),
    async (req) => {
      const body = (req.body || {}) as { assrtToken?: string; openSubtitlesKey?: string };
      const saved = subtitleConf(k);
      const assrtToken = String(body.assrtToken ?? saved.assrtToken ?? '').trim();
      const openSubKey = String(body.openSubtitlesKey ?? saved.openSubtitlesKey ?? '').trim();

      const sources: Array<{
        id: string;
        ok: boolean;
        status: number;
        latencyMs: number;
        message: string;
      }> = [];

      // ① JAV 字幕站（avsubtitles，免登录）
      {
        const r = await probeSource('https://avsubtitles.com/');
        sources.push({
          id: 'jav',
          ok: r.status > 0 && r.status < 400,
          status: r.status,
          latencyMs: r.ms,
          message: r.error ? r.error : r.status > 0 && r.status < 400 ? '站点可访问' : `HTTP ${r.status}`,
        });
      }

      // ② Assrt（伪射手）：接口要 Token；没有 Token 时只测域名连通性
      {
        const q = 'test';
        const url =
          `https://api.assrt.net/v1/sub/search?q=${encodeURIComponent(q)}&cnt=1` +
          (assrtToken ? `&token=${encodeURIComponent(assrtToken)}` : '');
        const r = await probeSource(url, { headers: { accept: 'application/json' } });
        let ok = r.status > 0 && r.status < 500;
        let message = r.error ? r.error : assrtToken ? `HTTP ${r.status}` : '站点可访问（未配置 Token）';
        if (ok && assrtToken && r.status === 200) {
          try {
            const json = JSON.parse(r.body) as { sub?: { subs?: unknown } };
            if (Array.isArray(json?.sub?.subs)) message = 'API 正常';
            else ok = false;
            message = ok ? message : 'API 返回异常';
          } catch {
            ok = false;
            message = 'API 返回非 JSON';
          }
        }
        sources.push({ id: 'assrt', ok, status: r.status, latencyMs: r.ms, message });
      }

      // ③ OpenSubtitles：没有 API Key 会返回 401/403，仍算「站点可达」
      {
        const url =
          'https://api.opensubtitles.com/api/v1/subtitles?query=test&languages=zh-cn&order_by=download_count&order_direction=desc';
        const r = await probeSource(url, {
          headers: {
            accept: 'application/json',
            ...(openSubKey ? { 'api-key': openSubKey } : {}),
          },
        });
        let ok = r.status > 0 && r.status < 500;
        let message = r.error
          ? r.error
          : openSubKey
            ? `HTTP ${r.status}`
            : '站点可访问（未配置 API Key）';
        if (ok && openSubKey && r.status === 200) {
          try {
            const json = JSON.parse(r.body) as { data?: unknown };
            if (Array.isArray(json?.data)) message = 'API 正常';
            else {
              ok = false;
              message = 'API 返回异常';
            }
          } catch {
            ok = false;
            message = 'API 返回非 JSON';
          }
        }
        sources.push({ id: 'openSub', ok, status: r.status, latencyMs: r.ms, message });
      }

      // ④ 迅雷字幕（免配置兜底）
      {
        const r = await probeSource(
          xunleiSubtitleUrl('test'),
          { headers: { accept: 'application/json' } },
        );
        let ok = r.status > 0 && r.status < 500;
        let message = r.error ? r.error : `HTTP ${r.status}`;
        if (ok && r.status === 200) {
          try {
            const json = JSON.parse(r.body) as { data?: unknown };
            if (Array.isArray(json?.data)) message = '接口正常';
            else {
              ok = false;
              message = '接口返回异常';
            }
          } catch {
            ok = false;
            message = '接口返回非 JSON';
          }
        }
        sources.push({ id: 'xunlei', ok, status: r.status, latencyMs: r.ms, message });
      }

      return { sources };
    },
  );

  // 每日自动补全：每小时看一次，只在「配置的整点」且当天还没跑过时入队。
  // 用 config 记 lastRunDay，避免重启后重复触发。
  const timer = setInterval(() => {
    void (async () => {
      try {
        const s = subtitleConf(k);
        const now = new Date();
        // 每日刮削进度统计（2026-11-04）：只读本地库、几十毫秒，
        // 跟字幕开关无关（关了自动补字幕也该知道还差多少要刮）。
        // 单独记 lastRunDay，一天只跑一次，重启不会重跑。
        if (now.getHours() === s.dailyHour) {
          const statsDay = now.toISOString().slice(0, 10);
          if (k.config.get<string>('video.stats.lastRunDay') !== statsDay) {
            await k.config.set('video.stats.lastRunDay', statsDay);
            await k.tasks
              .enqueueIfIdle('video.scrape.progress', {}, { maxAttempts: 1 })
              .catch(() => null);
          }
        }
        if (!s.dailyEnable) return;
        if (now.getHours() !== s.dailyHour) return;
        const day = now.toISOString().slice(0, 10);
        const last = k.config.get<string>('video.subtitle.lastRunDay');
        if (last === day) return;
        await k.config.set('video.subtitle.lastRunDay', day);
        const libs = (
          await sql<{ id: string }>`
            select id from video_libraries where auto_subtitle = 1
          `.execute(k.db)
        ).rows;
        for (const lib of libs) {
          await k.tasks
            .enqueueIfIdle('video.subtitle.fetch', { libraryId: lib.id }, { maxAttempts: 2 })
            .catch(() => null);
        }
        k.log.info({ libs: libs.length, day }, 'video.subtitle daily fetch enqueued');
      } catch (err) {
        k.log.warn({ err: String(err) }, 'video.subtitle daily scheduler failed');
      }
    })();
  }, 3600_000);
  timer.unref?.();
  app.addHook('onClose', async () => clearInterval(timer));
}
