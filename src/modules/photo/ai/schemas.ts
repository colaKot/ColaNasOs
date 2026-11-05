import { Type } from '@sinclair/typebox';

/**
 * photo 智能模块的路由契约（唯一真源：运行时校验 + OpenAPI + Dart 客户端）。
 * 每个 schema 带 `$id`，由全局限定名；跨模块复用的（PhotoSceneSummary / PhotoAiPhotoRefList）保持原名。
 */

export const AnalyzeBody = Type.Object(
  {
    libraryId: Type.Optional(Type.String()),
    limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 200, default: 10 })),
    force: Type.Optional(Type.Boolean({ default: false })),
    ocr: Type.Optional(
      Type.Boolean({ default: false, description: '同时做文字识别（票夹与语义搜索的原料）' }),
    ),
    activity: Type.Optional(
      Type.Boolean({ default: false, description: '同时做活动识别（SigLIP2 零样本）' }),
    ),
  },
  { $id: 'PhotoAiAnalyzeBody' },
);

/** 整库后台识别（入队 `photo.ai.scan`，内核重启后自动续跑） */
export const ScanBody = Type.Object(
  {
    force: Type.Optional(Type.Boolean({ default: false, description: '已识别过的也重算' })),
    ocr: Type.Optional(Type.Boolean({ default: false })),
    activity: Type.Optional(Type.Boolean({ default: false })),
    limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 200, default: 50 })),
  },
  { $id: 'PhotoAiScanBody' },
);

export const ScanResponse = Type.Object(
  {
    jobId: Type.String(),
    reused: Type.Boolean({ description: '已有同参数任务在跑时复用' }),
  },
  { $id: 'PhotoAiScanResponse' },
);
export const AnalyzeResponse = Type.Object(
  {
    processed: Type.Integer(),
    skipped: Type.Integer(),
    faces: Type.Integer(),
    scenes: Type.Integer(),
    ocr: Type.Integer({ description: '本次写入的 OCR 条数' }),
    activities: Type.Integer({ description: '本次写入的活动标签条数' }),
    remaining: Type.Integer(),
    /** 因「脸太小（占画面宽比过低）」被丢弃的人脸数：排查漏检/误检时看这个 */
    facesTooSmall: Type.Optional(Type.Integer()),
    /** 场景 v2 开放集门控分布（confident / ambiguous / unknown） */
    sceneGates: Type.Optional(
      Type.Object({
        confident: Type.Integer(),
        ambiguous: Type.Integer(),
        unknown: Type.Integer(),
      }),
    ),
  },
  { $id: 'PhotoAiAnalyzeResponse' },
);

export const ClusterItem = Type.Object(
  {
    id: Type.String(),
    name: Type.Union([Type.String(), Type.Null()]),
    size: Type.Integer(),
    coverPhotoId: Type.Union([Type.String(), Type.Null()]),
    /** 簇头像（人脸裁剪用）：客户端拼 `/photo/face/image?id=` */
    coverFaceId: Type.Optional(Type.Union([Type.String(), Type.Null()])),
  },
  { $id: 'PhotoFaceClusterItem' },
);

export const ClusterList = Type.Object(
  { items: Type.Array(Type.Ref(ClusterItem)) },
  { $id: 'PhotoFaceClusterList' },
);

export const ClusterDetailQuery = Type.Object(
  { id: Type.String({ minLength: 1 }) },
  { $id: 'PhotoFaceClusterQuery' },
);

export const FaceItem = Type.Object(
  {
    id: Type.String(),
    photoId: Type.String(),
    path: Type.String(),
    takenAt: Type.Integer(),
    score: Type.Number(),
    /** 人脸框（原图坐标）；加 bbox 之前入库的老数据为 null */
    boxLeft: Type.Optional(Type.Union([Type.Integer(), Type.Null()])),
    boxTop: Type.Optional(Type.Union([Type.Integer(), Type.Null()])),
    boxWidth: Type.Optional(Type.Union([Type.Integer(), Type.Null()])),
    boxHeight: Type.Optional(Type.Union([Type.Integer(), Type.Null()])),
  },
  { $id: 'PhotoFaceItem' },
);

export const FaceBackfillBody = Type.Object(
  {
    limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 5000, default: 500 })),
    /** 只处理这些照片（缺省按入库时间倒序取 limit 张） */
    photoIds: Type.Optional(Type.Array(Type.String({ minLength: 1 }), { maxItems: 2000 })),
  },
  { $id: 'PhotoFaceBackfillBody' },
);

export const FaceBackfillResponse = Type.Object(
  {
    photos: Type.Integer({ description: '处理的照片数' }),
    faces: Type.Integer({ description: '写入的人脸数' }),
    facesTooSmall: Type.Integer({ description: '因太小被丢弃的人脸数' }),
    remaining: Type.Integer({ description: '还有多少张照片的人脸缺坐标' }),
    skipped: Type.Integer(),
  },
  { $id: 'PhotoFaceBackfillResponse' },
);

export const FaceImageQuery = Type.Object(
  {
    id: Type.String({ minLength: 1, description: '人脸 id（photo_faces.id）' }),
    size: Type.Optional(Type.Integer({ minimum: 48, maximum: 512, default: 160 })),
  },
  { $id: 'PhotoFaceImageQuery' },
);

export const FaceList = Type.Object(
  { items: Type.Array(Type.Ref(FaceItem)) },
  { $id: 'PhotoFaceList' },
);

export const SceneSummaryItem = Type.Object(
  {
    label: Type.String(),
    count: Type.Integer(),
    /** 封面：该标签下**最近拍**的一张（列表改成网格后每个格子要一张图） */
    coverId: Type.Optional(Type.Union([Type.String(), Type.Null()])),
    coverPath: Type.Optional(Type.Union([Type.String(), Type.Null()])),
  },
  { $id: 'PhotoSceneSummaryItem' },
);

export const SceneSummary = Type.Object(
  { items: Type.Array(Type.Ref(SceneSummaryItem)) },
  { $id: 'PhotoSceneSummary' },
);

/**
 * 场景多标签（photo_scene_tags）。
 *
 * 与 `/photo/scenes` 的区别：那个读的是 top-1 单标签表 `photo_scenes`；
 * 这个读**多标签 + 置信度分层**，是「这张照片到底像什么」的真实答案。
 * `gate` 三态来自场景双路融合的开放集门控（confident / ambiguous / unknown）。
 */
export const SceneTagSummaryItem = Type.Object(
  {
    label: Type.String(),
    count: Type.Integer({ description: '该标签下的照片数（含 ambiguous）' }),
    confident: Type.Integer({ description: 'gate=confident 的条数' }),
    ambiguous: Type.Integer({ description: 'gate 非 confident 的条数' }),
    coverId: Type.Union([Type.String(), Type.Null()], {
      description: '封面取该标签下 score 最高的一条',
    }),
    /** 封面相对路径：客户端直接拼缩略图地址，不必再查一次 */
    coverPath: Type.Union([Type.String(), Type.Null()]),
  },
  { $id: 'PhotoSceneTagSummaryItem' },
);

export const SceneTagSummary = Type.Object(
  { items: Type.Array(Type.Ref(SceneTagSummaryItem)) },
  { $id: 'PhotoSceneTagSummary' },
);

export const SceneTagQuery = Type.Object(
  {
    label: Type.String({ minLength: 1 }),
    limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 500, default: 120 })),
    /** 只看高置信（confident）；缺省两者都出 */
    onlyConfident: Type.Optional(Type.Boolean({ default: false })),
  },
  { $id: 'PhotoSceneTagQuery' },
);

export const SceneTagItem = Type.Object(
  {
    id: Type.String(),
    path: Type.String(),
    takenAt: Type.Integer(),
    score: Type.Number(),
    gate: Type.Union([Type.String(), Type.Null()]),
    /** 只在「单张照片的全部标签」里出现 */
    label: Type.Optional(Type.String()),
  },
  { $id: 'PhotoSceneTagItem' },
);

export const SceneTagList = Type.Object(
  {
    label: Type.String(),
    items: Type.Array(Type.Ref(SceneTagItem)),
  },
  { $id: 'PhotoSceneTagList' },
);

/** 单张照片的全部场景标签（详情页"这张像什么"用） */
export const PhotoSceneTagsQuery = Type.Object(
  { id: Type.String({ minLength: 1 }) },
  { $id: 'PhotoSceneTagsQuery' },
);

export const SceneQuery = Type.Object(
  {
    label: Type.String({ minLength: 1 }),
    limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 200, default: 60 })),
  },
  { $id: 'PhotoSceneQuery' },
);

export const PhotoRef = Type.Object(
  {
    id: Type.String(),
    path: Type.String(),
    takenAt: Type.Integer(),
    score: Type.Optional(Type.Number()),
  },
  { $id: 'PhotoAiPhotoRef' },
);

export const PhotoRefList = Type.Object(
  { items: Type.Array(Type.Ref(PhotoRef)) },
  { $id: 'PhotoAiPhotoRefList' },
);

export const SimilarQuery = Type.Object(
  {
    id: Type.String({ minLength: 1 }),
    limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 100, default: 12 })),
    minScore: Type.Optional(
      Type.Number({
        minimum: 0,
        maximum: 1,
        description: '余弦下限；不传则不过滤（旧行为）',
      }),
    ),
  },
  { $id: 'PhotoSimilarQuery' },
);

export const BatchBody = Type.Object(
  {
    libraryId: Type.Optional(Type.String()),
    limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 200, default: 10 })),
    force: Type.Optional(Type.Boolean({ default: false })),
  },
  { $id: 'PhotoAiBatchBody' },
);

export const ActivityQuery = Type.Object(
  {
    label: Type.String({ minLength: 1 }),
    limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 200, default: 60 })),
  },
  { $id: 'PhotoActivityQuery' },
);

export const SemanticQuery = Type.Object(
  { q: Type.String({ minLength: 1, maxLength: 200 }) },
  { $id: 'PhotoSemanticQuery' },
);

export const SemanticComponent = Type.Object(
  {
    key: Type.String(),
    binding: Type.String(),
    tag: Type.String(),
    via: Type.String({ description: 'binding / binding_unavailable / embedding' }),
  },
  { $id: 'PhotoSemanticComponent' },
);

export const SemanticTag = Type.Object(
  { label: Type.String(), score: Type.Number(), hits: Type.Integer() },
  { $id: 'PhotoSemanticTag' },
);

export const SemanticParse = Type.Object(
  {
    ok: Type.Boolean(),
    normalized: Type.String(),
    components: Type.Array(Type.Ref(SemanticComponent)),
    unmatched: Type.Array(Type.String()),
    tags: Type.Array(Type.Ref(SemanticTag)),
    reason: Type.Optional(Type.String()),
  },
  { $id: 'PhotoSemanticParse' },
);

export const SemanticHit = Type.Object(
  {
    id: Type.String(),
    path: Type.String(),
    takenAt: Type.Integer(),
    score: Type.Number({ description: '命中标签数 + OCR / 路径命中加权' }),
    matched: Type.Array(Type.String()),
  },
  { $id: 'PhotoSemanticHit' },
);

export const SemanticSearchResponse = Type.Object(
  {
    normalized: Type.String(),
    tags: Type.Array(Type.Ref(SemanticTag)),
    unmatched: Type.Array(Type.String()),
    items: Type.Array(Type.Ref(SemanticHit)),
    degraded: Type.Boolean(),
    reason: Type.String(),
  },
  { $id: 'PhotoSemanticSearchResponse' },
);

export const FaceClusterFilterQuery = Type.Object(
  {
    minCount: Type.Optional(
      Type.Integer({
        minimum: 1,
        maximum: 1000,
        description: '展示门：少于这个张数的组不显示（具名组豁免）',
      }),
    ),
  },
  { $id: 'PhotoFaceClusterFilter' },
);

export const FaceNameBody = Type.Object(
  { clusterId: Type.String({ minLength: 1 }), name: Type.String({ maxLength: 64 }) },
  { $id: 'PhotoFaceNameBody' },
);

export const FaceDissolveBody = Type.Object(
  {
    clusterId: Type.String({ minLength: 1 }),
  },
  { $id: 'PhotoFaceDissolveBody' },
);

export const FaceMergeBody = Type.Object(
  { fromId: Type.String({ minLength: 1 }), toId: Type.String({ minLength: 1 }) },
  { $id: 'PhotoFaceMergeBody' },
);

export const FaceMergeResponse = Type.Object(
  { moved: Type.Integer(), clusterId: Type.String() },
  { $id: 'PhotoFaceMergeResponse' },
);

/** 单张人脸移动 / 移出簇（toClusterId 为 null 表示放回未分组） */
export const FaceMoveBody = Type.Object(
  {
    faceId: Type.String({ minLength: 1 }),
    toClusterId: Type.Optional(
      Type.Union([Type.String({ minLength: 1 }), Type.Null()], {
        description: '目标簇；null = 移出成未分组',
      }),
    ),
  },
  { $id: 'PhotoFaceMoveBody' },
);

export const FaceMoveResponse = Type.Object(
  {
    ok: Type.Boolean(),
    clusterId: Type.Union([Type.String(), Type.Null()], { description: '移动后的簇，null = 未分组' }),
  },
  { $id: 'PhotoFaceMoveResponse' },
);

/** 跨照片二次合并：先出候选，逐对确认后再合并 */
export const FaceMergeCandidateBody = Type.Object(
  {
    minSim: Type.Optional(
      Type.Number({
        minimum: 0.3,
        maximum: 0.99,
        description:
          '质心余弦下限；缺省取聚类参数 mergeClusterSim（默认 0.76，可用 COLANAS_FACE_MERGE_SIM 覆盖）',
      }),
    ),
    minEvidence: Type.Optional(
      Type.Integer({ minimum: 1, maximum: 50, default: 2, description: '近邻跨簇投票张数下限' }),
    ),
    limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 200, default: 30 })),
  },
  { $id: 'PhotoFaceMergeCandidateBody' },
);

export const FaceMergeCandidate = Type.Object(
  {
    fromId: Type.String({ description: '被并入方（较小的簇）' }),
    toId: Type.String({ description: '并入目标' }),
    fromName: Type.Union([Type.String(), Type.Null()]),
    toName: Type.Union([Type.String(), Type.Null()]),
    fromSize: Type.Integer(),
    toSize: Type.Integer(),
    fromCoverFaceId: Type.Union([Type.String(), Type.Null()]),
    toCoverFaceId: Type.Union([Type.String(), Type.Null()]),
    sim: Type.Number(),
    evidence: Type.Integer({ description: '跨簇近邻票数' }),
  },
  { $id: 'PhotoFaceMergeCandidate' },
);

export const FaceMergeCandidateList = Type.Object(
  {
    items: Type.Array(Type.Ref(FaceMergeCandidate)),
    scanned: Type.Integer({ description: '参与比对的簇数' }),
    pairs: Type.Integer({ description: '过阈值的候选对数（含被同框冲突过滤的）' }),
  },
  { $id: 'PhotoFaceMergeCandidateList' },
);

export const FaceMergeUndoBody = Type.Object(
  {
    ids: Type.Optional(Type.Array(Type.String({ minLength: 1 }), { maxItems: 100 })),
    limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 100, default: 20 })),
  },
  { $id: 'PhotoFaceMergeUndoBody' },
);

export const FaceMergeUndoResponse = Type.Object(
  {
    restored: Type.Integer(),
    faces: Type.Integer(),
  },
  { $id: 'PhotoFaceMergeUndoResponse' },
);

export const FaceRebuildBody = Type.Object(
  { limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 200000, default: 200000 })) },
  { $id: 'PhotoFaceRebuildBody' },
);

export const FaceRebuildResponse = Type.Object(
  {
    runId: Type.String(),
    faces: Type.Integer(),
    clusters: Type.Integer(),
    ms: Type.Integer(),
    /** v2：覆盖率（已归类样本 / 有效样本，百分比） */
    coverage: Type.Optional(Type.Number()),
    elapsedMs: Type.Optional(Type.Integer()),
    algoVersion: Type.Optional(Type.String()),
  },
  { $id: 'PhotoFaceRebuildResponse' },
);

export const FaceRollbackBody = Type.Object(
  { runId: Type.String({ minLength: 1 }) },
  { $id: 'PhotoFaceRollbackBody' },
);

export const FaceOk = Type.Object({ ok: Type.Boolean() }, { $id: 'PhotoFaceOk' });

export const FaceRescanBody = Type.Object(
  { limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 2000, default: 200 })) },
  { $id: 'PhotoFaceRescanBody' },
);

export const FaceMergeSimilarBody = Type.Object(
  {
    dryRun: Type.Optional(Type.Boolean({ default: false })),
    rounds: Type.Optional(Type.Integer({ minimum: 1, maximum: 5, default: 1 })),
  },
  { $id: 'PhotoFaceMergeSimilarBody' },
);

export const ErrorResponse = Type.Object(
  {
    error: Type.String(),
    message: Type.Optional(Type.String()),
    code: Type.Optional(Type.String()),
    traceId: Type.Optional(Type.String()),
    details: Type.Optional(Type.Record(Type.String(), Type.Unknown())),
  },
  { $id: 'PhotoAiError' },
);

export const PHOTO_AI_SCHEMAS = [
  ScanBody,
  ScanResponse,
  AnalyzeBody,
  AnalyzeResponse,
  ClusterItem,
  ClusterList,
  ClusterDetailQuery,
  FaceItem,
  FaceImageQuery,
  FaceBackfillBody,
  FaceBackfillResponse,
  FaceList,
  SceneSummaryItem,
  SceneSummary,
  SceneQuery,
  SceneTagSummaryItem,
  SceneTagSummary,
  SceneTagQuery,
  SceneTagItem,
  SceneTagList,
  PhotoSceneTagsQuery,
  PhotoRef,
  PhotoRefList,
  SimilarQuery,
  BatchBody,
  ActivityQuery,
  SemanticQuery,
  SemanticComponent,
  SemanticTag,
  SemanticParse,
  SemanticHit,
  SemanticSearchResponse,
  FaceClusterFilterQuery,
  FaceNameBody,
  FaceDissolveBody,
  FaceMergeBody,
  FaceMergeResponse,
  FaceMoveBody,
  FaceMoveResponse,
  FaceMergeCandidateBody,
  FaceMergeCandidate,
  FaceMergeCandidateList,
  FaceMergeUndoBody,
  FaceMergeUndoResponse,
  FaceRebuildBody,
  FaceRebuildResponse,
  FaceRollbackBody,
  FaceOk,
  FaceRescanBody,
  FaceMergeSimilarBody,
  ErrorResponse,
];

export const ref = (id: string) => ({ $ref: `${id}#` });
export const now = () => Math.floor(Date.now() / 1000);
export const EMB_DIM = 512;