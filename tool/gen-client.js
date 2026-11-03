#!/usr/bin/env node
/**
 * 契约 → Dart 生成器（SP1-01）。
 * 输入：contracts/openapi.json
 * 输出：packages/nas_core/lib/api/{client.dart, models.dart}
 *
 * 用法：
 *   node tool/gen-client.js            生成
 *   node tool/gen-client.js --check    校验磁盘与生成一致（CI 用）
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..');
const specPath = path.join(root, 'contracts', 'openapi.json');
const outDir = path.join(root, 'packages', 'nas_core', 'lib', 'api');
const checkOnly = process.argv.includes('--check');

const spec = JSON.parse(fs.readFileSync(specPath, 'utf-8'));

// ---------------------------------------------------------------- 类型映射

/** OpenAPI schema → Dart 类型 */
function dartType(schema, opts = {}) {
  if (!schema) return 'dynamic';

  let type;
  if (schema.$ref) {
    type = schema.$ref.split('/').pop();
  } else if (schema.type === 'array') {
    type = `List<${dartType(schema.items)}>`;
  } else {
    switch (schema.type) {
      case 'string':
        type = 'String';
        break;
      case 'integer':
        type = 'int';
        break;
      case 'number':
        type = 'double';
        break;
      case 'boolean':
        type = 'bool';
        break;
      case 'object':
        type = 'Map<String, dynamic>';
        break;
      default:
        type = 'dynamic';
    }
  }

  const nullable = opts.nullable || schema.nullable === true;
  if (nullable && type !== 'dynamic' && !type.endsWith('?')) type += '?';
  return type;
}

/** 生成 fromJson 表达式（传入值非 null） */
function fromJsonExpr(schema, src) {
  if (!schema) return `(${src} as dynamic)`;

  if (schema.$ref) {
    return `${dartType(schema)}.fromJson(${src} as Map<String, dynamic>)`;
  }
  if (schema.type === 'array') {
    const inner = schema.items || {};
    if (inner.$ref) {
      return `(${src} as List<dynamic>).map((e) => ${inner.$ref.split('/').pop()}.fromJson(e as Map<String, dynamic>)).toList()`;
    }
    return `(${src} as List<dynamic>).cast<${dartType(inner)}>()`;
  }
  switch (schema.type) {
    case 'string':
    case 'integer':
    case 'boolean':
    case 'object':
      // dartType 已处理 nullable → `String?` / `Map<String, dynamic>?`
      return `${src} as ${dartType(schema)}`;
    case 'number':
      // 必填但 nullable 的 number（契约里 `type: number, nullable: true`）必须写成
      // `as num?`：否则服务端给 null 时 `null as num` 会抛
      // 「Null is not a subtype of type num」，整页渲染直接崩。
      // 典型受害者：video Item 的 score（没刮到评分的片子该字段就是 null）。
      // 注意 integer 分支不用特判：它走 `as ${dartType(schema)}`，nullable 时自然是 `as int?`。
      return schema.nullable === true
        ? `(${src} as num?)?.toDouble()`
        : `(${src} as num).toDouble()`;
    default:
      return `(${src} as dynamic)`;
  }
}

/** 可选字段：null 直通，否则走 fromJsonExpr */
function fromJsonField(prop, key, isRequired) {
  const src = `json['${key}']`;
  const expr = fromJsonExpr(prop, src);
  return isRequired ? expr : `${src} == null ? null : ${expr}`;
}

/** 生成 toJson 表达式 */
function toJsonExpr(schema, src) {
  if (!schema) return src;
  if (schema.$ref) return `${src}.toJson()`;
  if (schema.type === 'array') {
    const inner = schema.items || {};
    if (inner.$ref) return `${src}.map((e) => e.toJson()).toList()`;
    return src;
  }
  return src;
}

/** 可选字段在 toJson 内已被 null 检查包裹，需用 `!` 解包 */
function toJsonField(prop, key, isRequired) {
  const src = isRequired ? key : `${key}!`;
  return toJsonExpr(prop, src);
}

function header() {
  return [
    '// AUTO-GENERATED. DO NOT EDIT.',
    '// source: contracts/openapi.json',
    '// regenerate: npm run gen:client',
    '',
  ];
}

// ---------------------------------------------------------------- 模型

/** 参数体（Query/Body）不作为 DTO，只生成响应与实体 */
function isModel(name, schema) {
  if (schema.type !== 'object') return false;
  if (name.endsWith('Query')) return false;
  return true;
}

function genModels() {
  const schemas = spec.components?.schemas || {};
  const out = header();

  for (const [name, schema] of Object.entries(schemas)) {
    if (!isModel(name, schema)) continue;

    const props = schema.properties || {};
    const required = new Set(schema.required || []);

    out.push(`class ${name} {`);
    const ctorArgs = [];
    for (const [key, prop] of Object.entries(props)) {
      const field = key;
      const isReq = required.has(key);
      const type = dartType(prop, { nullable: !isReq });
      ctorArgs.push(isReq ? `required this.${field}` : `this.${field}`);
      out.push(`  final ${type} ${field};`);
    }
    if (ctorArgs.length > 0) {
      out.push('', `  const ${name}({`);
      for (const a of ctorArgs) out.push(`    ${a},`);
      out.push('  });');
    } else {
      out.push('', `  const ${name}();`);
    }

    // fromJson
    out.push('', `  factory ${name}.fromJson(Map<String, dynamic> json) => ${name}(`);
    for (const [key, prop] of Object.entries(props)) {
      const isReq = required.has(key);
      out.push(`        ${key}: ${fromJsonField(prop, key, isReq)},`);
    }
    out.push('      );');

    // toJson
    out.push('', '  Map<String, dynamic> toJson() => <String, dynamic>{');
    for (const [key, prop] of Object.entries(props)) {
      const isReq = required.has(key);
      const value = toJsonField(prop, key, isReq);
      if (isReq) {
        out.push(`        '${key}': ${value},`);
      } else {
        out.push(`        if (${key} != null) '${key}': ${value},`);
      }
    }
    out.push('      };', '}', '');
  }

  if (Object.keys(schemas).length === 0) {
    out.push('// 契约暂无 components.schemas', '');
  }

  return out.join('\n');
}

// ---------------------------------------------------------------- 客户端

const HTTP_METHODS = ['get', 'post', 'put', 'patch', 'delete'];

function pascal(name) {
  return name.charAt(0).toUpperCase() + name.slice(1);
}

/** 任意字符串 → Dart lowerCamelCase */
function toCamel(input) {
  const parts = String(input)
    .split(/[^a-zA-Z0-9]+/)
    .filter(Boolean);
  return parts
    .map((p, i) => (i === 0 ? p.charAt(0).toLowerCase() + p.slice(1) : pascal(p)))
    .join('');
}

function genClient() {
  const out = header();
  out.push(
    "import 'dart:convert';",
    '',
    "import 'api_error.dart';",
    "import 'models.dart';",
    "import 'transport.dart';",
    '',
    '/// 由 OpenAPI 生成的强类型客户端。',
    '/// 鉴权通过 [tokenProvider] 注入，不在客户端保存密钥。',
    'class ApiClient {',
    '  ApiClient({',
    '    required this.baseUrl,',
    '    required this.transport,',
    '    this.tokenProvider,',
    '  });',
    '',
    '  final String baseUrl;',
    '  final Transport transport;',
    '  final Future<String?> Function()? tokenProvider;',
    '',
    '  Uri _uri(String path, [Map<String, String>? query]) {',
    "    final uri = Uri.parse('$baseUrl$path');",
    '    if (query == null || query.isEmpty) return uri;',
    '    return uri.replace(queryParameters: query);',
    '  }',
    '',
    '  Future<Map<String, String>> _headers({bool jsonBody = false, bool binaryBody = false}) async {',
    '    final headers = <String, String>{};',
    "    if (jsonBody) headers['content-type'] = 'application/json';",
    "    if (binaryBody) headers['content-type'] = 'application/octet-stream';",
    '    final token = await tokenProvider?.call();',
    '    if (token != null && token.isNotEmpty) {',
    "      headers['authorization'] = 'Bearer $token';",
    '    }',
    '    return headers;',
    '  }',
    '',
    '  Object? _decode(ApiResponse res) {',
    '    if (!res.isOk) throw ApiError.from(res);',
    '    if (res.body.isEmpty) return null;',
    '    try {',
    '      return res.json;',
    '    } catch (_) {',
    '      return res.text;',
    '    }',
    '  }',
    '',
    '  Map<String, dynamic> _asMap(Object? value) =>',
    '      value is Map<String, dynamic> ? value : <String, dynamic>{};',
    '',
    '  void close() => transport.close();',
    '',
  );

  for (const [url, ops] of Object.entries(spec.paths || {})) {
    for (const method of HTTP_METHODS) {
      const op = ops[method];
      if (!op) continue;

      const opId = op.operationId || toCamel(`${method} ${url}`);
      const summary = (op.summary || '').replace(/\r?\n/g, ' ');

      // 参数
      const params = [];
      const queryLines = [];
      for (const p of op.parameters || []) {
        const name = p.name;
        const type = dartType(p.schema, { nullable: !p.required });
        params.push(p.required ? `required ${type} ${name}` : `${type} ${name}`);
        if (p.in === 'query') {
          // query 一律拼成字符串；数字用插值，布尔需显式 toString()
          const numeric = p.schema && (p.schema.type === 'integer' || p.schema.type === 'number');
          const isBool = p.schema && p.schema.type === 'boolean';
          const value = numeric ? `'$${name}'` : isBool ? `${name}.toString()` : name;
          if (p.required) {
            queryLines.push(`      '${name}': ${value},`);
          } else {
            queryLines.push(`      if (${name} != null) '${name}': ${value},`);
          }
        }
      }

      // 请求体
      const bodyContent = op.requestBody?.content || {};
      let bodyParam = null;
      let bodyExpr = null;
      let jsonBody = false;
      let binaryBody = false;
      if (bodyContent['application/json']) {
        const bodySchema = bodyContent['application/json'].schema;
        if (bodySchema && bodySchema.$ref) {
          const model = bodySchema.$ref.split('/').pop();
          bodyParam = `required ${model} body`;
          bodyExpr = 'utf8.encode(jsonEncode(body.toJson()))';
        } else {
          bodyParam = 'required Map<String, dynamic> body';
          bodyExpr = 'utf8.encode(jsonEncode(body))';
        }
        jsonBody = true;
      } else if (bodyContent['application/octet-stream']) {
        bodyParam = 'required List<int> body';
        bodyExpr = 'body';
        // 二进制请求体必须显式声明 content-type：
        // Fastify 只为 application/octet-stream 注册了 buffer 解析器，缺头会走 JSON 解析并 415。
        binaryBody = true;
      }

      // 返回类型
      const resSchema = op.responses?.['200']?.content?.['application/json']?.schema;
      const isBinary = op['x-response-binary'] === true;
      const returnType = isBinary
        ? 'List<int>'
        : resSchema?.$ref
          ? resSchema.$ref.split('/').pop()
          : 'Map<String, dynamic>';

      const signature = [...params, ...(bodyParam ? [bodyParam] : [])].join(', ');

      out.push(`  /// ${summary || opId}`);
      out.push(
        `  Future<${returnType}> ${opId}(${signature.length > 0 ? `{${signature}}` : ''}) async {`,
      );

      if (queryLines.length > 0) {
        out.push('    final query = <String, String>{');
        out.push(...queryLines);
        out.push('    };');
        out.push(
          `    final res = await transport.send('${method.toUpperCase()}', _uri('${url}', query), headers: await _headers(${jsonBody ? 'jsonBody: true' : binaryBody ? 'binaryBody: true' : ''})${bodyExpr ? `, body: ${bodyExpr}` : ''});`,
        );
      } else {
        out.push(
          `    final res = await transport.send('${method.toUpperCase()}', _uri('${url}'), headers: await _headers(${jsonBody ? 'jsonBody: true' : binaryBody ? 'binaryBody: true' : ''})${bodyExpr ? `, body: ${bodyExpr}` : ''});`,
        );
      }

      if (isBinary) {
        if (!op.responses || Object.keys(op.responses).length === 0) {
          out.push('    _decode(res);');
        } else {
          out.push('    if (!res.isOk) throw ApiError.from(res);');
        }
        out.push('    return res.body;');
      } else if (resSchema?.$ref) {
        out.push(`    return ${returnType}.fromJson(_asMap(_decode(res)));`);
      } else {
        out.push('    return _asMap(_decode(res));');
      }

      out.push('  }', '');
    }
  }

  out.push('}');
  return out.join('\n');
}

// ---------------------------------------------------------------- 写出

function writeIfNeeded(file, content) {
  const exists = fs.existsSync(file);
  const prev = exists ? fs.readFileSync(file, 'utf-8') : '';
  if (prev === content) return { file, changed: false };
  if (checkOnly) return { file, changed: true };
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, content, 'utf-8');
  return { file, changed: true };
}

const files = [
  writeIfNeeded(path.join(outDir, 'models.dart'), genModels()),
  writeIfNeeded(path.join(outDir, 'client.dart'), genClient()),
];

if (checkOnly) {
  const stale = files.filter((f) => f.changed);
  if (stale.length > 0) {
    console.error(
      '[gen-client.check] 生成物已过期，请运行 npm run gen:client：\n' +
        stale.map((f) => '  - ' + path.relative(root, f.file)).join('\n'),
    );
    process.exit(1);
  }
  console.log('[gen-client.check] ok');
} else {
  for (const f of files) {
    console.log(`[gen-client] ${f.changed ? 'wrote' : 'unchanged'} ${path.relative(root, f.file)}`);
  }
}
