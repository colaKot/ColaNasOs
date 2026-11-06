import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';

/// 相册助手：单轮问答。
///
/// 对齐参考实现的「相册助手」浮层：四个预设问题 + 自由输入，服务端把只读库统计
/// 塞进 system prompt。没配模型（或模型调不通）时自动退回本地统计规则，
/// 页面会如实标明当前回答来自哪条路径，不装作有 AI。
class PhotoAssistantPage extends StatefulWidget {
  const PhotoAssistantPage({super.key, this.embedded = true});

  final bool embedded;

  @override
  State<PhotoAssistantPage> createState() => _PhotoAssistantPageState();
}

class _PhotoAssistantPageState extends State<PhotoAssistantPage> {
  final _questionCtrl = TextEditingController();
  PhotoModelApi? _modelApi;
  PhotoAskResponse? _answer;
  bool _busy = false;
  String? _error;
  String _question = '';

  ApiClient get _client => ApiSession.instance.client;

  static const _presets = <String>[
    'photo.ask.q1',
    'photo.ask.q2',
    'photo.ask.q3',
    'photo.ask.q4',
  ];

  @override
  void initState() {
    super.initState();
    _loadModel();
  }

  @override
  void dispose() {
    _questionCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadModel() async {
    try {
      final api = await _client.photoAiModelApi();
      if (mounted) setState(() => _modelApi = api);
    } catch (_) {
      // 拿不到配置不挡问答：本地规则照样能答
    }
  }

  Future<void> _ask(String question) async {
    final q = question.trim();
    if (q.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _question = q;
      _answer = null;
      _error = null;
    });
    try {
      final res = await _client.photoAiAsk(body: PhotoAskBody(question: q));
      if (mounted) setState(() => _answer = res);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
      children: [
        _header(scheme),
        const SizedBox(height: 14),
        _modeBanner(scheme),
        const SizedBox(height: 14),
        Text(tr('photo.ask.try'), style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final key in _presets)
              ActionChip(
                label: Text(tr(key)),
                onPressed: _busy ? null : () => _ask(tr(key)),
              ),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _questionCtrl,
                decoration: InputDecoration(
                  labelText: tr('photo.ask.input'),
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                onSubmitted: _ask,
              ),
            ),
            const SizedBox(width: 10),
            FilledButton.icon(
              onPressed: _busy ? null : () => _ask(_questionCtrl.text),
              icon: const Icon(Icons.send, size: 16),
              label: Text(tr('photo.ask.send')),
            ),
          ],
        ),
        const SizedBox(height: 18),
        _result(scheme),
      ],
    );
  }

  Widget _header(ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.help_outline, color: scheme.primary, size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr('photo.ask.title'),
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Text(
                  tr('photo.ask.hint'),
                  style: TextStyle(fontSize: NasTokens.fontCaption, color: context.nasTextSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _modeBanner(ColorScheme scheme) {
    final ready = _modelApi?.hasKey == true && _modelApi!.enabled;
    final fallback = _answer?.mode == 'rule' && _answer!.reason.isNotEmpty &&
        _answer!.reason != 'no_model';
    final text = fallback
        ? tr('photo.ask.fallback')
        : ready
            ? tr('photo.ask.llmMode')
            : tr('photo.ask.ruleMode');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: ready && !fallback
            ? scheme.primaryContainer.withValues(alpha: 0.45)
            : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(
            ready && !fallback ? Icons.auto_awesome_outlined : Icons.info_outline,
            size: 16,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  Widget _result(ColorScheme scheme) {
    if (_busy) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null) {
      return _answerCard(scheme, '${tr('photo.ask.error')}: $_error');
    }
    final res = _answer;
    if (res == null || res.answer.isEmpty) {
      return _answerCard(scheme, tr('photo.ask.empty'));
    }
    return _answerCard(
      scheme,
      res.answer,
      question: _question,
      byModel: res.mode == 'llm',
    );
  }

  Widget _answerCard(
    ColorScheme scheme,
    String body, {
    String? question,
    bool byModel = false,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                byModel ? Icons.auto_awesome_outlined : Icons.analytics_outlined,
                size: 16,
                color: scheme.primary,
              ),
              const SizedBox(width: 6),
              Text(
                tr('photo.ask.answer'),
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          if (question != null && question.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              question,
              style: TextStyle(fontSize: 12, color: context.nasTextSecondary),
            ),
          ],
          const SizedBox(height: 10),
          SelectableText(body, style: const TextStyle(fontSize: 14, height: 1.5)),
        ],
      ),
    );
  }
}
