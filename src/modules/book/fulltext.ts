import fsp from 'node:fs/promises';
import { Type } from '@sinclair/typebox';
import { sql } from 'kysely';
import { secured } from '../../../kernel/route';
import type { KernelApi } from '../../../kernel/types';
import { filesRoot, resolveInRoot } from '../files/fs-root';
import { Err } from '../../../kernel/errors';
import type { FastifyRequest, FastifyReply } from 'fastify';

/**
 * 书籍全文检索（SQLite FTS5）。
 *
 * 分词策略：FTS5 的 `unicode61` 把连续 CJK 当一个 token，中文两字词搜不到；
 * 这里在写入与查询两侧都把 CJK **逐字加空格**，等价于单字索引 + 短语查询。
 * 索引内容：书名、作者（全部格式）+ txt 正文（≤2 MB，避免把大文件读进内存）。
 * epub/cbz/pdf 的正文不索引 —— 需要先解压/解析，代价高于收益，留给后续。
 */
const MAX_TXT = 2 * 1024 * 1024;
const CJK = /[\u3400-\u9fff\uf900-\ufaff]/g;

const CJK_NEIGHBOR = /([\u3400-\u9fff\uf900-\ufaff])\s+(?=[\u3400-\u9fff\uf900-\ufaff])/g;

/**
 * 把 FTS 片段里 CJK 词元之间的空格还原（索引时逐字加空格，
 * snippet 会按词元重建出「三 体」这种带空格的片段）。
 */
export function compactCjk(text: string): string {
  let out = text;
  for (let i = 0; i < 6; i += 1) {
    const next = out.replace(CJK_NEIGHBOR, '$1');
    if (next === out) break;
    out = next;
  }
  return out;
}

export function segment(text: string): string {
  return text
    .replace(CJK, (ch) => ` ${ch} `)
    .replace(/\s+/g, ' ')
    .trim();
}

const ReindexBody = Type.Object({}, { $id: 'BookFulltextReindexBody' });

const SearchQuery = Type.Object(
  {
    q: Type.String({ minLength: 1, description: '关键词（中文按单字切分后 AND 匹配）' }),
    limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 100, default: 20 })),
  },
  { $id: 'BookFulltextQuery' },
);

const Hit = Type.Object(
  {
    bookId: Type.String(),
    title: Type.String(),
    author: Type.Union([Type.String(), Type.Null()]),
    snippet: Type.String(),
  },
  { $id: 'BookFulltextHit' },
);

const SearchResponse = Type.Object(
  { items: Type.Array(Type.Ref(Hit)), total: Type.Integer() },
  { $id: 'BookFulltextResponse' },
);

const ReindexResponse = Type.Object(
  { indexed: Type.Integer(), skipped: Type.Integer() },
  { $id: 'BookFulltextReindexResponse' },
);

const ErrorResponse = Type.Object(
  {
    error: Type.String(),
    message: Type.Optional(Type.String()),
    code: Type.Optional(Type.String()),
    traceId: Type.Optional(Type.String()),
    details: Type.Optional(Type.Record(Type.String(), Type.Unknown())),
  },
  { $id: 'BookFulltextError' },
);

export const BOOK_FULLTEXT_SCHEMAS = [
  ReindexBody,
  SearchQuery,
  Hit,
  SearchResponse,
  ReindexResponse,
  ErrorResponse,
];

const ref = (id: string) => ({ $ref: `${id}#` });

export async function registerBookFulltext(app: any, k: KernelApi): Promise<void> {
  for (const schema of BOOK_FULLTEXT_SCHEMAS) app.addSchema(schema);

  app.post(
    '/api/v1/book/search/reindex',
    secured('book:write', {
      schema: {
        operationId: 'bookFulltextReindex',
        tags: ['book'],
        summary: '重建全文索引（书名 / 作者 + txt 正文）',
        body: ref('BookFulltextReindexBody'),
        response: { 200: ref('BookFulltextReindexResponse') },
      },
    }),
    async () => {
      const root = filesRoot();
      const rows = (
        await sql<{
          id: string;
          title: string;
          author: string | null;
          rel_path: string;
          format: string;
        }>`
          select id, title, author, rel_path, format from books
        `.execute(k.db)
      ).rows;

      let indexed = 0;
      let skipped = 0;
      for (const b of rows) {
        let body = '';
        if (b.format === 'txt') {
          try {
            const abs = resolveInRoot(root, b.rel_path);
            const stat = await fsp.stat(abs);
            if (stat.size <= MAX_TXT) body = await fsp.readFile(abs, 'utf8');
          } catch {
            /* 读不到就只索引元数据 */
          }
        } else {
          skipped += 1;
        }
        await sql`delete from book_search where book_id = ${b.id}`.execute(k.db);
        await sql`
          insert into book_search (book_id, title, author, body)
          values (${b.id}, ${segment(b.title || '')}, ${segment(b.author || '')}, ${segment(body)})
        `.execute(k.db);
        indexed += 1;
      }
      return { indexed, skipped };
    },
  );

  app.get(
    '/api/v1/book/search',
    secured('book:read', {
      schema: {
        operationId: 'bookFulltextSearch',
        tags: ['book'],
        summary: '全文检索（FTS5，返回片段）',
        querystring: ref('BookFulltextQuery'),
        response: { 200: ref('BookFulltextResponse'), 400: ref('BookFulltextError') },
      },
    }),
    async (req: FastifyRequest, reply: FastifyReply) => {
      const q = (req.query || {}) as { q?: string; limit?: number };
      const keyword = String(q.q || '').trim();
      if (!keyword) return reply.code(400).send({ error: Err.badRequest, message: 'q required' });
      const limit = Math.min(Number(q.limit || 20) || 20, 100);

      const terms = segment(keyword).split(' ').filter(Boolean);
      const match = terms.map((t) => `"${t.replace(/"/g, '')}"`).join(' AND ');

      const rows = (
        await sql<{ book_id: string; snippet: string }>`
          select book_id, snippet(book_search, 3, '', '', '…', 24) as snippet
          from book_search where book_search match ${match}
          order by bm25(book_search) limit ${limit}
        `.execute(k.db)
      ).rows;

      const items: Array<{
        bookId: string;
        title: string;
        author: string | null;
        snippet: string;
      }> = [];
      for (const r of rows) {
        const book = (
          await sql<{ title: string; author: string | null }>`
            select title, author from books where id = ${r.book_id}
          `.execute(k.db)
        ).rows[0];
        if (!book) continue;
        items.push({
          bookId: r.book_id,
          title: book.title,
          author: book.author,
          snippet: compactCjk(r.snippet),
        });
      }
      return { items, total: items.length };
    },
  );
}
