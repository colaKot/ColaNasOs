import fs from 'node:fs';
import path from 'node:path';
import { sql } from 'kysely';
import { secured } from '../../../kernel/route';
import { Err } from '../../../kernel/errors';
import { downloadHandler } from '../files/download';
import { BLOG_MIGRATIONS } from './migrations';
import { BLOG_SCHEMAS } from './schemas';
import {
  DEFAULT_VOICE,
  SECONDS_PER_ITEM,
  ensureSettingsRow,
  cleanVoice,
  migrateDeprecatedBlogModel,
  migrateLegacyLlmKey,
  migrateLegacyVoice,
  normalizeCounts,
  normalizeSettings,
  readSettings,
  writeSettings,
  type BlogSettings,
} from './settings';
import {
  currentEpisodeId,
  episodeAudioPath,
  getTts,
  isGenerating,
  resynthesize,
  startGeneration,
  toEpisode,
  ttsDir,
  ttsStatus,
  userVoicesDir,
  voiceFileOf,
  voicesOf,
} from './generate';
import { fetchNews } from './news';
import { resetLocalLlm, translateNews } from './translate';
import { startBlogSchedule } from './schedule';
import { resolveTtsPaths } from '../../../kernel/tts/paths';
import { MAX_VOICE_BYTES, removeUserVoice, saveUserVoice } from '../../../kernel/tts/voices';
import { ttsModel } from '../../../kernel/tts/download';
import { mtModel } from '../../../kernel/llm/download';
import type { ServerModule } from '../../../kernel/types';

const TAG = ['blog'];

/** 试听句：与产品需求里约定的那句一致，6 个音色都念同一句才好横向比较 */
const PREVIEW_TEXT = '今天天气很不错，我们一起出去野餐。';

/** 媒体令牌 12 小时：与影视 / 音乐同一个口径，长音频缓冲后 seek 不会撞 401 */
const MEDIA_TOKEN_TTL = 12 * 3600;

/**
 * blog：AI 播客 / 新闻电台。二级菜单目前只有「AI 新闻」一项，
 * 页面结构：选条数 → 选音色（可试听）→ 倍速与预计时长 → API Key → 生成计划 → 已生成列表。
 *
 *   GET  /api/v1/blog/tts/model              语音模型下载状态（每次实时探测磁盘）
 *   POST /api/v1/blog/tts/model/download     一键下载（后台跑，前端轮询进度）
 *   POST /api/v1/blog/tts/model/cancel       取消下载（已下部分会保留，下次续传）
 *   GET  /api/v1/blog/settings         读取设置（含明文 API Key、TTS 可用性、每条估算秒数）
 *   POST /api/v1/blog/settings         保存设置（部分字段）
 *   GET  /api/v1/blog/voices           参考音色清单（内置 3 段 + 用户上传）
 *   POST /api/v1/blog/voices/upload    上传参考音色（base64，自动转 24kHz 单声道）
 *   POST /api/v1/blog/voices/remove    删除自己上传的音色
 *   POST /api/v1/blog/preview          合成试听句（按音色缓存）
 *   GET  /api/v1/blog/preview/audio    试听音频（带令牌，支持 Range）
 *   POST /api/v1/blog/generate         立即生成一期（后台跑，立刻返回 id）
 *   GET  /api/v1/blog/status           生成进度（parts / doneParts）
 *   GET  /api/v1/blog/episodes         已生成列表
 *   GET  /api/v1/blog/script           某一期的播报稿 + 引用链接
 *   GET  /api/v1/blog/audio-url        带令牌的播放地址
 *   GET  /api/v1/blog/audio            播放 / 下载 mp3
 *   POST /api/v1/blog/remove           删除一期（连同音频文件）
 *   GET  /api/v1/blog/news             预览当前设置会抓到的新闻（不生成）
 */
export const blog: ServerModule = {
  id: 'blog',
  prefix: '/api/v1/blog',
  permissions: ['blog:read', 'blog:write'],

  migrations: BLOG_MIGRATIONS,

  async register(app, k) {
    for (const schema of BLOG_SCHEMAS) app.addSchema(schema);

    // 一键下载的落点：装机版 resources/ 多半只读，模型统一写到用户数据目录。
    // 这一步同时把 <dataDir>/tts 注入 paths.ts 的搜索根，status() 每次实时探测它。
    ttsModel.configure(k.paths.dataDir);
    mtModel.configure(k.paths.dataDir);

    await ensureSettingsRow(k);
    // 老库的 Key 存在 blog_settings.api_key，搬到全局 llm 配置（只搬一次）
    await migrateLegacyLlmKey(k);
    // 老库 api_model 列里也可能是下线模型名（Key 还没迁过来时 readCfg 会回落到它）
    await migrateDeprecatedBlogModel(k);
    // 换 Qwen3-TTS 后音色来自磁盘扫描，老库的 Kokoro 固定 id 会让前端下拉框崩溃
    await migrateLegacyVoice(k);

    // 上次进程退出时还在跑的那期永远不会有结果了：标成 failed，别让 UI 一直转圈。
    // 重叠模式下不能做：这会误伤正式版正在生成的那一期。
    if (k.background.enabled) {
      const cleaned = await sql`
        update blog_episodes
           set status = 'failed', error = '服务重启，生成中断', finished_at = ${Math.floor(Date.now() / 1000)}
         where status in ('pending', 'running')
      `.execute(k.db);
      k.log.info(`[blog] 启动清理中断任务：${cleaned.numAffectedRows ?? 0} 条`);
    } else {
      k.log.info('[dev] 重叠模式：跳过博客中断任务清理与定时生成');
    }

    const settingsResponse = async () => {
      const s = await readSettings(k);
      const tts = ttsStatus(k);
      return {
        ...s,
        secondsPerItem: SECONDS_PER_ITEM,
        ttsAvailable: tts.available,
        ttsReason: tts.reason ?? null,
        llmReady: Boolean(s.apiKey),
      };
    };

    // 语音模型一键下载：状态每次实时探测磁盘，不写「已下载」标记。
    // 文件齐备（用户手工放置也算）→ 永远返回 installed=true，下次进页面自然还是「已下载」。
    app.get(
      '/api/v1/blog/tts/model',
      secured('blog:read', {
        schema: {
          operationId: 'blogTtsModel',
          tags: TAG,
          summary: '语音模型下载状态（实时探测磁盘）',
          response: { 200: { $ref: 'BlogTtsModelResponse#' } },
        },
      }),
      async () => ttsModel.status(),
    );

    app.post(
      '/api/v1/blog/tts/model/download',
      secured('blog:write', {
        schema: {
          operationId: 'blogTtsModelDownload',
          tags: TAG,
          summary: '一键下载语音模型（后台执行，前端轮询进度）',
          response: { 200: { $ref: 'BlogTtsModelResponse#' } },
        },
      }),
      async () => ttsModel.start(),
    );

    app.post(
      '/api/v1/blog/tts/model/cancel',
      secured('blog:write', {
        schema: {
          operationId: 'blogTtsModelCancel',
          tags: TAG,
          summary: '取消下载（已下部分保留，下次续传）',
          response: { 200: { $ref: 'BlogTtsModelResponse#' } },
        },
      }),
      async () => ttsModel.cancel(),
    );

    // 本地翻译模型（Qwen3-1.7B GGUF，约 1.0GB）：口径与语音模型一致。
    // 多源自动切换在 tool/mt-model.js 里（ModelScope → HF 镜像 → HuggingFace），
    // 全失败才报错，前端把 error 弹出来提示用户。
    app.get(
      '/api/v1/blog/mt/model',
      secured('blog:read', {
        schema: {
          operationId: 'blogMtModel',
          tags: TAG,
          summary: '本地翻译模型下载状态（实时探测磁盘）',
          response: { 200: { $ref: 'BlogMtModelResponse#' } },
        },
      }),
      async () => mtModel.status(),
    );

    app.post(
      '/api/v1/blog/mt/model/download',
      secured('blog:write', {
        schema: {
          operationId: 'blogMtModelDownload',
          tags: TAG,
          summary: '下载本地翻译模型（后台执行，前端轮询进度）',
          response: { 200: { $ref: 'BlogMtModelResponse#' } },
        },
      }),
      async () => mtModel.start(),
    );

    app.post(
      '/api/v1/blog/mt/model/cancel',
      secured('blog:write', {
        schema: {
          operationId: 'blogMtModelCancel',
          tags: TAG,
          summary: '取消翻译模型下载（已下部分保留，下次续传）',
          response: { 200: { $ref: 'BlogMtModelResponse#' } },
        },
      }),
      async () => mtModel.cancel(),
    );

    app.get(
      '/api/v1/blog/settings',
      secured('blog:read', {
        schema: {
          operationId: 'blogSettings',
          tags: TAG,
          summary: 'AI 新闻设置',
          response: { 200: { $ref: 'BlogSettingsResponse#' } },
        },
      }),
      async () => settingsResponse(),
    );

    app.post(
      '/api/v1/blog/settings',
      secured('blog:write', {
        schema: {
          operationId: 'blogSaveSettings',
          tags: TAG,
          summary: '保存 AI 新闻设置（counts 整体提交；其余字段未传则保持不变）',
          body: { $ref: 'BlogSettingsBody#' },
          response: { 200: { $ref: 'BlogSettingsResponse#' }, 400: { $ref: 'BlogErrorResponse#' } },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as Partial<BlogSettings> & { counts?: unknown };
        const cur = await readSettings(k);
        const counts = body.counts
          ? normalizeCounts({ ...cur.counts, ...(body.counts as object) })
          : cur.counts;
        const next = normalizeSettings({ ...cur, ...body, counts });
        await writeSettings(k, next);
        if (next.voice !== cur.voice || next.speed !== cur.speed) {
          // 音色 / 倍速变了：试听缓存里旧的那份还是旧参数生成的，留着会误导
          k.log.debug?.(`[blog] 设置已更新：${next.voice} @ ${next.speed}x`);
        }
        return settingsResponse();
      },
    );

    app.get(
      '/api/v1/blog/voices',
      secured('blog:read', {
        schema: {
          operationId: 'blogVoices',
          tags: TAG,
          summary: '参考音色清单（内置 3 段 + 用户上传）',
          response: { 200: { $ref: 'BlogVoiceListResponse#' } },
        },
      }),
      async () => ({
        items: voicesOf(k).map((v) => ({
          id: v.id,
          gender: v.gender,
          builtin: v.builtin,
          label: v.label,
        })),
        defaultVoice: DEFAULT_VOICE,
      }),
    );

    app.post(
      '/api/v1/blog/voices/upload',
      secured('blog:write', {
        schema: {
          operationId: 'blogVoiceUpload',
          tags: TAG,
          summary: '上传参考音色（base64 wav/mp3，自动转 24kHz 单声道）',
          body: { $ref: 'BlogVoiceUploadBody#' },
          response: {
            200: { $ref: 'BlogVoiceUploadResponse#' },
            400: { $ref: 'BlogErrorResponse#' },
          },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as { name?: string; data?: string };
        const raw = String(body.data || '');
        if (!raw) {
          return reply.code(400).send({ error: Err.badRequest, message: 'data 不能为空' });
        }
        const buf = Buffer.from(raw.replace(/^data:[^,]*,/, ''), 'base64');
        if (buf.length === 0) {
          return reply.code(400).send({ error: Err.badRequest, message: 'base64 解不出来' });
        }
        if (buf.length > MAX_VOICE_BYTES) {
          return reply.code(400).send({
            error: Err.badRequest,
            message: `参考音太大（上限 ${Math.round(MAX_VOICE_BYTES / 1024 / 1024)}MB）`,
          });
        }
        const paths = resolveTtsPaths();
        const tmp = path.join(k.paths.dataDir, 'tts', `upload-${Date.now()}.wav`);
        fs.mkdirSync(path.dirname(tmp), { recursive: true });
        fs.writeFileSync(tmp, buf);
        try {
          const voice = await saveUserVoice(
            paths.ffmpeg || 'ffmpeg',
            userVoicesDir(k),
            String(body.name || `voice_${Date.now()}`),
            tmp,
          );
          return { ok: true, voice };
        } catch (e) {
          return reply
            .code(400)
            .send({ error: Err.badRequest, message: String((e as Error).message || e) });
        } finally {
          fs.rmSync(tmp, { force: true });
        }
      },
    );

    app.post(
      '/api/v1/blog/voices/remove',
      secured('blog:write', {
        schema: {
          operationId: 'blogVoiceRemove',
          tags: TAG,
          summary: '删除用户上传的音色（内置音色不可删）',
          body: { $ref: 'BlogVoiceRemoveBody#' },
          response: { 200: { $ref: 'BlogOkResponse#' } },
        },
      }),
      async (req) => {
        const body = (req.body || {}) as { id?: string };
        removeUserVoice(userVoicesDir(k), String(body.id || ''));
        return { ok: true };
      },
    );

    app.post(
      '/api/v1/blog/warmup',
      secured('blog:read', {
        schema: {
          operationId: 'blogWarmup',
          tags: TAG,
          summary: '预热语音模型（进页面时调用，点试听才不用等 30 秒）',
          response: { 200: { $ref: 'BlogWarmupResponse#' } },
        },
      }),
      async () => {
        const st = ttsStatus(k);
        if (!st.available) return { ready: false, available: false, reason: st.reason ?? null };
        // 没有预热标记时真正跑一句：把 Vulkan 着色器编译挪到用户点「试听」之前
        const picked = voiceFileOf(k, DEFAULT_VOICE);
        const ready = picked ? await getTts(k).warmup(picked.file) : false;
        return { ready, available: true, reason: null };
      },
    );

    app.post(
      '/api/v1/blog/preview',
      secured('blog:write', {
        schema: {
          operationId: 'blogPreview',
          tags: TAG,
          summary: '合成试听句（同一音色只合成一次，之后读缓存）',
          body: { $ref: 'BlogPreviewBody#' },
          response: { 200: { $ref: 'BlogPreviewResponse#' }, 503: { $ref: 'BlogErrorResponse#' } },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as { voice?: string };
        const settings = await readSettings(k);
        const wanted = cleanVoice(body.voice ?? settings.voice);
        const picked = voiceFileOf(k, wanted);
        if (!picked) {
          return reply.code(503).send({
            error: Err.unavailable,
            message: '没有可用的参考音色（vendor/voices 下至少要有一个 wav）',
          });
        }
        const voice = picked.voice.id;
        const dir = path.join(ttsDir(k), 'preview');
        const mp3 = path.join(dir, `${voice}.mp3`);
        const wav = path.join(dir, `${voice}.wav`);

        let cached = fs.existsSync(mp3);
        if (!cached) {
          const st = ttsStatus(k);
          if (!st.available) {
            return reply.code(503).send({
              error: Err.unavailable,
              message: `语音合成不可用：${st.reason || '缺少模型'}`,
            });
          }
          fs.mkdirSync(dir, { recursive: true });
          try {
            const res = await getTts(k).synth({
              text: PREVIEW_TEXT,
              voicePath: picked.file,
              speed: 1,
              wav,
              mp3,
              mp3Bitrate: 'q2',
            });
            cached = Boolean(res.mp3);
            if (res.mp3) fs.rmSync(wav, { force: true });
          } catch (e) {
            return reply.code(503).send({
              error: Err.unavailable,
              message: `试听合成失败：${String((e as Error).message || e).slice(0, 300)}`,
            });
          }
        }

        const token = k.auth.sign({ sub: 'blog-preview', scopes: ['blog:read'] }, MEDIA_TOKEN_TTL);
        return {
          url: `/api/v1/blog/preview/audio?voice=${encodeURIComponent(voice)}&token=${encodeURIComponent(token)}`,
          expiresInSec: MEDIA_TOKEN_TTL,
          cached,
        };
      },
    );

    app.get(
      '/api/v1/blog/preview/audio',
      secured('blog:read', {
        schema: {
          operationId: 'blogPreviewAudio',
          tags: TAG,
          summary: '试听音频（inline，支持 Range）',
          querystring: { $ref: 'BlogVoiceQuery#' },
          response: { 404: { $ref: 'BlogErrorResponse#' } },
        },
      }),
      async (req, reply) => {
        const q = (req.query || {}) as { voice?: string };
        const voice = cleanVoice(q.voice);
        if (!voicesOf(k).some((v) => v.id === voice)) {
          return reply.code(404).send({ error: Err.notFound, message: 'unknown voice' });
        }
        const dir = path.join(ttsDir(k), 'preview');
        const file = [`${voice}.mp3`, `${voice}.wav`]
          .map((name) => path.join(dir, name))
          .find((p) => fs.existsSync(p));
        if (!file) {
          return reply.code(404).send({ error: Err.notFound, message: 'preview not generated' });
        }
        return downloadHandler(req, reply, { path: file, inline: '1' });
      },
    );

    app.post(
      '/api/v1/blog/generate',
      secured('blog:write', {
        schema: {
          operationId: 'blogGenerate',
          tags: TAG,
          summary: '立即生成一期（后台执行）',
          body: { $ref: 'BlogGenerateBody#' },
          response: {
            200: { $ref: 'BlogGenerateResponse#' },
            409: { $ref: 'BlogErrorResponse#' },
            503: { $ref: 'BlogErrorResponse#' },
          },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as {
          counts?: unknown;
          voice?: string;
          speed?: number;
        };
        const s = await readSettings(k);
        const st = ttsStatus(k);
        if (!st.available) {
          return reply.code(503).send({
            error: Err.unavailable,
            message: `语音合成不可用：${st.reason || '缺少模型'}`,
          });
        }
        const counts = body.counts ? normalizeCounts({ ...s.counts, ...(body.counts as object) }) : s.counts;
        const voice = cleanVoice(body.voice ?? s.voice);
        const speed = Number(body.speed ?? s.speed);
        try {
          return await startGeneration(k, {
            counts,
            voice,
            speed: Number.isFinite(speed) ? Math.max(0.5, Math.min(speed, 2)) : s.speed,
            trigger: 'manual',
          });
        } catch (e) {
          const code = (e as Error & { code?: string }).code;
          if (code === 'E_BUSY') {
            return reply.code(409).send({ error: Err.conflict, message: (e as Error).message });
          }
          throw e;
        }
      },
    );

    app.post(
      '/api/v1/blog/resynth',
      secured('blog:write', {
        schema: {
          operationId: 'blogResynth',
          tags: TAG,
          summary: '从已有稿件重跑语音合成（不抓新闻、不调云端模型、不消耗 token）',
          body: { $ref: 'BlogResynthBody#' },
          response: {
            200: { $ref: 'BlogResynthResponse#' },
            400: { $ref: 'BlogErrorResponse#' },
            404: { $ref: 'BlogErrorResponse#' },
            409: { $ref: 'BlogErrorResponse#' },
            503: { $ref: 'BlogErrorResponse#' },
          },
        },
      }),
      async (req, reply) => {
        const id = String((req.body as { id?: string } | null)?.id ?? '').trim();
        if (!id) {
          return reply.code(400).send({ error: Err.badRequest, message: '缺少 episode id' });
        }
        const st = ttsStatus(k);
        if (!st.available) {
          return reply.code(503).send({
            error: Err.unavailable,
            message: `语音合成不可用：${st.reason || '缺少模型'}`,
          });
        }
        try {
          return await resynthesize(k, id);
        } catch (e) {
          const code = (e as Error & { code?: string }).code;
          if (code === 'E_BUSY') {
            return reply.code(409).send({ error: Err.conflict, message: (e as Error).message });
          }
          if (code === 'E_NOT_FOUND') {
            return reply.code(404).send({ error: Err.notFound, message: (e as Error).message });
          }
          if (code === 'E_NO_SCRIPT') {
            return reply.code(400).send({ error: Err.badRequest, message: (e as Error).message });
          }
          throw e;
        }
      },
    );

    app.get(
      '/api/v1/blog/status',
      secured('blog:read', {
        schema: {
          operationId: 'blogStatus',
          tags: TAG,
          summary: '生成进度',
          querystring: { $ref: 'BlogIdQuery#' },
          response: { 200: { $ref: 'BlogStatusResponse#' }, 404: { $ref: 'BlogErrorResponse#' } },
        },
      }),
      async (req, reply) => {
        const q = (req.query || {}) as { id?: string };
        const row = q.id
          ? (await sql<any>`select * from blog_episodes where id = ${q.id}`.execute(k.db)).rows[0]
          : null;
        if (!row) return reply.code(404).send({ error: Err.notFound, message: 'episode not found' });
        return {
          id: String(row.id),
          status: String(row.status),
          parts: Number(row.parts || 0),
          doneParts: Number(row.done_parts || 0),
          error: row.error ? String(row.error) : null,
          message: '',
        };
      },
    );

    app.get(
      '/api/v1/blog/episodes',
      secured('blog:read', {
        schema: {
          operationId: 'blogEpisodes',
          tags: TAG,
          summary: '已生成的节目（新的在前）',
          querystring: { $ref: 'BlogQuery#' },
          response: { 200: { $ref: 'BlogEpisodeListResponse#' } },
        },
      }),
      async (req) => {
        const q = (req.query || {}) as { limit?: number; offset?: number };
        const limit = Math.max(1, Math.min(Number(q.limit ?? 60) || 60, 200));
        const offset = Math.min(Math.max(Math.trunc(Number(q.offset ?? 0) || 0), 0), 1_000_000);
        // 以前一次吐 200 条再由前端切片（内存伪分页）；现在服务端真翻页
        const countRes = await sql<{ n: number }>`
          select count(*) as n from blog_episodes
        `.execute(k.db);
        const total = Number(countRes.rows[0]?.n) || 0;
        const rows = (
          await sql<any>`
            select * from blog_episodes
             order by created_at desc, id desc
             limit ${limit} offset ${offset}
          `.execute(k.db)
        ).rows;
        return { items: rows.map(toEpisode), total, limit, offset };
      },
    );

    app.get(
      '/api/v1/blog/script',
      secured('blog:read', {
        schema: {
          operationId: 'blogScript',
          tags: TAG,
          summary: '某一期的播报稿全文与引用链接',
          querystring: { $ref: 'BlogIdQuery#' },
          response: {
            200: { $ref: 'BlogScriptResponse#' },
            404: { $ref: 'BlogErrorResponse#' },
          },
        },
      }),
      async (req, reply) => {
        const q = (req.query || {}) as { id?: string };
        const rows = (
          await sql<any>`select * from blog_episodes where id = ${String(q.id || '')}`.execute(k.db)
        ).rows;
        const row = rows[0];
        if (!row) return reply.code(404).send({ error: Err.notFound, message: 'episode missing' });

        // select * 而不是点名 news_json：万一老库还没跑迁移，也不至于整条接口 500
        const parseJson = (raw: unknown): unknown[] => {
          try {
            const v = JSON.parse(String(raw || '[]'));
            return Array.isArray(v) ? v : [];
          } catch {
            return [];
          }
        };
        const items = parseJson(row.news_json)
          .slice(0, 60)
          .map((x: any) => ({
            category: String(x?.category || ''),
            title: String(x?.title || ''),
            link: String(x?.link || ''),
            source: String(x?.source || ''),
          }));
        // 迁移前的老期次只存了 headlines：给一组「只有标题、没有链接」的引用
        if (items.length === 0) {
          for (const h of parseJson(row.headlines_json).slice(0, 12)) {
            items.push({ category: '', title: String(h), link: '', source: '' });
          }
        }
        return {
          id: String(row.id || ''),
          title: String(row.title || ''),
          script: String(row.script || ''),
          items,
        };
      },
    );

    app.get(
      '/api/v1/blog/audio-url',
      secured('blog:read', {
        schema: {
          operationId: 'blogAudioUrl',
          tags: TAG,
          summary: '带短期令牌的播放地址',
          querystring: { $ref: 'BlogIdQuery#' },
          response: {
            200: { $ref: 'BlogAudioUrlResponse#' },
            404: { $ref: 'BlogErrorResponse#' },
          },
        },
      }),
      async (req, reply) => {
        const q = (req.query || {}) as { id?: string };
        const file = q.id ? audioFileOf(k, q.id) : null;
        if (!file) return reply.code(404).send({ error: Err.notFound, message: 'audio missing' });
        const token = k.auth.sign({ sub: 'blog-audio', scopes: ['blog:read'] }, MEDIA_TOKEN_TTL);
        return {
          url: `/api/v1/blog/audio?id=${encodeURIComponent(String(q.id))}&token=${encodeURIComponent(token)}`,
          expiresInSec: MEDIA_TOKEN_TTL,
        };
      },
    );

    app.get(
      '/api/v1/blog/audio',
      secured('blog:read', {
        schema: {
          operationId: 'blogAudio',
          tags: TAG,
          summary: '播放 / 下载（mp3，退化时给 wav；支持 Range）',
          querystring: { $ref: 'BlogIdQuery#' },
          response: { 404: { $ref: 'BlogErrorResponse#' } },
        },
      }),
      async (req, reply) => {
        const q = (req.query || {}) as { id?: string };
        const file = q.id ? audioFileOf(k, q.id) : null;
        if (!file) return reply.code(404).send({ error: Err.notFound, message: 'audio missing' });
        return downloadHandler(req, reply, { path: file, inline: '1' });
      },
    );

    app.post(
      '/api/v1/blog/remove',
      secured('blog:write', {
        schema: {
          operationId: 'blogRemove',
          tags: TAG,
          summary: '删除一期（连同音频文件）',
          body: { $ref: 'BlogRemoveBody#' },
          response: { 200: { $ref: 'BlogOkResponse#' } },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as { id?: string };
        const id = String(body.id || '');
        if (!id) return { ok: true };
        if (id === currentEpisodeId()) {
          return reply
            .code(409)
            .send({ error: Err.conflict, message: '这一期正在生成，等它结束再删' });
        }
        await sql`delete from blog_episodes where id = ${id}`.execute(k.db);
        for (const name of [`${id}.mp3`, `${id}.wav`, path.join('tmp', `${id}.wav`)]) {
          try {
            fs.rmSync(path.join(ttsDir(k), name), { force: true });
          } catch {
            // 文件已不在就算了，不要把删除按钮做成会报错的按钮
          }
        }
        return { ok: true };
      },
    );

    app.get(
      '/api/v1/blog/news',
      secured('blog:read', {
        schema: {
          operationId: 'blogNews',
          tags: TAG,
          summary: '预览当前设置会抓到的新闻（不生成音频）',
          response: { 200: { $ref: 'BlogNewsResponse#' } },
        },
      }),
      async () => {
        const s = await readSettings(k);
        const { items, failed } = await fetchNews(s.counts);
        // 模型正在跑（刚生成过）就顺手翻译；没起来不为预览单独加载 1GB
        const tr = await translateNews(k, items, (m) => k.log.info(m), { warm: false });
        return {
          items: items.map((it) => ({
            category: it.spoken,
            title: it.title,
            summary: it.summary,
            link: it.link,
            source: it.source,
            published: it.published,
          })),
          failed: tr.failed ? [...failed, `英转中失败 ${tr.failed} 条（保留原文）`] : failed,
        };
      },
    );

    if (k.background.enabled) {
      startBlogSchedule(app, k);
    }

    app.addHook('onClose', async () => {
      await resetLocalLlm();
      await getTts(k).stop();
    });

    k.log.info(`[blog] 已注册（生成中：${isGenerating() ? '是' : '否'}）`);
  },
};

/** 播放源：优先 mp3；极端情况下（缺 ffmpeg）退回 wav */
function audioFileOf(k: Parameters<typeof episodeAudioPath>[0], id: string): string | null {
  const mp3 = episodeAudioPath(k, id);
  if (fs.existsSync(mp3)) return mp3;
  const wav = path.join(ttsDir(k), `${id}.wav`);
  if (fs.existsSync(wav)) return wav;
  const tmp = path.join(ttsDir(k), 'tmp', `${id}.wav`);
  return fs.existsSync(tmp) ? tmp : null;
}
