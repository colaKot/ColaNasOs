import path from 'node:path';
import { sql } from 'kysely';
import {
  isFullAccess,
  readPolicy,
  type PathRule,
} from '../../../kernel/access-policy';
import type { ConfigStore } from '../../../kernel/config';
import { filesRoot } from './fs-root';

/**
 * 「这个账号能看到哪些目录」的统一判定。
 *
 * 目录授权里存的路径有两种形态：文件根内的相对路径（`/media`）和目录选择器
 * 选出来的绝对路径（`D:/Media` → 归一后 `/D:/Media`）。而库 / 条目里的路径
 * 同样两者都有，直接字符串比会永远对不上。这里把两侧统一折成
 * **绝对 POSIX 小写路径**再比，规则与候选就落在同一个坐标系里。
 *
 * 语义：
 * - 全权账号（`*` / 访问令牌的 ownerAdmin）→ `unrestricted`，任何过滤都不生效；
 * - 管理员没给这个账号配目录规则 → `unrestricted`（没做限制，列表按全量，
 *   真实读写仍由 preHandler 的「没配规则 = 全拒 403」兜底）；
 * - 配了目录规则的普通账号 → 只放行规则覆盖到的路径。
 */
export interface Visibility {
  unrestricted: boolean;
  rules: PathRule[];
  /** 归一后的绝对路径前缀（小写、无尾斜杠） */
  prefixes: string[];
}

function posix(input: string): string {
  return String(input ?? '').trim().replace(/\\/g, '/');
}

/** 规则路径 / 库源路径 / 条目路径统一成绝对形式 */
export function absolutePathOf(input: string): string {
  const s = posix(input);
  if (!s) return posix(filesRoot()).toLowerCase().replace(/\/+$/, '');
  // 规则经 normalizePathRule 后带前导斜杠：`/D:/Media` 其实是绝对路径。
  const bare = s.replace(/^\/+/, '');
  if (/^[A-Za-z]:/.test(bare) || bare.startsWith('//')) {
    return path.posix.normalize(bare).toLowerCase().replace(/\/+$/, '');
  }
  const root = posix(filesRoot()).replace(/\/+$/, '');
  return (root + '/' + bare).toLowerCase().replace(/\/+$/, '');
}

export function visibilityOf(config: ConfigStore, user: unknown): Visibility {
  if (isFullAccess(user)) {
    return { unrestricted: true, rules: [], prefixes: [] };
  }
  const uid = String((user as { sub?: string } | null)?.sub ?? '');
  const policy = readPolicy(config, uid);
  const rules = policy.paths ?? [];
  // 没配目录授权 = 管理员没有做目录限制，列表按全量显示。真正的文件 / 下载
  // 访问仍由 preHandler 的 effectivePathRules 兜底（没配规则 = 全拒 403），
  // 所以放行「库 / 来源这些元数据」不会放大读写权限。
  if (rules.length === 0) {
    return { unrestricted: true, rules: [], prefixes: [] };
  }
  return {
    unrestricted: false,
    rules,
    prefixes: rules.map((r) => absolutePathOf(r.path)),
  };
}

/** 一条数据（库源 / 条目 / 文件）是否落在授权目录内 */
export function pathVisible(v: Visibility, candidate: string): boolean {
  if (v.unrestricted) return true;
  if (v.rules.length === 0) return false;
  if (v.rules.some((r) => r.path === '/')) return true;
  const abs = absolutePathOf(candidate);
  return v.prefixes.some((p) => abs === p || abs.startsWith(`${p}/`));
}

/**
 * 目录选择器用：除了授权目录本身与子目录，**通往它的祖先目录**也要能浏览，
 * 否则用户根本点不进 `D:/Media/Movies`（`D:` 和 `D:/Media` 会被过滤掉）。
 */
export function dirVisible(v: Visibility, candidate: string): boolean {
  if (v.unrestricted) return true;
  if (v.rules.length === 0) return false;
  if (v.rules.some((r) => r.path === '/')) return true;
  const abs = absolutePathOf(candidate);
  return v.prefixes.some(
    (p) => abs === p || abs.startsWith(`${p}/`) || p.startsWith(`${abs}/`),
  );
}

/**
 * SQL LIKE 前缀：条目列表要在数据库里过滤才能保住分页，不能拉全量到内存。
 * 同时给出「原始形态」和「绝对形态」两套，覆盖 rel_path 的相对 / 绝对两种写法。
 */
export function likePrefixes(v: Visibility): string[] {
  const out = new Set<string>();
  const root = posix(filesRoot()).replace(/\/+$/, '').toLowerCase();
  for (const r of v.rules) {
    const bare = posix(r.path).replace(/^\/+/, '');
    if (bare) out.add(bare);
    const abs = absolutePathOf(r.path).replace(/^\/+/, '');
    if (abs) out.add(abs);
    // 目录选择器选出来的是绝对路径，规则因此是 `/C:/.../files/music`；
    // 但库 / 曲目的 rel_path 往往是相对 filesRoot 的 `music/a.mp3`。
    // 少了这一条，库能显示、曲目却被 LIKE 全部滤空（2026-11-12 tv 账号实测）。
    if (abs.toLowerCase().startsWith(`${root}/`)) {
      out.add(abs.slice(root.length + 1));
    }
  }
  return [...out];
}

/**
 * 可拼进 `where` 的 SQL 片段：列表接口靠它把过滤留在数据库里，
 * 分页 / cursor 语义才不会被破坏（拉全量到内存过滤会让每页条数变少）。
 * 超级管理员返回恒真；没配目录的普通账号返回恒假。
 */
export function pathWhere(v: Visibility, column: string) {
  if (v.unrestricted) return sql`1 = 1`;
  const prefs = likePrefixes(v);
  if (prefs.length === 0) return sql`1 = 0`;
  let cond = sql`1 = 0`;
  for (const p of prefs) {
    cond = sql`${cond} or ${sql.ref(column)} like ${`${p}%`}`;
  }
  return cond;
}
