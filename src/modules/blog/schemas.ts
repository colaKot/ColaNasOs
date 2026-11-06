import { Type } from '@sinclair/typebox';

/**
 * blog 模块路由契约（唯一真源：运行时校验 + OpenAPI + Dart 客户端）。
 *
 * 「新闻条数」用 8 个具名字段而不是 `Record<string, number>`：
 * 后者在 OpenAPI 里是 additionalProperties，生成出来的 Dart 只能拿到 `Map<String,dynamic>`，
 * 前端每取一次都要判空。类别固定 8 类，显式写死更省事，也与 UI 的顺序一致。
 */
export const BlogCounts = Type.Object(
  {
    domesticGeneral: Type.Integer({ minimum: 0, maximum: 10, description: '国内综合' }),
    worldGeneral: Type.Integer({ minimum: 0, maximum: 10, description: '国际综合' }),
    domesticTech: Type.Integer({ minimum: 0, maximum: 10, description: '国内科技' }),
    worldTech: Type.Integer({ minimum: 0, maximum: 10, description: '国外科技' }),
    domesticAi: Type.Integer({ minimum: 0, maximum: 10, description: '国内 AI' }),
    worldAi: Type.Integer({ minimum: 0, maximum: 10, description: '国际 AI' }),
    domesticFinance: Type.Integer({ minimum: 0, maximum: 10, description: '国内财经' }),
    worldFinance: Type.Integer({ minimum: 0, maximum: 10, description: '国外财经' }),
  },
  { $id: 'BlogCounts' },
);

export const BlogSettingsResponse = Type.Object(
  {
    voice: Type.String({ description: '参考音色 id（内置 default/warm/deep 或用户上传）' }),
    speed: Type.Number({ minimum: 0.5, maximum: 2, description: '朗读倍速，1 = 原速' }),
    counts: Type.Ref(BlogCounts),
    planHour: Type.Integer({ minimum: 0, maximum: 23 }),
    planMinute: Type.Integer({ minimum: 0, maximum: 59 }),
    planEnabled: Type.Boolean({ description: '是否启用每日定时生成' }),
    apiProvider: Type.String({ description: 'deepseek / openai / 自定义（仅展示）' }),
    apiKey: Type.String({ description: '明文（用户要求可复制、可查看）' }),
    apiBase: Type.String({ description: 'OpenAI 兼容 base，如 https://api.deepseek.com' }),
    apiModel: Type.String(),
    llmEnabled: Type.Boolean({ description: '大模型改写开关（与系统设置共用同一份配置）' }),
    webSearch: Type.Boolean({ description: '联网搜索（阿里百炼搜索插件）' }),
    llmReady: Type.Boolean({ description: '是否已配好 Key（没配就只用素材拼接）' }),
    /** 1 倍速下每条新闻的估算秒数（前端算预计总时长用；实测稿面 1 分半左右） */
    secondsPerItem: Type.Integer(),
    lastPlanDate: Type.Union([Type.String(), Type.Null()]),
    ttsAvailable: Type.Boolean({ description: '本机语音合成是否可用（二进制 + 模型齐备）' }),
    ttsReason: Type.Union([Type.String(), Type.Null()], {
      description: '不可用时的原因（缺什么、该跑哪条命令）',
    }),
  },
  { $id: 'BlogSettingsResponse' },
);

export const BlogSettingsBody = Type.Object(
  {
    voice: Type.Optional(Type.String({ minLength: 1, maxLength: 40 })),
    speed: Type.Optional(Type.Number({ minimum: 0.5, maximum: 2 })),
    counts: Type.Optional(
      Type.Ref(BlogCounts, { description: '八个类别整体替换（与页面提交方式一致）' }),
    ),
    planHour: Type.Optional(Type.Integer({ minimum: 0, maximum: 23 })),
    planMinute: Type.Optional(Type.Integer({ minimum: 0, maximum: 59 })),
    planEnabled: Type.Optional(Type.Boolean()),
    apiProvider: Type.Optional(Type.String({ maxLength: 40 })),
    apiKey: Type.Optional(Type.String({ maxLength: 400 })),
    apiBase: Type.Optional(Type.String({ maxLength: 300 })),
    apiModel: Type.Optional(Type.String({ maxLength: 120 })),
    llmEnabled: Type.Optional(Type.Boolean()),
    webSearch: Type.Optional(Type.Boolean()),
  },
  { $id: 'BlogSettingsBody' },
);

export const BlogVoiceItem = Type.Object(
  {
    id: Type.String(),
    gender: Type.String({ description: 'female / male / unknown' }),
    /** 内置音色随仓库分发，用户上传的可以删除 */
    builtin: Type.Boolean(),
    /** 内置音色留空（前端按 i18n 显示），用户上传的直接是文件名 */
    label: Type.String(),
  },
  { $id: 'BlogVoiceItem' },
);

export const BlogVoiceUploadBody = Type.Object(
  {
    name: Type.String({ minLength: 1, maxLength: 40, description: '音色名（做文件名）' }),
    data: Type.String({ description: 'base64（可带 data:audio/wav;base64, 前缀）' }),
  },
  { $id: 'BlogVoiceUploadBody' },
);

export const BlogVoiceUploadResponse = Type.Object(
  { ok: Type.Boolean(), voice: Type.Ref(BlogVoiceItem) },
  { $id: 'BlogVoiceUploadResponse' },
);

export const BlogVoiceRemoveBody = Type.Object(
  { id: Type.String({ minLength: 1 }) },
  { $id: 'BlogVoiceRemoveBody' },
);

export const BlogVoiceListResponse = Type.Object(
  {
    items: Type.Array(Type.Ref(BlogVoiceItem)),
    defaultVoice: Type.String(),
  },
  { $id: 'BlogVoiceListResponse' },
);

export const BlogEpisodeItem = Type.Object(
  {
    id: Type.String(),
    title: Type.String(),
    voice: Type.String(),
    speed: Type.Number(),
    durationSec: Type.Number(),
    sizeBytes: Type.Integer(),
    itemCount: Type.Integer(),
    status: Type.String({ description: 'pending / running / done / failed' }),
    error: Type.Union([Type.String(), Type.Null()]),
    parts: Type.Integer({ description: '合成分段总数' }),
    doneParts: Type.Integer({ description: '已完成分段（进度）' }),
    sections: Type.Array(Type.String(), { description: '本期涉及的新闻类别标签' }),
    headlines: Type.Array(Type.String(), { description: '本期新闻标题（前若干条）' }),
    createdAt: Type.Integer(),
    finishedAt: Type.Union([Type.Integer(), Type.Null()]),
  },
  { $id: 'BlogEpisodeItem' },
);

export const BlogEpisodeListResponse = Type.Object(
  { items: Type.Array(Type.Ref(BlogEpisodeItem)) },
  { $id: 'BlogEpisodeListResponse' },
);

export const BlogQuery = Type.Object(
  { limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 200 })) },
  { $id: 'BlogQuery' },
);

export const BlogGenerateBody = Type.Object(
  {
    /** 不传就用已保存的设置（定时任务也走同一条路） */
    counts: Type.Optional(
      Type.Ref(BlogCounts, { description: '八个类别整体替换（与页面提交方式一致）' }),
    ),
    voice: Type.Optional(Type.String({ maxLength: 40 })),
    speed: Type.Optional(Type.Number({ minimum: 0.5, maximum: 2 })),
  },
  { $id: 'BlogGenerateBody' },
);

export const BlogGenerateResponse = Type.Object(
  { id: Type.String(), status: Type.String() },
  { $id: 'BlogGenerateResponse' },
);

export const BlogResynthBody = Type.Object(
  {
    /** 已落库的一期 id；稿件必须已经生成过（失败/中断/已完成都可以） */
    id: Type.String({ minLength: 1, maxLength: 64 }),
  },
  { $id: 'BlogResynthBody' },
);

export const BlogResynthResponse = Type.Object(
  { id: Type.String(), status: Type.String() },
  { $id: 'BlogResynthResponse' },
);

export const BlogStatusResponse = Type.Object(
  {
    id: Type.String(),
    status: Type.String(),
    parts: Type.Integer(),
    doneParts: Type.Integer(),
    error: Type.Union([Type.String(), Type.Null()]),
    message: Type.String(),
  },
  { $id: 'BlogStatusResponse' },
);

export const BlogPreviewBody = Type.Object(
  { voice: Type.Optional(Type.String({ maxLength: 40 })) },
  { $id: 'BlogPreviewBody' },
);

export const BlogWarmupResponse = Type.Object(
  {
    ready: Type.Boolean(),
    available: Type.Boolean(),
    reason: Type.Optional(Type.Union([Type.String(), Type.Null()])),
  },
  { $id: 'BlogWarmupResponse' },
);

/**
 * 语音模型一键下载状态。
 * `installed` 是**实时探测磁盘**得到的，不存标记：模型在就永远显示「已下载」，
 * 用户删了文件也立刻变回「未下载」，不会出现假状态。
 */
export const BlogTtsModelResponse = Type.Object(
  {
    installed: Type.Boolean(),
    downloading: Type.Boolean(),
    /** 0~100，跨三个文件加权 */
    percent: Type.Number(),
    phase: Type.String({ description: '当前阶段的人话描述（排障用，UI 不直接展示）' }),
    /** bin / model1 / model2 / done / error / idle：前端据此选本地化文案 */
    task: Type.String(),
    error: Type.Union([Type.String(), Type.Null()]),
    binReady: Type.Boolean(),
    modelReady: Type.Boolean(),
    modelDir: Type.Union([Type.String(), Type.Null()]),
  },
  { $id: 'BlogTtsModelResponse' },
);

export const BlogPreviewResponse = Type.Object(
  { url: Type.String(), expiresInSec: Type.Integer(), cached: Type.Boolean() },
  { $id: 'BlogPreviewResponse' },
);

export const BlogAudioUrlResponse = Type.Object(
  { url: Type.String(), expiresInSec: Type.Integer() },
  { $id: 'BlogAudioUrlResponse' },
);

export const BlogIdQuery = Type.Object(
  { id: Type.String({ minLength: 1 }) },
  { $id: 'BlogIdQuery' },
);

export const BlogVoiceQuery = Type.Object(
  { voice: Type.String({ minLength: 1 }) },
  { $id: 'BlogVoiceQuery' },
);

export const BlogRemoveBody = Type.Object(
  { id: Type.String({ minLength: 1 }) },
  { $id: 'BlogRemoveBody' },
);

export const BlogOkResponse = Type.Object({ ok: Type.Boolean() }, { $id: 'BlogOkResponse' });

export const BlogNewsItem = Type.Object(
  {
    category: Type.String(),
    title: Type.String(),
    summary: Type.String(),
    link: Type.String(),
    source: Type.String(),
    published: Type.Union([Type.Integer(), Type.Null()]),
  },
  { $id: 'BlogNewsItem' },
);

export const BlogNewsResponse = Type.Object(
  {
    items: Type.Array(Type.Ref(BlogNewsItem)),
    /** 抓取失败的源（前端提示「某些源不可用」，不影响其余新闻） */
    failed: Type.Array(Type.String()),
  },
  { $id: 'BlogNewsResponse' },
);

export const BlogErrorResponse = Type.Object(
  {
    error: Type.String(),
    message: Type.Optional(Type.String()),
    code: Type.Optional(Type.String()),
  },
  { $id: 'BlogErrorResponse' },
);

export const BLOG_SCHEMAS = [
  BlogCounts,
  BlogSettingsResponse,
  BlogSettingsBody,
  BlogVoiceItem,
  BlogVoiceListResponse,
  BlogVoiceUploadBody,
  BlogVoiceUploadResponse,
  BlogVoiceRemoveBody,
  BlogEpisodeItem,
  BlogEpisodeListResponse,
  BlogQuery,
  BlogGenerateBody,
  BlogGenerateResponse,
  BlogResynthBody,
  BlogResynthResponse,
  BlogStatusResponse,
  BlogPreviewBody,
  BlogWarmupResponse,
  BlogTtsModelResponse,
  BlogPreviewResponse,
  BlogAudioUrlResponse,
  BlogIdQuery,
  BlogVoiceQuery,
  BlogRemoveBody,
  BlogOkResponse,
  BlogNewsItem,
  BlogNewsResponse,
  BlogErrorResponse,
];
