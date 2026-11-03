#!/usr/bin/env node
/**
 * X-02 SBOM 生成与第三方许可清单。
 *
 * 产出：
 *   docs/sbom/sbom.cdx.json       CycloneDX 1.5（子集）
 *   docs/sbom/third-party-licenses.md
 *
 * 用法：
 *   node tool/sbom.js            生成
 *   node tool/sbom.js --check    校验产物与当前依赖一致（CI 门禁，不一致退出 1）
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..');
const outDir = path.join(root, 'docs', 'sbom');
const cdxyFile = path.join(outDir, 'sbom.cdx.json');
const licFile = path.join(outDir, 'third-party-licenses.md');

const CHECK = process.argv.includes('--check');

function readJson(p) {
  return JSON.parse(fs.readFileSync(p, 'utf8'));
}

function safeReadJson(p) {
  try {
    return readJson(p);
  } catch {
    return null;
  }
}

function licenseOf(pkgPath, meta) {
  if (meta && typeof meta.license === 'string') return meta.license;
  if (meta && meta.license && typeof meta.license.type === 'string') return meta.license.type;
  if (meta && Array.isArray(meta.licenses)) {
    const ids = meta.licenses.map((l) => (typeof l === 'string' ? l : l && l.type)).filter(Boolean);
    if (ids.length) return ids.join(' OR ');
  }
  if (pkgPath) {
    const meta2 = safeReadJson(path.join(pkgPath, 'package.json'));
    if (meta2) return licenseOf(null, meta2);
  }
  return 'UNKNOWN';
}

function collect() {
  const lock = safeReadJson(path.join(root, 'package-lock.json'));
  if (!lock || !lock.packages) {
    console.error('[FATAL] package-lock.json 缺失或格式不支持（需要 lockfileVersion>=2）');
    process.exit(2);
  }

  const comps = [];
  for (const [key, meta] of Object.entries(lock.packages)) {
    if (!key) continue; // 根项目
    const name = meta.name || key.replace(/^.*node_modules\//, '');
    if (!name || !meta.version) continue;
    const pkgPath = path.join(root, key);
    const resolved = meta.resolved || '';
    let license = meta.license;
    if (!license) {
      const pj = safeReadJson(path.join(pkgPath, 'package.json'));
      license = pj ? licenseOf(null, pj) : 'UNKNOWN';
    }
    comps.push({
      name,
      version: meta.version,
      license: typeof license === 'string' ? license : 'UNKNOWN',
      dev: meta.dev === true,
      optional: meta.optional === true,
      resolved: resolved.split('?')[0],
      path: key,
    });
  }

  comps.sort((a, b) => (a.name === b.name ? a.version.localeCompare(b.version) : a.name.localeCompare(b.name)));
  return comps;
}

function buildCdx(comps) {
  return {
    bomFormat: 'CycloneDX',
    specVersion: '1.5',
    version: 1,
    metadata: {
      tools: [{ vendor: 'ColaNasOs', name: 'tool/sbom.js' }],
      component: {
        type: 'application',
        name: 'colanas_os_server',
        version: safeReadJson(path.join(root, 'package.json')).version,
      },
    },
    components: comps.map((c) => ({
      type: 'library',
      'bom-ref': `${c.name}@${c.version}`,
      name: c.name,
      version: c.version,
      scope: c.dev ? 'excluded' : 'required',
      ...(c.license !== 'UNKNOWN' ? { licenses: [{ license: { id: c.license } }] } : {}),
      ...(c.resolved ? { purl: c.resolved } : {}),
    })),
  };
}

function buildLicenses(comps) {
  const byLicense = new Map();
  for (const c of comps) {
    const list = byLicense.get(c.license) || [];
    list.push(c);
    byLicense.set(c.license, list);
  }

  const total = comps.length;
  const prod = comps.filter((c) => !c.dev).length;
  const unknown = comps.filter((c) => c.license === 'UNKNOWN');
  const lines = [
    '# 第三方许可清单',
    '',
    '> 自动生成，请勿手改；更新依赖后执行 `npm run sbom`。',
    '',
    `- 组件总数：**${total}**（运行时 ${prod} / 开发期 ${total - prod}）`,
    `- 许可未知：**${unknown.length}**`,
    '',
    '## 按许可汇总',
    '',
    '| 许可 | 数量 |',
    '| --- | --- |',
  ];
  for (const [lic, list] of [...byLicense.entries()].sort((a, b) => b[1].length - a[1].length)) {
    lines.push(`| ${lic} | ${list.length} |`);
  }

  lines.push('', '## 明细', '', '| 组件 | 版本 | 许可 | 范围 |', '| --- | --- | --- | --- |');
  for (const c of comps) {
    lines.push(`| ${c.name} | ${c.version} | ${c.license} | ${c.dev ? 'dev' : 'runtime'} |`);
  }

  if (unknown.length) {
    lines.push('', '## 待补许可', '', '> 这些组件未在 package.json 中声明 license，发布前需人工确认：', '');
    for (const c of unknown) lines.push(`- \`${c.name}@${c.version}\`（${c.path}）`);
  }
  lines.push('');
  return lines.join('\n');
}

function stableJson(obj) {
  return JSON.stringify(obj, null, 2) + '\n';
}

const comps = collect();
const cdx = stableJson(buildCdx(comps));
const lic = buildLicenses(comps);

if (CHECK) {
  const a = safeReadJson(cdxyFile);
  const b = readJson(path.join(root, 'package-lock.json'));
  const old = a ? stableJson(a) : '';
  const oldLic = fs.existsSync(licFile) ? fs.readFileSync(licFile, 'utf8') : '';
  const ok = old === cdx && oldLic === lic;
  console.log(ok ? '[OK]   sbom 与依赖一致' : '[FAIL] sbom 与依赖不一致，请执行 npm run sbom');
  if (!ok && b) {
    const oldNames = new Set((a && a.components ? a.components : []).map((c) => `${c.name}@${c.version}`));
    const added = comps.filter((c) => !oldNames.has(`${c.name}@${c.version}`));
    if (added.length) console.log('  新增: ' + added.slice(0, 10).map((c) => `${c.name}@${c.version}`).join(', '));
  }
  process.exit(ok ? 0 : 1);
}

fs.mkdirSync(outDir, { recursive: true });
fs.writeFileSync(cdxyFile, cdx, 'utf8');
fs.writeFileSync(licFile, lic, 'utf8');
console.log(`[OK]   sbom 已生成：${comps.length} 个组件`);
console.log(`       ${path.relative(root, cdxyFile)}`);
console.log(`       ${path.relative(root, licFile)}`);