import type { RouteShorthandOptions } from 'fastify';

/**
 * 受保护路由的元数据：
 * - `config.scope` 交给内核 preHandler 做越权校验（运行时）
 * - `schema.security` 让 OpenAPI 标注 `bearerAuth`（契约）
 * - `extra` 可叠加 operationId / tags / summary / querystring / response
 */
export function secured(
  scope: string,
  extra: Partial<RouteShorthandOptions> = {},
): RouteShorthandOptions {
  return {
    ...extra,
    config: { ...(extra.config as object | undefined), scope },
    schema: { security: [{ bearerAuth: [] }], ...(extra.schema as object | undefined) },
  } as unknown as RouteShorthandOptions;
}
