/**
 * compat 翻译表缺键检查。
 *
 * `features/discover` 与 `features/music` 各有一套独立中文表，用法是
 * `'some_key'.tr` / `'some_key'.trParams(...)`。这两套表的 getter 在缺键时
 * 回落成「键名本身」，于是中文界面上会直接出现 `music_list_page_of`
 * 这种 snake_case 英文 —— 肉眼很难在 Code Review 里发现。
 *
 * 这里静态扫描所有字面量调用，跟对应表逐一对账。
 * 用法：node tool/check/compat-i18n-check.js
 */
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '../..');
const groups = [
  {
    name: 'discover',
    dir: path.join(root, 'apps/colanas_os/lib/features/discover'),
    table: path.join(
      root,
      'apps/colanas_os/lib/features/discover/shell/compat/i18n.dart',
    ),
    tableName: 'kCompatZhCN',
  },
  {
    name: 'music',
    dir: path.join(root, 'apps/colanas_os/lib/features/music'),
    table: path.join(
      root,
      'apps/colanas_os/lib/features/music/shell/compat/i18n_music.dart',
    ),
    tableName: 'kMusicCompatZhCN',
  },
];

function walk(dir, out = []) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p, out);
    else if (e.isFile() && p.endsWith('.dart')) out.push(p);
  }
  return out;
}

function tableKeys(file) {
  const text = fs.readFileSync(file, 'utf-8');
  // 只取 `  'key': 'value',` 这种表项
  return new Set(
    [...text.matchAll(/^\s*'([^']+)'\s*:/gm)].map((m) => m[1]),
  );
}

const callRe = /'([A-Za-z0-9_.-]+)'\.(tr|trParams)\b/g;
let missingTotal = 0;

for (const g of groups) {
  const known = tableKeys(g.table);
  const used = new Map(); // key -> 首次出现的文件:行
  for (const file of walk(g.dir)) {
    if (file === g.table) continue;
    const lines = fs.readFileSync(file, 'utf-8').split(/\r?\n/);
    lines.forEach((line, i) => {
      const trimmed = line.trim();
      // 跳过文档注释 / 行注释，里面常有示例写法
      if (trimmed.startsWith('//') || trimmed.startsWith('*')) return;
      for (const m of line.matchAll(callRe)) {
        if (!used.has(m[1])) {
          used.set(m[1], `${path.relative(root, file)}:${i + 1}`);
        }
      }
    });
  }
  const missing = [...used].filter(([k]) => !known.has(k));
  missingTotal += missing.length;
  if (missing.length === 0) {
    console.log(
      `[compat-i18n] ${g.name}: ${used.size} 个 key 全部命中 ${g.tableName}`,
    );
  } else {
    console.error(`[compat-i18n] ${g.name}: 缺 ${missing.length} 个中文键`);
    for (const [k, at] of missing) console.error(`  - ${k}  (${at})`);
  }
}

if (missingTotal > 0) {
  console.error(`[compat-i18n] 共 ${missingTotal} 个缺键`);
  process.exit(1);
}
console.log('[compat-i18n] ok');
