import crypto from 'node:crypto';
import { sql } from 'kysely';
import type { KernelApi } from '../../../kernel/types';
import type { FastifyInstance, FastifyRequest, FastifyReply } from 'fastify';
import { fromBuffer } from './ai/face';

/**
 * 最小只读 MCP 服务（JSON-RPC 2.0 over HTTP）。
 *
 * 只提供 6 个查询工具，不开放任何写操作；令牌与挂载用户在 AI 设置里维护，
 * 数据范围按挂载用户过滤（缺省 = 令牌所属配置的 uid）。
 */

interface McpConfig {
  enabled: boolean;
  uid: string;
  token: string;
}

const TOOLS = [
  {
    name: 'photo_search',
    description: '按关键词 / 时间范围搜索照片',
    inputSchema: {
      type: 'object',
      properties: {
        q: { type: 'string', description: '路径关键词' },
        from: { type: 'integer', description: '起始时间（epoch 秒）' },
        to: { type: 'integer', description: '结束时间（epoch 秒）' },
        limit: { type: 'integer', default: 30 },
      },
    },
  },
  {
    name: 'photo_recent',
    description: '最近拍摄的照片',
    inputSchema: {
      type: 'object',
      properties: { limit: { type: 'integer', default: 30 } },
    },
  },
  {
    name: 'photo_similar',
    description: '以图搜图：给一张照片找相似照片',
    inputSchema: {
      type: 'object',
      properties: {
        photoId: { type: 'string', description: '源照片 id' },
        limit: { type: 'integer', default: 12 },
      },
      required: ['photoId'],
    },
  },
  {
    name: 'photo_scenes',
    description: '场景标签分布，或某个场景下的照片',
    inputSchema: {
      type: 'object',
      properties: {
        label: { type: 'string', description: '场景名；留空返回分布' },
        limit: { type: 'integer', default: 30 },
      },
    },
  },
  {
    name: 'photo_faces',
    description: '人物相册列表（人脸簇）',
    inputSchema: {
      type: 'object',
      properties: { limit: { type: 'integer', default: 20 } },
    },
  },
  {
    name: 'photo_stats',
    description: '照片总量 / 年份分布 / 活跃天数',
    inputSchema: { type: 'object', properties: {} },
  },
];

const TOOL_NAMES = TOOLS.map((t) => t.name);

function readConfig(k: KernelApi): McpConfig {
  const raw = (k.config.get<Partial<McpConfig>>('mcp') || {}) as Partial<McpConfig>;
  return {
    enabled: raw.enabled === true,
    uid: String(raw.uid || ''),
    token: String(raw.token || ''),
  };
}

function authorized(k: KernelApi, token: string): boolean {
  const cfg = readConfig(k);
  if (!cfg.enabled || !cfg.token || !token) return false;
  const a = Buffer.from(cfg.token);
  const b = Buffer.from(token);
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

function ownerFilter(uid: string) {
  return sql`library_id in (select id from photo_libraries where owner_id = ${uid})`;
}

export async function registerPhotoMcp(app: FastifyInstance, k: KernelApi): Promise<void> {
  const callTool = async (uid: string, name: string, args: Record<string, any>) => {
    const limit = Math.max(1, Math.min(Number(args.limit) || 30, 200));
    if (name === 'photo_search') {
      const rows = (
        await sql<Record<string, unknown>>`
          select id, rel_path, taken_at, size, width, height, mime, favorite
            from photo_items
           where in_trash = 0 and ${ownerFilter(uid)}
             ${args.q ? sql`and rel_path like ${`%${String(args.q).replace(/[\\%_]/g, (c) => `\\${c}`)}%`}` : sql``}
             ${args.from ? sql`and taken_at >= ${Number(args.from)}` : sql``}
             ${args.to ? sql`and taken_at <= ${Number(args.to)}` : sql``}
           order by taken_at desc limit ${limit}
        `.execute(k.db)
      ).rows;
      return rows;
    }
    if (name === 'photo_recent') {
      const rows = (
        await sql<Record<string, unknown>>`
          select id, rel_path, taken_at, size, width, height, mime
            from photo_items
           where in_trash = 0 and ${ownerFilter(uid)}
           order by taken_at desc limit ${limit}
        `.execute(k.db)
      ).rows;
      return rows;
    }
    if (name === 'photo_similar') {
      const base = (
        await sql<{ vec: Buffer }>`
          select e.vec from photo_embeddings e
            join photo_items i on i.id = e.photo_id
           where e.photo_id = ${String(args.photoId || '')} and i.in_trash = 0
             and ${ownerFilter(uid)}
        `.execute(k.db)
      ).rows[0];
      if (!base) return { items: [], message: '没有这张照片的向量' };
      const scanLimit = Math.max(100, Math.min(Number(process.env.COLANAS_VECTOR_SCAN_LIMIT) || 5000, 50_000));
      const rows = (
        await sql<{ photo_id: string; vec: Buffer }>`
          select e.photo_id, e.vec from photo_embeddings e
            join photo_items i on i.id = e.photo_id
           where e.photo_id != ${String(args.photoId || '')} and i.in_trash = 0
             and ${ownerFilter(uid)}
           limit ${scanLimit}
        `.execute(k.db)
      ).rows;
      const a = fromBuffer(base.vec);
      const scored = rows.map((r) => {
        const b = fromBuffer(r.vec);
        let dot = 0;
        let na = 0;
        let nb = 0;
        for (let i = 0; i < a.length; i += 1) {
          dot += a[i] * b[i];
          na += a[i] * a[i];
          nb += b[i] * b[i];
        }
        return { id: r.photo_id, score: dot / (Math.sqrt(na) * Math.sqrt(nb) || 1) };
      });
      scored.sort((x, y) => y.score - x.score);
      const top = scored.slice(0, limit);
      if (top.length === 0) return { items: [] };
      const ids = sql.join(
        top.map((t) => sql`${t.id}`),
        sql`, `,
      );
      const items = (
        await sql<Record<string, unknown>>`
          select id, rel_path, taken_at from photo_items where id in (${ids})
        `.execute(k.db)
      ).rows;
      const byId = new Map(items.map((r) => [String(r.id), r]));
      return {
        items: top
          .map((t) => {
            const item = byId.get(t.id);
            return item ? { ...item, score: Number(t.score.toFixed(4)) } : null;
          })
          .filter((r) => r != null),
      };
    }
    if (name === 'photo_scenes') {
      if (!args.label) {
        const rows = (
          await sql<{ label: string; count: number }>`
            select s.label, count(*) as count
              from photo_scenes s
              join photo_items i on i.id = s.photo_id
             where i.in_trash = 0 and ${ownerFilter(uid)}
             group by s.label order by count desc limit 100
          `.execute(k.db)
        ).rows;
        return { items: rows.map((r) => ({ label: r.label, count: Number(r.count) })) };
      }
      const rows = (
        await sql<Record<string, unknown>>`
          select i.id, i.rel_path, i.taken_at
            from photo_scenes s join photo_items i on i.id = s.photo_id
           where s.label = ${String(args.label)} and i.in_trash = 0 and ${ownerFilter(uid)}
           order by i.taken_at desc limit ${limit}
        `.execute(k.db)
      ).rows;
      return { items: rows };
    }
    if (name === 'photo_faces') {
      const rows = (
        await sql<Record<string, unknown>>`
          select c.id, c.name, c.size,
                 (select i.rel_path from photo_items i where i.id = c.cover_photo_id) as cover_path
            from photo_face_clusters c
           order by c.size desc limit ${limit}
        `.execute(k.db)
      ).rows;
      return { items: rows };
    }
    if (name === 'photo_stats') {
      const agg = (
        await sql<{ n: number; earliest: number | null; latest: number | null }>`
          select count(*) as n, min(taken_at) as earliest, max(taken_at) as latest
            from photo_items
           where in_trash = 0 and ${ownerFilter(uid)}
        `.execute(k.db)
      ).rows[0];
      const years = (
        await sql<{ year: number; count: number }>`
          select cast(strftime('%Y', taken_at, 'unixepoch', 'localtime') as integer) as year,
                 count(*) as count
            from photo_items
           where in_trash = 0 and ${ownerFilter(uid)}
           group by year order by year desc
        `.execute(k.db)
      ).rows;
      return {
        items: Number(agg?.n) || 0,
        earliest: agg?.earliest ?? null,
        latest: agg?.latest ?? null,
        byYear: years.map((r) => ({ year: Number(r.year), count: Number(r.count) })),
      };
    }
    throw new Error(`未知工具：${name}`);
  };

  app.post('/api/mcp', async (req: FastifyRequest, reply: FastifyReply) => {
    const cfg = readConfig(k);
    if (!cfg.enabled) {
      return reply.code(403).send({ jsonrpc: '2.0', error: { code: -32000, message: 'MCP 服务未启用' } });
    }
    const auth = String(req.headers.authorization || '');
    const token = auth.startsWith('Bearer ') ? auth.slice(7).trim() : '';
    if (!authorized(k, token)) {
      return reply.code(401).send({ jsonrpc: '2.0', error: { code: -32001, message: '令牌无效' } });
    }
    const body = (req.body || {}) as {
      jsonrpc?: string;
      id?: string | number | null;
      method?: string;
      params?: Record<string, any>;
    };
    const id = body.id ?? null;
    const method = String(body.method || '');
    if (method === 'initialize') {
      return {
        jsonrpc: '2.0',
        id,
        result: {
          protocolVersion: '2024-11-05',
          capabilities: { tools: {} },
          serverInfo: { name: 'colanas-photo', version: '1.0.0' },
        },
      };
    }
    if (method === 'notifications/initialized') {
      return reply.code(202).send();
    }
    if (method === 'ping') {
      return { jsonrpc: '2.0', id, result: {} };
    }
    if (method === 'tools/list') {
      return { jsonrpc: '2.0', id, result: { tools: TOOLS } };
    }
    if (method === 'tools/call') {
      const name = String(body.params?.name || '');
      const args = (body.params?.arguments || {}) as Record<string, any>;
      if (!TOOL_NAMES.includes(name)) {
        return {
          jsonrpc: '2.0',
          id,
          error: { code: -32602, message: `未知工具：${name}` },
        };
      }
      try {
        const result = await callTool(cfg.uid || '', name, args);
        return {
          jsonrpc: '2.0',
          id,
          result: {
            content: [{ type: 'text', text: JSON.stringify(result) }],
          },
        };
      } catch (err) {
        return {
          jsonrpc: '2.0',
          id,
          error: { code: -32002, message: String((err as Error)?.message || err) },
        };
      }
    }
    return {
      jsonrpc: '2.0',
      id,
      error: { code: -32601, message: `不支持的方法：${method}` },
    };
  });

  // Streamable HTTP 的 GET 通道暂不提供（只做请求-响应）
  app.get('/api/mcp', async (_req: FastifyRequest, reply: FastifyReply) =>
    reply.code(405).send({ error: 'method_not_allowed', message: '只支持 POST JSON-RPC' }),
  );
}