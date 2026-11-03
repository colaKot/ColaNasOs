/**
 * 行为用例的类型契约（执行器与用例共用；只含类型，运行时不产生依赖）。
 */
export interface ResponseLike {
  statusCode: number;
  headers: Record<string, string | string[] | undefined>;
  body: string;
  json(): any;
}

export interface RequestOptions {
  headers?: Record<string, string>;
  payload?: unknown;
  /** 便捷写法：直接给 token 头 */
  token?: Record<string, string>;
}

export interface CaseContext {
  app: any;
  k: any;
  /** 当前域临时目录（dataDir / filesRoot 都在其下） */
  tmpDir: string;
  dataDir: string;
  filesRoot: string;
  token(scopes: string[], sub?: string): Promise<Record<string, string>>;
  request(method: string, url: string, opts?: RequestOptions): Promise<ResponseLike>;
  expect(condition: unknown, message: string): void;
  assertStatus(res: ResponseLike, expected: number, label?: string): void;
}

/** 四角色（用 scope 组合模拟，见 docs/behavior-用例指南.md §4） */
export type BehaviorRole = 'anonymous' | 'reader' | 'writer' | 'crossUser';

export interface BehaviorCase {
  id: string;
  name: string;
  /**
   * 该用例覆盖的角色。缺省时由 `tool/check/behavior-matrix.ts` 按 id 里的关键词推断
   * （`anonymous` / `reader` / `cross-user|isolated|other-user|per-user`），
   * 推断不出来的算 `writer`。命名不规范时请显式标注。
   */
  roles?: BehaviorRole[];
  run(ctx: CaseContext): Promise<void>;
}

export interface BehaviorDomain {
  domain: string;
  /**
   * 本域资源是全局共享的（账号表 / 挂载配置 / 订阅 / 备份 / 分享链接 / 同步任务 /
   * 进程监控 / Webhook），不存在「他人资源」，跨用户角色不适用。
   * 覆盖矩阵据此把跨用户列标为「不适用」且不计缺口。
   */
  shared?: boolean;
  /** 启动内核前准备（创建 files 根、写测试文件），返回额外 env */
  prepare?(tmpDir: string): Promise<Record<string, string>>;
  setup?(ctx: CaseContext): Promise<void>;
  teardown?(ctx: CaseContext): Promise<void>;
  cases: BehaviorCase[];
}

export interface CaseResult {
  domain: string;
  id: string;
  name: string;
  ok: boolean;
  ms: number;
  error?: string;
}