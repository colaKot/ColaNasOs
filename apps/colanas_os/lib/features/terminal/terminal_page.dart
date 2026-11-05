import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import '../../core/terminal_socket.dart';

/// 终端（SP3-10 二期）。
///
/// - 桌面 / 移动：**完整 PTY**（`/api/v1/system/terminal/ws`，管理员 scope `system:write`），
///   单用户 2 个会话、30 分钟空闲回收、512 KB/s 输出限流；
/// - Web：浏览器拿不到 PTY，降级为原来的**只读白名单命令**（`/system/exec`）。
///
/// 全屏 TUI（vim / top）不在支持范围：客户端用等宽文本渲染，ANSI 光标移动会被丢弃。
class TerminalPage extends StatelessWidget {
  const TerminalPage({super.key});

  @override
  Widget build(BuildContext context) {
    return kIsWeb ? const _RestrictedTerminal() : const _PtyTerminal();
  }
}

// ------------------------------------------------------------------ PTY

class _PtyTerminal extends StatefulWidget {
  const _PtyTerminal();

  @override
  State<_PtyTerminal> createState() => _PtyTerminalState();
}

class _PtyTerminalState extends State<_PtyTerminal> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final StringBuffer _buffer = StringBuffer();

  TerminalSocket? _socket;
  StreamSubscription<String>? _outSub;
  StreamSubscription<int?>? _exitSub;
  Timer? _flushTimer;
  bool _dirty = false;
  bool _connected = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _connect();
  }

  @override
  void dispose() {
    _flushTimer?.cancel();
    _outSub?.cancel();
    _exitSub?.cancel();
    _socket?.close();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _connect() {
    _outSub?.cancel();
    _exitSub?.cancel();
    _socket?.close();
    _buffer.clear();
    setState(() {
      _connected = false;
      _error = null;
    });

    try {
      final socket = TerminalSocket.connect();
      _socket = socket;
      _outSub = socket.output.listen((chunk) {
        _buffer.write(stripAnsi(chunk));
        _scheduleFlush();
      });
      _exitSub = socket.exit.listen((code) {
        if (!mounted) return;
        setState(() {
          _connected = false;
          if (code != null && code != 0) _error = 'exit $code';
        });
      });
      setState(() {
        _connected = true;
        _buffer.write(
          tr('ui.terminal.005'),
        );
        _buffer.write('\n');
      });
      _scheduleFlush();
    } catch (e) {
      setState(() {
        _connected = false;
        _error = '$e';
      });
    }
  }

  void _scheduleFlush() {
    if (_dirty) return;
    _dirty = true;
    _flushTimer?.cancel();
    _flushTimer = Timer(const Duration(milliseconds: 120), () {
      _dirty = false;
      if (!mounted) return;
      setState(() {});
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    });
  }

  void _send(String data) {
    final socket = _socket;
    if (socket == null || data.isEmpty) return;
    socket.sendInput(data);
  }

  void _submit() {
    final text = _input.text;
    if (text.isEmpty) return;
    _send('$text\r');
    _input.clear();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Text(tr('ui.terminal.001')),
            const SizedBox(width: NasTokens.spaceSm),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: (_connected ? scheme.primary : scheme.outline)
                    .withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                _connected ? tr('ui.terminal.005') : tr('ui.terminal.006'),
                style: TextStyle(
                  fontSize: NasTokens.fontMicro,
                  color: _connected ? scheme.primary : scheme.outline,
                ),
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.link),
            tooltip: tr('ui.terminal.004'),
            onPressed: _connect,
          ),
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined),
            tooltip: tr('ui.terminal.002'),
            onPressed: () => setState(_buffer.clear),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Container(
              width: double.infinity,
              color: const Color(0xFF0B0F14),
              child: SingleChildScrollView(
                controller: _scroll,
                padding: const EdgeInsets.all(NasTokens.spaceMd),
                child: SelectableText(
                  _buffer.toString(),
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: NasTokens.fontMono,
                    height: 1.45,
                    color: Color(0xFFD6E2EE),
                  ),
                ),
              ),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: NasTokens.spaceMd,
                vertical: NasTokens.spaceXs,
              ),
              child: Text(
                _error!,
                style: TextStyle(
                  fontSize: NasTokens.fontCaption,
                  color: context.nasDanger,
                ),
              ),
            ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(NasTokens.spaceSm),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    autofocus: true,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: NasTokens.fontMono,
                    ),
                    decoration: const InputDecoration(
                      hintText: 'ls -la',
                      isDense: true,
                    ),
                    onSubmitted: (_) => _submit(),
                  ),
                ),
                const SizedBox(width: NasTokens.spaceXs),
                IconButton(
                  tooltip: 'Ctrl+C',
                  icon: const Icon(Icons.stop_circle_outlined),
                  onPressed: () => _send('\x03'),
                ),
                const SizedBox(width: NasTokens.spaceXs),
                FilledButton.icon(
                  onPressed: _submit,
                  icon: const Icon(Icons.play_arrow),
                  label: Text(tr('ui.photo.008')),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------- Web：受限命令

/// Web 端的只读白名单终端（能力矩阵里 terminal 在 web 为 `none`，这里保留降级入口）。
class _RestrictedTerminal extends StatefulWidget {
  const _RestrictedTerminal();

  @override
  State<_RestrictedTerminal> createState() => _RestrictedTerminalState();
}

class _RestrictedTerminalState extends State<_RestrictedTerminal> {
  static const _allow = [
    'pwd',
    'ls',
    'dir',
    'df',
    'free',
    'ps',
    'tasklist',
    'uname',
    'whoami',
  ];

  final TextEditingController _input = TextEditingController();
  final List<(String, String)> _log = [];
  bool _busy = false;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final raw = _input.text.trim();
    if (raw.isEmpty || _busy) return;
    final parts = raw.split(RegExp(r'\s+'));
    final command = parts.first;
    final args = parts.skip(1).toList();

    if (!_allow.contains(command)) {
      setState(() => _log.add(('\$ $raw', tr('terminal.denied', {'allow': _allow.join(' / ')}))));
      return;
    }

    setState(() {
      _busy = true;
      _log.add(('\$ $raw', tr('ui.terminal.h666b4a')));
    });
    final index = _log.length - 1;
    try {
      final res = await ApiSession.instance.client.systemExec(
        body: {'command': command, 'args': args},
      );
      if (!mounted) return;
      final stdout = (res['stdout'] ?? '').toString();
      final stderr = (res['stderr'] ?? '').toString();
      final code = res['code'];
      final ms = res['ms'];
      final text = [
        if (stdout.isNotEmpty) stdout,
        if (stderr.isNotEmpty) stderr,
        '(exit $code, $ms ms)',
      ].join('\n');
      setState(() {
        _log[index] = ('\$ $raw', text);
        _busy = false;
        _input.clear();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _log[index] = ('\$ $raw', tr('terminal.failed', {'error': '$e'}));
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('ui.terminal.001')),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined),
            tooltip: tr('ui.terminal.002'),
            onPressed: _log.isEmpty ? null : () => setState(_log.clear),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(NasTokens.spaceMd),
            child: Text(
              tr('ui.terminal.007'),
              style: TextStyle(
                fontSize: NasTokens.fontCaption,
                color: context.nasTextSecondary,
              ),
            ),
          ),
          Expanded(
            child: _log.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(NasTokens.spaceLg),
                      child: Text(
                        tr('terminal.allowHint', {'allow': _allow.join(' / ')}),
                        textAlign: TextAlign.center,
                        style: TextStyle(color: context.nasTextSecondary),
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(NasTokens.spaceMd),
                    itemCount: _log.length,
                    separatorBuilder: (_, _) =>
                        const SizedBox(height: NasTokens.spaceMd),
                    itemBuilder: (context, i) {
                      final (cmd, out) = _log[i];
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            cmd,
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: NasTokens.fontMono,
                              color: context.nasTextSecondary,
                            ),
                          ),
                          const SizedBox(height: NasTokens.spaceXs),
                          SelectableText(
                            out,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: NasTokens.fontMono,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(NasTokens.spaceSm),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: NasTokens.fontMono,
                    ),
                    decoration: InputDecoration(
                      hintText: tr('ui.terminal.003'),
                      isDense: true,
                    ),
                    onSubmitted: (_) => _run(),
                  ),
                ),
                const SizedBox(width: NasTokens.spaceSm),
                FilledButton.icon(
                  onPressed: _busy ? null : _run,
                  icon: const Icon(Icons.play_arrow),
                  label: Text(tr('ui.photo.008')),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}