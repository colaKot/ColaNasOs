#!/usr/bin/env node
/**
 * 端能力矩阵生成器（CL4-02）。
 * 输入：contracts/apps.json#capabilities（能力 × 端档位 + App 归属）
 * 输出：packages/nas_core/lib/capability_matrix.dart
 *
 * 用法：
 *   node tool/gen-capabilities.js            生成
 *   node tool/gen-capabilities.js --check    校验磁盘与契约一致
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..');
const src = path.join(root, 'contracts', 'apps.json');
const out = path.join(root, 'packages', 'nas_core', 'lib', 'capability_matrix.dart');
const checkOnly = process.argv.includes('--check');

const spec = JSON.parse(fs.readFileSync(src, 'utf-8'));
const caps = spec.capabilities || {};

/** `tv_android` → `tvAndroid` */
function camel(s) {
  const parts = String(s)
    .split(/[^a-zA-Z0-9]+/)
    .filter(Boolean);
  return parts
    .map((p, i) => (i === 0 ? p.charAt(0).toLowerCase() + p.slice(1) : p.charAt(0).toUpperCase() + p.slice(1)))
    .join('');
}

const endpoints = caps.endpoints || [];
const levels = caps.levels || [];
const items = caps.items || [];

if (!endpoints.length || !items.length) {
  console.error('[gen-capabilities] contracts/apps.json 缺少 capabilities.endpoints / items');
  process.exit(1);
}

function dartString(s) {
  return `'${String(s).replace(/\\/g, '\\\\').replace(/'/g, "\\'")}'`;
}

function gen() {
  const lines = [
    '// AUTO-GENERATED. DO NOT EDIT.',
    '// source: contracts/apps.json#capabilities',
    '// regenerate: npm run gen:caps',
    '',
    '/// 端能力矩阵的 6 端形态（docs/04 §64）。',
    'enum CapabilityEndpoint {',
    ...endpoints.map((e) => `  ${camel(e)},`),
    '}',
    '',
    `/// ${items.length} 类功能能力（docs/04 §64 的行）。`,
    'enum Capability {',
    ...items.map((it) => `  ${camel(it.id)},`),
    '}',
    '',
    '/// 某端对某能力的支持档位：完整 / 受限或降级 / 不提供。',
    'enum CapabilityLevel {',
    ...levels.map((l) => `  ${camel(l)},`),
    '}',
    '',
    '/// 一项能力在 6 端的档位声明。',
    'class CapabilityEntry {',
    '  const CapabilityEntry({',
    '    required this.id,',
    '    required this.nameKey,',
    '    required this.appIds,',
    '    required this.levels,',
    '  });',
    '',
    `  /// 能力 id（${items.map((it) => `\`${it.id}\``).join(' / ')}）`,
    '  final String id;',
    '',
    '  /// 能力名文案键（复用 App 名称，见 l10n/keys.dart）。',
    '  final String nameKey;',
    '',
    '  /// 归属该能力的 App id（外壳据此判断当前页是否需要提示）。',
    '  final List<String> appIds;',
    '',
    '  /// 端 → 档位；契约未声明的端一律视为 [CapabilityLevel.none]。',
    '  final Map<CapabilityEndpoint, CapabilityLevel> levels;',
    '',
    '  CapabilityLevel levelOn(CapabilityEndpoint endpoint) =>',
    '      levels[endpoint] ?? CapabilityLevel.none;',
    '',
    '  bool coversApp(String appId) => appIds.contains(appId);',
    '}',
    '',
    '/// 生成自 `contracts/apps.json#capabilities`；改矩阵只需改契约后重跑 `npm run gen:caps`。',
    'class CapabilityMatrix {',
    '  static const List<CapabilityEntry> entries = <CapabilityEntry>[',
  ];

  for (const it of items) {
    const levelLines = endpoints
      .map((e) => `        CapabilityEndpoint.${camel(e)}: CapabilityLevel.${camel(it.levels[e] || 'none')},`)
      .join('\n');
    lines.push('    CapabilityEntry(');
    lines.push(`      id: ${dartString(it.id)},`);
    lines.push(`      nameKey: ${dartString(it.nameKey)},`);
    lines.push(`      appIds: <String>[${(it.apps || []).map(dartString).join(', ')}],`);
    lines.push('      levels: <CapabilityEndpoint, CapabilityLevel>{');
    lines.push(levelLines);
    lines.push('      },');
    lines.push('    ),');
  }

  lines.push(
    '  ];',
    '',
    '  static CapabilityEntry? byId(String id) {',
    '    for (final entry in entries) {',
    '      if (entry.id == id) return entry;',
    '    }',
    '    return null;',
    '  }',
    '',
    '  /// 当前 App 对应的能力条目；未声明能力的 App（工作台 / 传输等）返回 null。',
    '  static CapabilityEntry? forApp(String appId) {',
    '    for (final entry in entries) {',
    '      if (entry.coversApp(appId)) return entry;',
    '    }',
    '    return null;',
    '  }',
    '',
    '  static CapabilityLevel levelOf(String id, CapabilityEndpoint endpoint) =>',
    '      byId(id)?.levelOn(endpoint) ?? CapabilityLevel.none;',
    '',
    '  /// 契约里的端键（`desktop` / `mobile` / `web` / `tv_android` / `tv_apple` / `harmony`）。',
    '  static String keyOf(CapabilityEndpoint endpoint) {',
    '    switch (endpoint) {',
    ...endpoints.map((e) => `      case CapabilityEndpoint.${camel(e)}:\n        return ${dartString(e)};`),
    '    }',
    '  }',
    '}',
    '',
  );

  return lines.join('\n');
}

const content = gen();
const prev = fs.existsSync(out) ? fs.readFileSync(out, 'utf-8') : '';

if (checkOnly) {
  if (prev !== content) {
    console.error('[gen:caps.check] capability_matrix.dart 已过期，请运行 npm run gen:caps');
    process.exit(1);
  }
  console.log(`[gen:caps.check] ok, capabilities=${items.length}, endpoints=${endpoints.length}`);
} else {
  fs.mkdirSync(path.dirname(out), { recursive: true });
  fs.writeFileSync(out, content, 'utf-8');
  console.log(`[gen:caps] wrote ${path.relative(root, out)} capabilities=${items.length}`);
}