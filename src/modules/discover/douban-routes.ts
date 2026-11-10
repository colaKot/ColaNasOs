import { Type } from '@sinclair/typebox';
import { secured } from '../../../kernel/route';
import type { KernelApi } from '../../../kernel/types';
import { fetchDoubanChart, fetchDoubanRating, toCatalogItem } from './douban';
import { doubanTest } from './rating';
import { normalizeConfig } from './tmdb';
import type { FastifyRequest } from 'fastify';

/**
 * 豆瓣发现：榜单 + 评分查询。
 * Cookie 可选（存 config `discover.doubanCookie`），没有也能用公开 JSON 接口。
 */
const TAG = ['discover'];

export async function registerDoubanRoutes(app: any, k: KernelApi): Promise<void> {
  const cookieOf = () => k.config.get<string>('discover.doubanCookie') || undefined;

  app.get(
    '/api/v1/discover/douban',
    secured('discover:read', {
      schema: {
        operationId: 'discoverDouban',
        tags: TAG,
        summary: '豆瓣榜单（热门/选电影等 tag）',
        querystring: Type.Object({
          tag: Type.Optional(Type.String({ maxLength: 32 })),
          limit: Type.Optional(Type.String()),
        }),
        response: {
          200: Type.Object(
            {
              items: Type.Array(
                Type.Object(
                  {
                    id: Type.String(),
                    title: Type.String(),
                    rating: Type.Union([Type.Number(), Type.Null()]),
                    coverUrl: Type.Union([Type.String(), Type.Null()]),
                    year: Type.Union([Type.String(), Type.Null()]),
                    source: Type.String(),
                  },
                  { additionalProperties: true },
                ),
              ),
            },
            { additionalProperties: true },
          ),
        },
      },
    }),
    async (req: FastifyRequest) => {
      const q = (req.query || {}) as { tag?: string; limit?: string };
      const limit = Math.max(1, Math.min(Number(q.limit) || 50, 100));
      const items = await fetchDoubanChart(String(q.tag || '热门'), { cookie: cookieOf() });
      return { items: items.slice(0, limit).map(toCatalogItem) };
    },
  );

  app.get(
    '/api/v1/discover/douban/rating',
    secured('discover:read', {
      schema: {
        operationId: 'discoverDoubanRating',
        tags: TAG,
        summary: '按标题（+年份）查豆瓣评分',
        querystring: Type.Object({
          title: Type.String({ minLength: 1, maxLength: 200 }),
          year: Type.Optional(Type.String({ maxLength: 8 })),
        }),
        response: {
          200: Type.Object(
            { rating: Type.Union([Type.Number(), Type.Null()]) },
            { additionalProperties: true },
          ),
        },
      },
    }),
    async (req: FastifyRequest) => {
      const q = (req.query || {}) as { title?: string; year?: string };
      const rating = await fetchDoubanRating(String(q.title || ''), q.year ?? null, {
        cookie: cookieOf(),
      });
      return { rating };
    },
  );

  // 读取豆瓣配置（Cookie 明文回传：用户要能看见自己配了什么）
  app.get(
    '/api/v1/discover/douban/settings',
      secured('discover:read', {
        schema: {
          operationId: 'discoverDoubanSettingsGet',
          tags: TAG,
          summary: '读取豆瓣配置（Cookie 明文回传）',
          response: {
            200: Type.Object({
              cookie: Type.String(),
              configured: Type.Boolean(),
            }),
          },
        },
      }),
      async () => {
        const cookie = String(k.config.get('discover.doubanCookie') || '');
        return { cookie, configured: cookie.trim().length > 0 };
      },
    );

    // 连通性自检：网站 / Cookie 登录态 / TMDB 反查命中率，三段分开给结论
    app.post(
      '/api/v1/discover/douban/test',
      secured('discover:read', {
        schema: {
          operationId: 'discoverDoubanTest',
          tags: TAG,
          summary: '测试豆瓣连通性（网站 / Cookie / TMDB 反查）',
          body: Type.Object({
            cookie: Type.Optional(Type.String({ maxLength: 4096 })),
          }),
          response: {
            200: Type.Object({
              site: Type.Object({
                ok: Type.Boolean(),
                elapsed_ms: Type.Integer(),
                code: Type.String(),
              }),
              cookie: Type.Object({
                provided: Type.Boolean(),
                valid: Type.Boolean(),
                user: Type.String(),
                elapsed_ms: Type.Integer(),
                code: Type.String(),
              }),
              tmdb_match: Type.Object({
                total: Type.Integer(),
                matched: Type.Integer(),
                match_rate: Type.Integer(),
              }),
              sample: Type.Union([
                Type.Object({ title: Type.String(), rating: Type.Union([Type.Number(), Type.Null()]) }),
                Type.Null(),
              ]),
            }),
          },
        },
      }),
      async (req: FastifyRequest) => {
        const body = (req.body || {}) as { cookie?: string };
        const cookie = String(body.cookie ?? '').trim()
          || String(k.config.get('discover.doubanCookie') || '').trim();
        const cfg = normalizeConfig(k.config.get('discover.tmdb'));
        return doubanTest(cfg, cookie);
      },
    );

    app.post(
    '/api/v1/discover/douban/settings',
    secured('discover:write', {
      schema: {
        operationId: 'discoverDoubanSettings',
        tags: TAG,
        summary: '设置豆瓣 Cookie（可选）',
        body: Type.Object({ cookie: Type.String({ maxLength: 4096 }) }),
        response: { 200: Type.Object({ ok: Type.Boolean() }) },
      },
    }),
    async (req: FastifyRequest) => {
      const body = (req.body || {}) as { cookie?: string };
      await k.config.set('discover.doubanCookie', String(body.cookie || ''));
      return { ok: true };
    },
  );
}
