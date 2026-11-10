import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { sql } from 'kysely';
import type { KernelApi } from '../../../kernel/types';
import { TtsEngine } from '../../../kernel/tts/engine';
import { resolveTtsPaths } from '../../../kernel/tts/paths';
import { defaultVoiceId, listVoices, resolveVoice, type TtsVoice } from '../../../kernel/tts/voices';
import { llmApiKey, readSystemSettings } from '../../../kernel/system-settings';
import { cleanVoice, DEFAULT_VOICE } from './settings';
import { fetchNews, type NewsItem } from './news';
import { composeScript, todayLabel } from './script';
import { translateNews } from './translate';
import { CATEGORIES } from './news';
import type { BlogCounts } from './settings';

/**
 * 生成一期节目：抓新闻 → 写稿 → 本地 TTS → 落 mp3。
 *
 * 为什么是"后台跑 + 落库进度"而不是同步请求：
 * 10 条新闻 ≈ 10 分钟音频，本地合成是 1.2~1.5 倍实时，也就是 7~9 分钟。
 * HTTP 请求扛不住，所以接口立刻返回 episode id，前端轮询 `status`；
 * 进度写在 `parts / done_parts` 上，进程重启后至少能看到「停在 7/12」而不是永远 pending。
 *
 * 同一时间只允许一期在跑：合成是 GPU 串行的，排三期只会让用户以为卡死。
 */

let engine: TtsEngine | null = null;
let current: string | null = null;
let dbRef: any = null;

export function ttsDir(k: KernelApi): string {
  return path.join(k.paths.dataDir, 'blog');
}

/** 用户上传的参考音色目录（`<data>/tts/voices`） */
export function userVoicesDir(k: KernelApi): string {
  return path.join(k.paths.dataDir, 'tts', 'voices');
}

export function episodeAudioPath(k: KernelApi, id: string): string {
  return path.join(ttsDir(k), `${id}.mp3`);
}

function tmpWavPath(k: KernelApi, id: string): string {
  return path.join(ttsDir(k), 'tmp', `${id}.wav`);
}

export function isGenerating(): boolean {
  return current !== null;
}

export function currentEpisodeId(): string | null {
  return current;
}

/** 当前可用的音色（内置 + 用户上传） */
export function voicesOf(k: KernelApi): TtsVoice[] {
  const p = resolveTtsPaths();
  return listVoices(p.voicesDir, userVoicesDir(k));
}

/** 把设置里的音色 id 解析成磁盘上的参考音；找不到就退回默认音色 */
export function voiceFileOf(k: KernelApi, id: string): { voice: TtsVoice; file: string } | null {
  const p = resolveTtsPaths();
  const hit = resolveVoice(p.voicesDir, userVoicesDir(k), id || DEFAULT_VOICE);
  if (hit) return hit;
  return resolveVoice(p.voicesDir, userVoicesDir(k), defaultVoiceId());
}

/** 模块级单例：路径只在第一次解析，引擎本身无状态（每个进程都是新起的 llama-tts） */
export function getTts(k: KernelApi): TtsEngine {
  if (!engine) {
    dbRef = k.db;
    const p = resolveTtsPaths();
    const log = (level: 'debug' | 'info' | 'warn' | 'error', message: string) => {
      const fn = (k.log as Record<string, (m: string) => void>)[level];
      if (typeof fn === 'function') fn.call(k.log, message);
    };
    engine = new TtsEngine({
      binPath: p.bin || '',
      modelPath: p.model || '',
      mmprojPath: p.mmproj || '',
      ffmpeg: p.ffmpeg || 'ffmpeg',
      workDir: path.join(path.join(k.paths.dataDir, 'tts'), 'tmp'),
      cacheDir: path.join(k.paths.dataDir, 'tts'),
      log,
    });
  }
  // 每次取用都重新解析一次路径：一键下载可能在进程启动之后才把模型放到
  // <dataDir>/tts，单例引擎必须跟上，否则「下完还要重启服务」。
  engine?.refreshPaths();
  return engine;
}

/** 可用性 + 人话原因（前端直接显示「缺少什么、该跑哪条命令」） */
export function ttsStatus(k: KernelApi): { available: boolean; reason?: string } {
  const st = getTts(k).status();
  if (st.available) return st;
  return { available: false, reason: st.reason };
}

function newId(): string {
  return crypto.randomBytes(9).toString('base64url');
}

export interface GenerateParams {
  counts: BlogCounts;
  voice: string;
  speed: number;
  trigger: 'manual' | 'schedule';
}

export interface StartResult {
  id: string;
  status: string;
}

/** 起一期生成（立刻返回）。已有任务在跑时抛 `E_BUSY`。 */
export async function startGeneration(
  k: KernelApi,
  params: GenerateParams,
): Promise<StartResult> {
  if (current) {
    const err = new Error('已有一期正在生成，请等它结束');
    (err as Error & { code?: string }).code = 'E_BUSY';
    throw err;
  }

  const id = newId();
  const now = Math.floor(Date.now() / 1000);
  await sql`
    insert into blog_episodes
      (id, title, voice, speed, duration_sec, size_bytes, item_count, parts, done_parts,
       status, error, script, sections_json, headlines_json, created_at, finished_at)
    values (${id}, ${`${todayLabel()} AI 新闻`}, ${params.voice}, ${params.speed}, 0, 0, 0, 0, 0,
            'pending', null, '', '[]', '[]', ${now}, null)
  `.execute(k.db);

  current = id;
  // 不 await：接口要立刻返回，前端靠轮询看进度
  void run(k, id, params).finally(() => {
    if (current === id) current = null;
  });
  return { id, status: 'pending' };
}

async function setStatus(
  k: KernelApi,
  id: string,
  patch: Record<string, unknown>,
): Promise<void> {
  const entries = Object.entries(patch);
  if (entries.length === 0) return;
  await sql`
    update blog_episodes set ${sql.join(
      entries.map(([key, value]) => sql`${sql.ref(key)} = ${value as never}`),
      sql`, `,
    )} where id = ${id}
  `.execute(k.db);
}

async function run(k: KernelApi, id: string, params: GenerateParams): Promise<void> {
  try {
    await setStatus(k, id, { status: 'running' });

    // 模型配置来自系统设置（与设置页同一份），决定抓 1 倍还是 2 倍素材
    const cfg = await readCfg(k);
    const useLlm = Boolean(cfg.apiKey) && cfg.llmEnabled;
    // 有模型就多抓一倍素材让它筛，没有就按条数抓（拼接稿用不上备选）
    const { items, failed } = await fetchNews(
      params.counts,
      (m) => k.log.info(m),
      useLlm ? 3 : 1,
    );
    if (items.length === 0 && !(useLlm && cfg.webSearch)) {
      throw new Error(
        `一条新闻都没抓到：${failed.slice(0, 3).join('；') || '检查网络 / 代理设置'}`,
      );
    }
    if (items.length === 0) {
      k.log.warn('[blog] RSS 素材为空，改为让模型联网检索（enable_search）');
    }
    if (failed.length) k.log.warn(`[blog] 部分源不可用：${failed.slice(0, 5).join('；')}`);

    // 英文源先在本地译成中文：云端模型只管改写，不用又翻又写又压字数；
    // 顺带保证「没有 Key 时的兜底拼接稿」不是英文原文（04:00 那期就是栽在这）
    const tr = await translateNews(k, items, (m) => k.log.info(m));
    if (tr.failed > 0) k.log.warn(`[blog] 英转中失败 ${tr.failed} 条，这 ${tr.failed} 条保留原文`);

    const settings = {
      voice: params.voice,
      speed: params.speed,
      counts: params.counts,
      planHour: 0,
      planMinute: 0,
      planEnabled: true,
      apiProvider: 'deepseek',
      apiKey: '',
      apiBase: '',
      apiModel: '',
      llmEnabled: false,
      webSearch: false,
      lastPlanDate: null,
    };
    const merged = { ...settings, ...cfg, voice: params.voice, speed: params.speed };
    const script = await composeScript(items, params.counts, merged, (m) => k.log.info(m));
    const text = script.text;
    // 用量落库：出账后按 episode_id 就能查到这一期烧了多少 token、几次调用
    const u = script.stats.usage;
    if (u?.calls) {
      await sql`
        insert or replace into blog_llm_usage
          (episode_id, model, calls, prompt_tokens, completion_tokens, total_tokens,
           search_calls, compat_retries, created_at)
        values (${id}, ${String(merged.apiModel || '')}, ${u.calls}, ${u.promptTokens},
                ${u.completionTokens}, ${u.promptTokens + u.completionTokens},
                ${u.searchCalls}, ${u.compatRetries}, ${Math.floor(Date.now() / 1000)})
      `
        .execute(k.db)
        .catch(() => undefined);
    }
    if (script.warnings.length) {
      k.log.warn(`[blog] 稿件提示：${script.warnings.slice(0, 5).join('；')}`);
    }

    const sections = [...new Set(items.map((it) => it.spoken))];
    const headlines = items.slice(0, 12).map((it) => it.title);
    // 本期素材清单：文稿弹窗底部要列「引用链接」，所以连原文 URL 一起落库。
    // 按 link 去重（同一条新闻常出现在多个源），最多 60 条，避免把 blob 撑大。
    const seen = new Set<string>();
    const news = items
      .filter((it) => {
        const link = String(it.link || '').trim();
        if (!link || seen.has(link)) return false;
        seen.add(link);
        return true;
      })
      .slice(0, 60)
      .map((it) => ({
        category: String(it.spoken || ''),
        title: String(it.title || '').slice(0, 200),
        link: String(it.link || '').slice(0, 500),
        source: String(it.source || '').slice(0, 60),
      }));
    // 先把清单与稿件落库：合成失败也能看见「这期本来要播什么」
    await setStatus(k, id, {
      script: text,
      item_count: script.usedLlm ? script.stats.total : items.length,
      sections_json: JSON.stringify(sections),
      headlines_json: JSON.stringify(headlines),
      news_json: JSON.stringify(news),
    });

    // 稿件已落库，剩下的纯音频合成独立成函数：接口可从已有稿件直接重跑，
    // 不必再抓 RSS / 本地翻译 / 云端改写（不花 token）。
    await synthesizeEpisode(k, id, text, params.voice, params.speed);
  } catch (e) {
    const message = String((e as Error)?.message || e).slice(0, 500);
    k.log.error(`[blog] 生成失败：${message}`);
    await setStatus(k, id, {
      status: 'failed',
      error: message,
      finished_at: Math.floor(Date.now() / 1000),
    }).catch(() => undefined);
  }
}

/**
 * 只做音频合成：稿件、音色、语速都来自已落库的这一期。
 * 抓取 / 翻译 / 云端改写一概不碰，所以重合成不消耗任何云端 token。
 */
export async function synthesizeEpisode(
  k: KernelApi,
  id: string,
  text: string,
  voice: string,
  speed: number,
): Promise<void> {
  const mp3 = episodeAudioPath(k, id);
  const wav = tmpWavPath(k, id);
  fs.mkdirSync(path.dirname(wav), { recursive: true });
  fs.mkdirSync(path.dirname(mp3), { recursive: true });

  const tts = getTts(k);
  const st = tts.status();
  if (!st.available) {
    throw new Error(`语音合成不可用：${st.reason || '缺少模型'}`);
  }
  const picked = voiceFileOf(k, voice);
  if (!picked) {
    throw new Error('没有可用的参考音色（vendor/voices 下至少要有一个 wav）');
  }
  if (picked.voice.id !== voice) {
    k.log.warn(`[blog] 音色 ${voice} 不存在，退回 ${picked.voice.id}`);
  }

  const result = await tts.synth({
    text,
    voicePath: picked.file,
    speed,
    wav,
    mp3,
    mp3Bitrate: 'q2',
    onProgress: (done, total) => {
      // 每块写完更新一次进度：一次 update 是毫秒级，不拖慢合成
      if (!dbRef) return;
      void sql`
        update blog_episodes set done_parts = ${done}, parts = ${total} where id = ${id}
      `
        .execute(dbRef)
        .catch(() => undefined);
    },
  });

  const finalBytes = result.mp3 ? result.mp3Bytes : result.wavBytes;
  if (!result.mp3) {
    k.log.warn('[blog] mp3 转码失败，保留 wav（缺 ffmpeg？npm run ffmpeg:fetch）');
  }
  // 自检：TTS 被截断时不报错、退出码也是 0，唯一痕迹是「念得太快」
  // （正常 ≈4.5 汉字/秒 @speed=1）。真出现就说明某块顶到了 -n 上限还没被兜底切开。
  const charsPerSec = result.durationSec > 0 ? (result.han / result.durationSec) * speed : 0;
  if (charsPerSec > 6) {
    k.log.warn(
      `[blog] 第 ${id} 期语速异常：${charsPerSec.toFixed(1)} 汉字/秒（正常约 4.5），可能有分块被 TTS 截断`,
    );
  }
  await setStatus(k, id, {
    status: 'done',
    duration_sec: result.durationSec,
    size_bytes: finalBytes,
    parts: result.parts,
    done_parts: result.parts,
    finished_at: Math.floor(Date.now() / 1000),
  });

  // wav 是中间产物，mp3 已经转好就删掉（一期 10 分钟 ≈ 28MB）
  try {
    if (result.mp3) fs.rmSync(wav, { force: true });
  } catch {
    // 删不掉就留着，不影响播放
  }
  k.log.info(`[blog] 第 ${id} 期完成：${result.durationSec.toFixed(1)}s / ${finalBytes} bytes`);
}

/** 从已有稿件重跑 TTS（后台执行，立刻返回）。已有任务在跑时抛 E_BUSY。 */
export async function resynthesize(k: KernelApi, id: string): Promise<StartResult> {
  if (current) {
    const busy = new Error('已有一期正在生成，请等它结束');
    (busy as Error & { code?: string }).code = 'E_BUSY';
    throw busy;
  }
  const row = (
    await sql<{ script: string; voice: string; speed: number }>`
      select script, voice, speed from blog_episodes where id = ${id}
    `.execute(k.db)
  ).rows[0];
  if (!row) {
    const err = new Error('找不到这一期节目');
    (err as Error & { code?: string }).code = 'E_NOT_FOUND';
    throw err;
  }
  const text = String(row.script || '');
  if (!text.trim()) {
    const err = new Error('这一期还没有稿件，无法重合成（请重新生成一期）');
    (err as Error & { code?: string }).code = 'E_NO_SCRIPT';
    throw err;
  }
  const voice = cleanVoice(row.voice);
  const speed = Number(row.speed) || 1;

  current = id;
  dbRef = k.db;
  await setStatus(k, id, {
    status: 'running',
    error: null,
    finished_at: null,
    done_parts: 0,
    size_bytes: 0,
    duration_sec: 0,
  });
  void synthesizeEpisode(k, id, text, voice, speed)
    .catch(async (e) => {
      const message = String((e as Error)?.message || e).slice(0, 500);
      k.log.error(`[blog] 重合成失败：${message}`);
      await setStatus(k, id, {
        status: 'failed',
        error: message,
        finished_at: Math.floor(Date.now() / 1000),
      }).catch(() => undefined);
    })
    .finally(() => {
      if (current === id) current = null;
    });
  return { id, status: 'pending' };
}

/** 只取生成需要的字段；避免为了一个 key 把整个 settings 结构拖进来 */
async function readCfg(k: KernelApi) {
  // 真源：系统设置里的 llm（设置页与博客页共用）。老库还没迁移时才回落到 api_* 列。
  const llm = readSystemSettings(k.config).llm;
  if (llm.apiKey) {
    return {
      apiKey: llmApiKey(llm),
      apiBase: llm.baseUrl,
      apiModel: llm.model,
      apiProvider: llm.provider,
      llmEnabled: llm.enabled,
      webSearch: llm.webSearch,
    };
  }
  const row = (
    await sql<any>`select * from blog_settings where id = 1`.execute(k.db)
  ).rows[0];
  return {
    apiKey: String(row?.api_key || ''),
    apiBase: String(row?.api_base || llm.baseUrl || 'https://api.deepseek.com'),
    apiModel: String(row?.api_model || llm.model || 'deepseek-flash'),
    apiProvider: String(row?.api_provider || llm.provider || 'deepseek'),
    llmEnabled: llm.enabled,
    webSearch: llm.webSearch,
  };
}

/** 给路由用：把一行 episode 转成契约形状 */
export function toEpisode(r: any) {
  const parse = (s: string): string[] => {
    try {
      const v = JSON.parse(s || '[]');
      return Array.isArray(v) ? v.map(String) : [];
    } catch {
      return [];
    }
  };
  return {
    id: String(r.id),
    title: String(r.title || ''),
    voice: String(r.voice || ''),
    speed: Number(r.speed || 1),
    durationSec: Number(r.duration_sec || 0),
    sizeBytes: Number(r.size_bytes || 0),
    itemCount: Number(r.item_count || 0),
    status: String(r.status || 'pending'),
    error: r.error ? String(r.error) : null,
    parts: Number(r.parts || 0),
    doneParts: Number(r.done_parts || 0),
    sections: parse(r.sections_json),
    headlines: parse(r.headlines_json),
    createdAt: Number(r.created_at || 0),
    finishedAt: r.finished_at === null || r.finished_at === undefined ? null : Number(r.finished_at),
  };
}

export type { NewsItem };
export { CATEGORIES };
