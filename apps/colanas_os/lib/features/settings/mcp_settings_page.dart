import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';

/// 设置 → MCP：把 ColaNasOs 的内容与工程信息接入 AI IDE（Trae / WorkBuddy / Cursor 等）。
///
/// 两种接入，分两个标签：
/// - 内容查询：stdio sidecar（随安装包分发），需要只读令牌，页内一键生成；
/// - 工程台：stdio 源码工具（tool/mcp-dev），查工程信息 / 做诊断，无需令牌。
class McpSettingsPage extends StatefulWidget {
  const McpSettingsPage({super.key, this.embedded = false});

  /// true 时作为设置二级栏目内嵌展示（不再自带 Scaffold / AppBar）
  final bool embedded;

  @override
  State<McpSettingsPage> createState() => _McpSettingsPageState();
}

class _McpSettingsPageState extends State<McpSettingsPage> {
  int _tab = 0;
  String _token = '';
  bool _generating = false;

  static const _contentTools = <(String, String)>[
    ('files_list', '列出文件根内某个目录（相对路径）'),
    ('photo_timeline', '相册时间轴（按拍摄时间倒序）'),
    ('video_list', '影视列表（可关键词搜索）'),
    ('music_list', '音乐曲目（可关键词 / 艺术家 / 专辑过滤）'),
    ('system_monitor', '整机监控：CPU / 内存 / 磁盘 / 负载'),
    ('media_libraries', '各媒体库概况（相册 / 影视 / 音乐）'),
  ];

  static const _devTools = <(String, String)>[
    ('doc_search', '在 docs / AGENTS.md 等工程文档里按关键词检索'),
    ('contract_lookup', '查契约：错误码 / 路由 / i18n 键 / 应用 / 术语'),
    ('api_endpoint', '按 path 或 operationId 查端点详情'),
    ('project_facts', '工程元信息：版本 / 模块 / 契约计数 / 工具数'),
    ('diag_digest', '读 verify 报告：失败步骤 / 最慢步骤'),
    ('diag_static', '跑一组轻量只读检查（错误码 / 契约 / i18n / sbom）'),
    ('log_query', '查内核日志，按级别 / 关键字过滤'),
  ];

  String _contentConfig() {
    final cfg = {
      'mcpServers': {
        'colanas': {
          'command': 'node',
          'args': ['<ColaNasOs 服务端目录>/resources/sidecars/mcp/main.js'],
          'env': {
            'COLANAS_MCP_BASE_URL': ApiSession.instance.baseUrl,
            'COLANAS_MCP_TOKEN': _token.isEmpty ? '<在此生成令牌>' : _token,
          },
        },
      },
    };
    return const JsonEncoder.withIndent('  ').convert(cfg);
  }

  String _devConfig() {
    final cfg = {
      'mcpServers': {
        'colanas-dev': {
          'command': 'node',
          'args': ['<源码仓库>/tool/mcp-dev/main.js'],
        },
      },
    };
    return const JsonEncoder.withIndent('  ').convert(cfg);
  }

  String get _config => _tab == 0 ? _contentConfig() : _devConfig();

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _config));
    if (!mounted) return;
    NasSnack.show(context, tr('settings.mcp.copied'));
  }

  Future<void> _genToken() async {
    setState(() => _generating = true);
    try {
      final res = await ApiSession.instance.client.apiTokenCreate(
        body: {
          'name': 'MCP IDE 接入 ${DateTime.now().toIso8601String()}',
          'scopes': const ['files:read', 'photo:read', 'video:read', 'music:read', 'system:read'],
        },
      );
      final token = '${res['token'] ?? ''}';
      if (!mounted) return;
      setState(() => _token = token);
      NasSnack.show(context, tr('settings.mcp.genTokenHint'));
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, '$e', error: true);
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  Widget _codeBlock() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(NasTokens.spaceMd),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(NasTokens.radiusMd),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SelectableText(
          _config,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.4),
        ),
      ),
    );
  }

  Widget _chip(int index, String label) {
    return ChoiceChip(
      label: Text(label),
      selected: _tab == index,
      onSelected: (_) => setState(() => _tab = index),
    );
  }

  Widget _toolList(List<(String, String)> tools) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final t in tools)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 150,
                  child: Text(
                    t.$1,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  ),
                ),
                Expanded(child: Text(t.$2, style: TextStyle(color: muted))),
              ],
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final canGen = ApiSession.instance.isAdminFromServer;
    final tools = _tab == 0 ? _contentTools : _devTools;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final body = ListView(
      shrinkWrap: widget.embedded,
      physics: widget.embedded
          ? const NeverScrollableScrollPhysics()
          : null,
      padding: const EdgeInsets.all(NasTokens.spaceLg),
      children: [
          Text(tr('settings.mcp.subtitle'), style: TextStyle(color: muted)),
          const SizedBox(height: NasTokens.spaceLg),
          Row(
            children: [
              _chip(0, tr('settings.mcp.tabContent')),
              const SizedBox(width: NasTokens.spaceSm),
              _chip(1, tr('settings.mcp.tabDev')),
            ],
          ),
          const SizedBox(height: NasTokens.spaceMd),
          Text(_tab == 0 ? tr('settings.mcp.contentHint') : tr('settings.mcp.devHint')),
          const SizedBox(height: NasTokens.spaceMd),
          _codeBlock(),
          const SizedBox(height: NasTokens.spaceMd),
          Row(
            children: [
              FilledButton.icon(
                onPressed: _copy,
                icon: const Icon(Icons.copy_all_outlined, size: 18),
                label: Text(tr('settings.mcp.copy')),
              ),
              if (_tab == 0) ...[
                const SizedBox(width: NasTokens.spaceSm),
                OutlinedButton.icon(
                  onPressed: (!canGen || _generating) ? null : _genToken,
                  icon: const Icon(Icons.key_outlined, size: 18),
                  label: Text(tr('settings.mcp.genToken')),
                ),
              ],
            ],
          ),
          if (_tab == 0) ...[
            const SizedBox(height: NasTokens.spaceSm),
            Text(
              canGen ? tr('settings.mcp.genTokenHint') : '仅管理员可生成令牌',
              style: TextStyle(fontSize: 12, color: muted),
            ),
          ],
          const SizedBox(height: NasTokens.spaceLg),
          const Divider(height: 1),
          const SizedBox(height: NasTokens.spaceMd),
          Text(
            tr('settings.mcp.toolsTitle'),
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: NasTokens.spaceSm),
          _toolList(tools),
        ],
    );
    if (widget.embedded) return body;
    return Scaffold(
      appBar: AppBar(title: Text(tr('settings.mcp.title'))),
      body: body,
    );
  }
}
