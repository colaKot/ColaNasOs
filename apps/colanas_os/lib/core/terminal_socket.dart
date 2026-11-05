import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'session.dart';

/// 交互式终端连接（SP3-10 二期）。
///
/// 内核端点：`/api/v1/system/terminal/ws?token=&cols=&rows=`（query token 因为
/// 浏览器 WebSocket 不能自定义请求头）；协议见 `src/modules/system/pty.ts`。
class TerminalSocket {
  TerminalSocket._(this._channel);

  final WebSocketChannel _channel;
  final StreamController<String> _output = StreamController<String>.broadcast();
  final StreamController<int?> _exit = StreamController<int?>.broadcast();
  bool _closed = false;

  /// PTY 原始输出（含 ANSI 控制序列，渲染层自行清理）
  Stream<String> get output => _output.stream;

  /// 会话结束（`code` 可能为 null：客户端主动关闭 / 空闲回收）
  Stream<int?> get exit => _exit.stream;

  static TerminalSocket connect({int cols = 100, int rows = 30}) {
    final httpBase = ApiSession.instance.baseUrl;
    final wsBase = httpBase.startsWith('https')
        ? httpBase.replaceFirst(RegExp('^https'), 'wss')
        : httpBase.replaceFirst(RegExp('^http'), 'ws');
    final token = Uri.encodeComponent(ApiSession.instance.token ?? '');
    final uri = Uri.parse(
      '$wsBase/api/v1/system/terminal/ws?token=$token&cols=$cols&rows=$rows',
    );
    final socket = TerminalSocket._(WebSocketChannel.connect(uri));
    socket._listen();
    return socket;
  }

  void _listen() {
    _channel.stream.listen(
      (raw) {
        Map<String, dynamic> msg;
        try {
          msg = jsonDecode(raw as String) as Map<String, dynamic>;
        } catch (_) {
          _output.add(raw as String);
          return;
        }
        switch (msg['type']) {
          case 'data':
            _output.add((msg['data'] ?? '').toString());
          case 'error':
            _output.add('\n[error] ${msg['message']}\n');
          case 'exit':
            _finish(msg['code'] as int?);
        }
      },
      onError: (Object e) {
        _output.add('\n[connection] $e\n');
        _finish(null);
      },
      onDone: () => _finish(null),
    );
  }

  void _finish(int? code) {
    if (_closed) return;
    _closed = true;
    _exit.add(code);
    _output.close();
    _exit.close();
  }

  void sendInput(String data) {
    if (_closed) return;
    _channel.sink.add(jsonEncode({'type': 'input', 'data': data}));
  }

  void resize(int cols, int rows) {
    if (_closed) return;
    _channel.sink.add(jsonEncode({'type': 'resize', 'cols': cols, 'rows': rows}));
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _channel.sink.close();
    } catch (_) {
      /* 已断开 */
    }
    if (!_output.isClosed) await _output.close();
    if (!_exit.isClosed) await _exit.close();
  }
}

/// 去掉 ANSI 转义（CSI / OSC / 单字符控制），终端输出直接用等宽文本渲染时不花屏。
/// 光标移动类序列会被丢掉，因此全屏 TUI（vim / top）不在支持范围。
String stripAnsi(String input) {
  return input
      .replaceAll(RegExp(r'\x1b\][^\x07]*(\x07|\x1b\\)'), '')
      .replaceAll(RegExp(r'\x1b\[[0-9;?]*[a-zA-Z]'), '')
      .replaceAll(RegExp(r'\x1b[()][A-Za-z0-9]'), '')
      .replaceAll(RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f]'), '');
}