/**
 * FTS5 trigram 查询构造。
 *
 * trigram 只索引 3 字符窗口：**查询少于 3 个字符时 FTS 一定命中不了**
 * （中文两字词很常见，实测 `MATCH '情书'` 返回空）。所以调用方必须保留
 * 原来的 LIKE 路径，这里只负责给出 ≥3 字符时可直接喂给 `MATCH` 的短语。
 *
 * 用双引号包成 phrase：用户输入里的 `*` `-` `(` 等不会被当成 FTS 语法；
 * 内部的 `"` 按 FTS 规则双写转义。
 */
export function ftsPhrase(query: unknown): string | null {
  const term = String(query ?? '').trim();
  if (term.length < 3) return null;
  return `"${term.replace(/"/g, '""')}"`;
}
