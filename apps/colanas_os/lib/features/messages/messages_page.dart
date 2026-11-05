import 'package:flutter/material.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';

/// 站内消息：未读高亮、点击已读、全部已读。
class MessagesPage extends StatefulWidget {
  const MessagesPage({super.key});

  @override
  State<MessagesPage> createState() => _MessagesPageState();
}

class _MessagesPageState extends State<MessagesPage> {
  bool _loading = true;
  String? _error;
  int _unread = 0;
  bool _unreadOnly = false;
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
      final res = await ApiSession.instance.client.messageList(
        unreadOnly: _unreadOnly,
      );
      final unread = await ApiSession.instance.client.messageUnread();
      if (!mounted) return;
      setState(() {
        _items = (res['items'] as List<dynamic>? ?? const [])
            .map((e) => (e as Map).cast<String, dynamic>())
            .toList();
        _unread = (unread['unread'] as num?)?.toInt() ?? 0;
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

  Future<void> _read(String id) async {
    try {
      await ApiSession.instance.client.messageRead(body: {'id': id});
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr('messages.markFailed', {'error': '$e'}))));
    }
  }

  Future<void> _readAll() async {
    try {
      await ApiSession.instance.client.messageReadAll();
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr('common.errorWith', {'error': '$e'}))));
    }
  }

  IconData _icon(String level) {
    switch (level) {
      case 'warn':
        return Icons.warning_amber_rounded;
      case 'error':
        return Icons.error_outline;
      default:
        return Icons.notifications_none;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_unread > 0 ? tr('messages.titleUnread', {'count': '$_unread'}) : tr('ui.messages.001')),
        actions: [
          IconButton(
            icon: Icon(
              _unreadOnly
                  ? Icons.mark_email_unread_outlined
                  : Icons.all_inbox_outlined,
            ),
            tooltip: _unreadOnly
                ? tr('ui.messages.002')
                : tr('ui.messages.003'),
            onPressed: () {
              setState(() => _unreadOnly = !_unreadOnly);
              _load();
            },
          ),
          IconButton(
            icon: const Icon(Icons.done_all),
            tooltip: tr('ui.messages.004'),
            onPressed: _readAll,
          ),
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Text(_error!, style: TextStyle(color: context.nasDanger)),
            )
          : _items.isEmpty
          ? Center(child: Text(tr('ui.messages.005')))
          : ListView.separated(
              itemCount: _items.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final m = _items[i];
                final unread = m['readAt'] == null;
                final id = m['id'] as String? ?? '';
                return ListTile(
                  leading: Icon(
                    _icon(m['level'] as String? ?? 'info'),
                    color: unread ? const Color(NasTokens.colorPrimary) : null,
                  ),
                  title: Text(
                    m['title'] as String? ?? '',
                    style: TextStyle(
                      fontWeight: unread ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                  subtitle: Text(
                    m['body'] as String? ?? '',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: unread
                      ? IconButton(
                          icon: const Icon(Icons.mark_email_read_outlined),
                          tooltip: tr('ui.messages.006'),
                          onPressed: id.isEmpty ? null : () => _read(id),
                        )
                      : null,
                );
              },
            ),
    );
  }
}
