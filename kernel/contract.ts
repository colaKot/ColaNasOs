export interface ContractSummary {
  paths: number;
  byPrefix: Record<string, number>;
}

/**
 * 契约注册表：从 Fastify 生成的 OpenAPI 文档汇总路由。
 * 供 `gen.check`、覆盖率比对与文档生成使用。
 */
export class ContractRegistry {
  constructor(private readonly app: any) {}

  paths(): string[] {
    const doc = this.app.swagger();
    return Object.keys((doc && doc.paths) || {});
  }

  summary(): ContractSummary {
    const all = this.paths();
    const byPrefix: Record<string, number> = {};
    for (const p of all) {
      const key = '/' + p.split('/').filter(Boolean).slice(0, 3).join('/');
      byPrefix[key] = (byPrefix[key] ?? 0) + 1;
    }
    return { paths: all.length, byPrefix };
  }
}
