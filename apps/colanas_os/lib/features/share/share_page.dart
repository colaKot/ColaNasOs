import 'package:flutter/material.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';

/// 分享链接管理：创建（可选过期/密码）→ 列表 → 撤销。
class SharePage extends StatefulWidget {
  const SharePage({super.key});

  @override
  State<SharePage> createState() => _SharePageState();
}

class _SharePageState extends State<SharePage> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _items = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ApiSession.instance.client.shareList();
      if (!mounted) return;
      setState(() {
        _items = (res['items'] as List<dynamic>? ?? const [])
            .map((e) => (e as Map).cast<String, dynamic>())
            .toList();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _create() async {
    final pathCtrl = TextEditingController(text: '/');
    final pwCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('ui.share.001')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: pathCtrl,
              decoration: InputDecoration(labelText: tr('ui.share.002')),
            ),
            const SizedBox(height: NasTokens.spaceMd),
            TextField(
              controller: pwCtrl,
              decoration: InputDecoration(labelText: tr('ui.share.003')),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('ui.accounts.006')),
          ),
        ],
      ),
    );
    if (ok != true) return;

    try {
      final created = await ApiSession.instance.client.shareCreate(
        body: {
          'path': pathCtrl.text.trim(),
          if (pwCtrl.text.trim().isNotEmpty) 'password': pwCtrl.text.trim(),
        },
      );
      if (!mounted) return;
      final url = '${ApiSession.instance.baseUrl}${created['url']}';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: SelectableText(tr('share.created', {'url': url}))));
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr('common.createFailed', {'error': '$e'}))));
    }
  }

  Future<void> _revoke(String id) async {
    try {
      await ApiSession.instance.client.shareRevoke(body: {'id': id});
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr('share.revokeFailed', {'error': '$e'}))));
    }
  }

  String _expiry(Map<String, dynamic> item) {
    final at = item['expiresAt'];
    if (at == null) return tr('ui.share.h409752');
    final ts = (at as num).toInt();
    final dt = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
    return tr('share.expiry', {'date': '${dt.toLocal()}'}).split('.').first;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('ui.share.004')),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
          IconButton(
            icon: const Icon(Icons.add_link),
            tooltip: tr('ui.share.005'),
            onPressed: _create,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(NasTokens.spaceLg),
                child: Text(
                  _error!,
                  style: TextStyle(color: context.nasDanger),
                ),
              ),
            )
          : _items.isEmpty
          ? Center(child: Text(tr('ui.share.006')))
          : ListView.separated(
              itemCount: _items.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final item = _items[i];
                final id = item['id'] as String? ?? '';
                return ListTile(
                  leading: Icon(
                    item['hasPassword'] == true ? Icons.lock : Icons.link,
                  ),
                  title: Text(item['path'] as String? ?? ''),
                  subtitle: Text(
                    tr('share.summary', {'expires': _expiry(item), 'downloads': '${item['downloads'] ?? 0}'}),
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.link_off),
                    tooltip: tr('ui.photo.015'),
                    onPressed: id.isEmpty ? null : () => _revoke(id),
                  ),
                );
              },
            ),
    );
  }
}
