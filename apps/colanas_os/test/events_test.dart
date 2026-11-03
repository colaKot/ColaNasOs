import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nas_core/nas_core.dart';

/// 可控的假传输：按 URL 返回预设响应，并记录调用次数。
class _FakeTransport implements Transport {
  _FakeTransport(this.handler);

  final ApiResponse Function(Uri url) handler;
  int calls = 0;

  @override
  Future<ApiResponse> send(
    String method,
    Uri url, {
    Map<String, String>? headers,
    List<int>? body,
  }) async {
    calls++;
    return handler(url);
  }

  @override
  void close() {}
}

ApiResponse _json(Object payload, {int status = 200}) => ApiResponse(
      statusCode: status,
      body: utf8.encode(jsonEncode(payload)),
      headers: const {'content-type': 'application/json'},
    );

ApiClient _client(Transport transport) => ApiClient(
      baseUrl: 'http://test.local',
      transport: transport,
      tokenProvider: () async => 'token',
    );

void main() {
  test('首轮只对齐游标，历史事件不派发', () async {
    final transport = _FakeTransport(
      (url) => _json({
        'items': [
          {'seq': 1, 'topic': 'scan.done', 'at': 1, 'data': {'domain': 'photo'}},
        ],
        'nextSeq': 1,
      }),
    );
    final poller = EventPoller(_client(transport), interval: const Duration(milliseconds: 30));
    final seen = <String>[];
    poller.addListener((topic, data) => seen.add('$topic:${data['domain']}'));

    poller.start();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    poller.stop();

    expect(transport.calls, greaterThanOrEqualTo(1));
    expect(poller.cursor, 1);
    expect(seen, isEmpty, reason: '首轮不应把历史事件派发给页面');
  });

  test('后续增量事件派发，且游标推进', () async {
    final transport = _FakeTransport((url) {
      final since = int.tryParse(url.queryParameters['since'] ?? '0') ?? 0;
      if (since == 0) {
        return _json({
          'items': [
            {'seq': 1, 'topic': 'scan.done', 'at': 1, 'data': {'domain': 'photo'}},
          ],
          'nextSeq': 1,
        });
      }
      if (since == 1) {
        return _json({
          'items': [
            {'seq': 2, 'topic': 'scan.done', 'at': 2, 'data': {'domain': 'video'}},
          ],
          'nextSeq': 2,
        });
      }
      return _json({'items': <Object>[], 'nextSeq': since});
    });

    final poller = EventPoller(_client(transport), interval: const Duration(milliseconds: 40));
    final seen = <String>[];
    poller.addListener((topic, data) => seen.add('$topic:${data['domain']}'));

    poller.start();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    poller.stop();

    expect(seen, contains('scan.done:video'));
    expect(poller.cursor, greaterThanOrEqualTo(2));
  });

  test('403 视为权限问题：停止轮询，不再重复请求', () async {
    final transport = _FakeTransport((url) => _json({'error': 'forbidden'}, status: 403));
    final poller = EventPoller(_client(transport), interval: const Duration(milliseconds: 30));

    poller.start();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final calls = transport.calls;
    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(poller.running, isFalse);
    expect(transport.calls, calls, reason: '403 后不应继续轮询');
  });

  test('stop 之后不再请求（即使 stop 发生在一次 tick 进行中）', () async {
    final transport = _FakeTransport(
      (url) => _json({'items': <Object>[], 'nextSeq': 0}),
    );
    final poller = EventPoller(_client(transport), interval: const Duration(milliseconds: 20));

    poller.start();
    await Future<void>.delayed(const Duration(milliseconds: 70));
    poller.stop();
    // stop 时可能正好有一轮请求在飞：等它落地再取基准值。
    // 原来 stop() 后立刻记 calls，那一轮稍晚返回就会让计数多 1 ——
    // 机器空闲时能过、并行跑 6 个验证作业时必挂（本用例因此长期偶发红）。
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final calls = transport.calls;
    await Future<void>.delayed(const Duration(milliseconds: 120));

    expect(poller.running, isFalse);
    expect(transport.calls, calls, reason: 'stop 后不应再排下一轮');
  });
}