// AUTO-GENERATED. DO NOT EDIT.
// source: contracts/errors.json
// regenerate: npm run gen:errors

/** 统一错误码：值就是 API 返回里的 `error` 字段（与旧版裸字符串完全兼容） */
export const Err = {
  badRequest: 'badRequest',
  unauthorized: 'unauthorized',
  forbidden: 'forbidden',
  appForbidden: 'appForbidden',
  pathForbidden: 'pathForbidden',
  notFound: 'notFound',
  conflict: 'conflict',
  gone: 'gone',
  corrupted: 'corrupted',
  unsupported: 'unsupported',
  empty: 'empty',
  tooLarge: 'tooLarge',
  unavailable: 'unavailable',
  mediaUnavailable: 'mediaUnavailable',
  aiUnavailable: 'aiUnavailable',
  internal: 'internal',
} as const;

export type ErrorCode = keyof typeof Err;

/** 每个错误码的默认 HTTP 状态（业务可用 `reply.code()` 覆盖） */
export const ERROR_STATUS: Record<ErrorCode, number> = {
  badRequest: 400,
  unauthorized: 401,
  forbidden: 403,
  appForbidden: 403,
  pathForbidden: 403,
  notFound: 404,
  conflict: 409,
  gone: 410,
  corrupted: 400,
  unsupported: 400,
  empty: 400,
  tooLarge: 413,
  unavailable: 503,
  mediaUnavailable: 503,
  aiUnavailable: 503,
  internal: 500,
};

/** 默认文案（中文；客户端可本地化） */
export const ERROR_MESSAGE: Record<ErrorCode, string> = {
  badRequest: "请求参数不合法",
  unauthorized: "未登录或令牌失效",
  forbidden: "缺少所需权限",
  appForbidden: "该子账号无权访问此应用",
  pathForbidden: "路径超出允许范围",
  notFound: "资源不存在",
  conflict: "资源冲突（重复创建）",
  gone: "资源已失效（过期 / 已撤销）",
  corrupted: "数据校验失败（清单与文件不一致）",
  unsupported: "当前格式或能力不受支持",
  empty: "内容为空",
  tooLarge: "内容超过大小上限",
  unavailable: "依赖服务不可用",
  mediaUnavailable: "缺少 ffmpeg 或媒体 sidecar",
  aiUnavailable: "缺少模型或 AI sidecar",
  internal: "服务端内部错误",
};
