/* 巨石模块拆分器：把 src/modules/<m>/index.ts 拆成
 *   util.ts（模块级类型 / 常量 / 纯函数）
 *   migrations.ts（建表迁移）
 *   helpers.ts（register 内闭包辅助函数的工厂）
 *   routes/<分节>.ts（每个分节注释一个注册器）
 *   index.ts（只留 id/prefix/permissions + register 依次调用）
 *
 * 只做机械搬运：不改任何 SQL、schema、handler 逻辑。
 */
const fs = require('node:fs');
const path = require('node:path');

const ROOT = 'src/modules';

function countParen(s) {
  let d = 0;
  for (const ch of s) {
    if (ch === '{' || ch === '(' || ch === '[') d++;
    if (ch === '}' || ch === ')' || ch === ']') d--;
  }
  return d;
}

function bindingsOf(code) {
  const names = [];
  const def = code.match(/^import\s+([^'"]+?)\s+from\s/);
  if (!def) return names;
  const head = def[1].trim();
  const named = head.match(/\{([\s\S]*?)\}/);
  if (named) {
    for (const part of named[1].split(',')) {
      const seg = part.trim();
      if (!seg) continue;
      const alias = seg.split(/\s+as\s+/);
      names.push((alias[1] || alias[0]).trim().replace(/^type\s+/, ''));
    }
  }
  const bare = head.replace(/\{[\s\S]*?\}/, '').replace(/,/g, ' ').trim();
  for (const seg of bare.split(/\s+/)) if (seg && seg !== 'type') names.push(seg.replace(/^\*\s+as\s+/, ''));
  return names;
}

function collectImports(lines, endIdx) {
  const out = [];
  let i = 0;
  while (i < endIdx) {
    if (!/^import\b/.test(lines[i].trim())) {
      i++;
      continue;
    }
    let code = lines[i];
    while (!/from\s+['"][^'"]+['"];?\s*$/.test(code) && i + 1 < endIdx) {
      i++;
      code += `\n${lines[i]}`;
    }
    out.push({ code: code.replace(/\s+$/, ''), bindings: bindingsOf(code) });
    i++;
  }
  return out;
}

/** routes/ 子目录多一层：`./x` -> `../x`，`../x` -> `../../x` */
function rewritePath(code, up) {
  if (!up) return code;
  return code.replace(/from\s+['"](\.[^'"]*)['"]/g, (m, p) => `from '${'../'.repeat(up)}${p.replace(/^\.\//, '')}'`);
}

function filterImports(imports, body, up) {
  return imports
    .filter((imp) => imp.bindings.length === 0 || imp.bindings.some((b) => new RegExp(`\\b${b}\\b`).test(body)))
    .map((imp) => rewritePath(imp.code, up))
    .join('\n');
}

function exportedNames(text) {
  const names = [];
  for (const m of text.matchAll(/^export (?:interface|type|const|function|class) (\w+)/gm)) names.push(m[1]);
  return names;
}

function utilImport(text, names, from) {
  const used = names.filter((n) => new RegExp(`\\b${n}\\b`).test(text));
  return used.length ? `import { ${used.join(', ')} } from '${from}';` : '';
}

function constBlockEnd(lines, start, limit) {
  let depth = 0;
  for (let i = start; i < limit; i++) {
    depth += countParen(lines[i]);
    if (depth <= 0 && /;\s*$/.test(lines[i])) return i;
  }
  return start;
}

function pascal(s) {
  return s.replace(/(^|[-_])(\w)/g, (_, __, c) => c.toUpperCase());
}

function sectionize(regLines, keys, mainKey, skip = []) {
  const marks = [];
  regLines.forEach((l, i) => {
    if (!/^\s*\/\/ -{10,}/.test(l)) return;
    const title = l.replace(/^\s*\/\/\s*-+\s*/, '').trim();
    if (skip.some((s) => title.startsWith(s))) return;
    marks.push(i);
  });
  const pick = (title, i) => (keys.find(([prefix]) => title.startsWith(prefix)) || [null, `sec${i}`])[1];
  const blocks = [];
  const first = marks.length ? marks[0] : regLines.length;
  if (first > 0) blocks.push({ key: mainKey, title: '主注册', body: regLines.slice(0, first) });
  marks.forEach((m, i) => {
    const end = i + 1 < marks.length ? marks[i + 1] : regLines.length;
    const title = regLines[m].replace(/^\s*\/\/\s*-+\s*/, '').trim();
    blocks.push({ key: pick(title, i), title, body: regLines.slice(m, end) });
  });
  return blocks.filter((b) => /\bapp\.(get|post|put|patch|delete|route)\(/.test(b.body.join('\n')));
}

function clean(arr) {
  return arr.filter((x, i) => x !== '' || (i > 0 && arr[i - 1] !== '')).join('\n');
}

function splitModule({ mod, exportName, label, keys = [], mainKey = 'main', skip = [] }) {
  const file = path.join(ROOT, mod, 'index.ts');
  const lines = fs.readFileSync(file, 'utf8').split('\n');
  const objIdx = lines.findIndex((l) => new RegExp(`^export const ${exportName}: ServerModule = \\{`).test(l));
  const migStart = lines.findIndex((l, i) => i > objIdx && /^ {2}migrations: \[/.test(l));
  const migEnd = lines.findIndex((l, i) => i > migStart && /^ {2}\],\s*$/.test(l));
  const regIdx = lines.findIndex((l, i) => i > objIdx && /^ {2}async register\(app, k\) \{/.test(l));
  const regEnd = lines.findIndex((l, i) => i > regIdx && /^ {2}\},?\s*$/.test(l));
  if (objIdx < 0 || migStart < 0 || migEnd < 0 || regIdx < 0 || regEnd < 0) throw new Error(`layout unexpected: ${mod}`);

  const lastImport = lines.reduce((acc, l, i) => (i < objIdx && /^import\b/.test(l) ? i : acc), -1);
  const imports = collectImports(lines, objIdx);

  const utilLines = [];
  const commentLines = [];
  for (const l of lines.slice(lastImport + 1, objIdx)) {
    if (l.trim() === '') continue;
    if (utilLines.length === 0 && /^\s*(\/\/|\/\*|\*)/.test(l)) commentLines.push(l);
    else utilLines.push(l);
  }

  const regBody = lines.slice(regIdx + 1, regEnd);
  const helperBlocks = [];
  const keepSeq = [];
  const routeLines = [];
  let hasWatch = false;
  const constNames = [];
  for (let i = 0; i < regBody.length; i++) {
    const wm = /^ {4}const libWatch = /.exec(regBody[i]);
    if (wm) {
      const end = constBlockEnd(regBody, i, regBody.length);
      keepSeq.push({ kind: 'watch', code: regBody.slice(i, end + 1).join('\n') });
      hasWatch = true;
      i = end;
      continue;
    }
    const fn = /^ {4}const (\w+) = (async )?(\(|function|<)/.exec(regBody[i]);
    if (fn) {
      const end = constBlockEnd(regBody, i, regBody.length);
      helperBlocks.push({ name: fn[1], code: regBody.slice(i, end + 1) });
      constNames.push(fn[1]);
      i = end;
      continue;
    }
    if (/app\.addSchema\(/.test(regBody[i]) || /^ {4}await register\w+\(app, k\);/.test(regBody[i])) {
      keepSeq.push({ kind: 'other', code: regBody[i] });
      continue;
    }
    routeLines.push(regBody[i]);
  }

  const helperNames = helperBlocks.map((h) => h.name);
  const helperBody = helperBlocks.map((h) => h.code.join('\n')).join('\n\n');

  // util.ts
  const utilText = utilLines.map((l) => (/^(interface|type|const|function|class) /.test(l) ? `export ${l}` : l)).join('\n');
  const names = exportedNames(utilText);
  fs.writeFileSync(path.join(ROOT, mod, 'util.ts'), `${clean([filterImports(imports, utilText, 0), '', utilText]).trimEnd()}\n`);

  // migrations.ts
  const migBody = lines.slice(migStart + 1, migEnd).join('\n');
  const migConst = `${mod.toUpperCase()}_MIGRATIONS`;
  fs.writeFileSync(
    path.join(ROOT, mod, 'migrations.ts'),
    `${clean([filterImports(imports, migBody, 0), "import type { Migration } from '../../../kernel/migrator';", '', `export const ${migConst}: Migration[] = [`, migBody, '];']).trimEnd()}\n`,
  );

  // helpers.ts
  const pascalMod = pascal(mod);
  const helperType = `${pascalMod}Helpers`;
  const watchParam = hasWatch ? `, libWatch: { refresh(): Promise<void> | void }` : '';
  fs.writeFileSync(
    path.join(ROOT, mod, 'helpers.ts'),
    `${clean([
      filterImports(imports, helperBody, 0),
      utilImport(helperBody, names, './util'),
      "import type { KernelApi } from '../../../kernel/types';",
      '',
      `/** ${label} register 作用域内的闭包辅助函数（原样抽出，工厂化） */`,
      `export function make${helperType}(k: KernelApi${watchParam}) {`,
      helperBody,
      `  return { ${[...helperNames, ...(hasWatch ? ['libWatch'] : [])].join(', ')} };`,
      '}',
      '',
      `export type ${helperType} = ReturnType<typeof make${helperType}>;`,
    ]).trimEnd()}\n`,
  );

  // routes/*.ts
  const sections = sectionize(routeLines, keys, mainKey, skip);
  fs.mkdirSync(path.join(ROOT, mod, 'routes'), { recursive: true });
  const routeImports = [];
  for (const sec of sections) {
    let code = sec.body.join('\n');
    for (const n of helperNames) code = code.replace(new RegExp(`(?<!\\.)\\b${n}\\(`, 'g'), `h.${n}(`);
    if (hasWatch) code = code.replace(/\blibWatch\./g, 'h.libWatch.');
    const hUsed = /\bh\./.test(code);
    const fnName = `register${pascalMod}${pascal(sec.key.replace(/\\d+$/, ''))}`;
    routeImports.push({ fnName, key: sec.key });
    fs.writeFileSync(
      path.join(ROOT, mod, 'routes', `${sec.key}.ts`),
      `${clean([
        filterImports(imports, code, 1),
        utilImport(code, names, '../util'),
        "import type { FastifyInstance } from 'fastify';",
        "import type { KernelApi } from '../../../../kernel/types';",
        `import type { ${helperType} } from '../helpers';`,
        '',
        `/** ${sec.title} */`,
        `export async function ${fnName}(app: FastifyInstance, k: KernelApi, ${hUsed ? 'h' : '_h'}: ${helperType}): Promise<void> {`,
        code,
        '}',
      ]).trimEnd()}\n`,
    );
  }

  // index.ts
  const objHead = lines.slice(objIdx + 1, migStart).join('\n');
  const keepText = keepSeq.map((x) => x.code).join('\n');
  const calls = routeImports.map((r) => `    await ${r.fnName}(app, k, h);`).join('\n');
  const body = [keepText, objHead, calls, `export const ${exportName}: ServerModule = {`].join('\n');
  const indexText = clean([
    filterImports(imports, body, 0),
    utilImport(body, names, './util'),
    `import { ${migConst} } from './migrations';`,
    `import { make${helperType} } from './helpers';`,
    routeImports.map((r) => `import { ${r.fnName} } from './routes/${r.key}';`).join('\n'),
    '',
    commentLines.join('\n'),
    `export const ${exportName}: ServerModule = {`,
    objHead,
    `  migrations: ${migConst},`,
    '',
    '  async register(app, k) {',
    keepText,
    `    const h = make${helperType}(k${hasWatch ? ', libWatch' : ''});`,
    calls,
    '  },',
    '};',
  ]);
  fs.writeFileSync(file, `${indexText.trimEnd()}\n`);

  console.log(`${mod}: helpers=${helperNames.length}${hasWatch ? '+watch' : ''} routes=${routeImports.length} indexLines=${indexText.split('\n').length}`);
}

module.exports = { splitModule };

if (require.main === module) {
  const cfg = {
    book: {
      exportName: 'book',
      label: '书库',
      keys: [['库', 'library'], ['书架', 'shelf'], ['封面', 'reading'], ['收藏', 'favorites'], ['合集', 'collections'], ['自定义列表', 'lists']],
    },
    video: {
      exportName: 'video',
      label: '影视库',
      skip: ['图片', '视频'],
      keys: [['库', 'library'], ['列表', 'items'], ['海报', 'playback'], ['外挂字幕', 'subtitles']],
    },
    sync: { exportName: 'sync', label: '多端同步', keys: [['多端同步', 'tasks']], mainKey: 'jobs' },
    photo: { exportName: 'photo', label: '相册', keys: [['库', 'library'], ['时间轴', 'timeline'], ['相册', 'albums']] },
    music: {
      exportName: 'music',
      label: '音乐库',
      keys: [['库', 'library'], ['列表', 'items'], ['封面', 'playback'], ['播放列表', 'playlists']],
    },
  };
  const mod = process.argv[2];
  if (!mod || !cfg[mod]) throw new Error('usage: node tool/split/split-module.js <book|video|sync|photo|music>');
  splitModule({ mod, ...cfg[mod] });
}