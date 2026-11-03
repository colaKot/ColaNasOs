import 'dart:convert';
import 'dart:io';

import 'package:colanas_os/core/session.dart';
import 'package:colanas_os/features/book/book_page.dart';
import 'package:colanas_os/features/files/files_page.dart';
import 'package:colanas_os/features/music/music_page.dart';
import 'package:colanas_os/features/notes/notes_page.dart';
import 'package:colanas_os/features/photo/photo_page.dart';
import 'package:colanas_os/features/video/video_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

/// CL3-01 客户端性能基准：**首屏渲染耗时**（数据已就绪的一帧）+ **滚动步进耗时**。
///
/// 由 `node tool/bench/client.js` 驱动：
///   flutter test test/perf_test.dart --dart-define=PERF_DATA=`perf-data.json`
///
/// 为什么回放而不是真发 HTTP：`testWidgets` 跑在 FakeAsync 里，`IoTransport` 的
/// 30 s timeout 会变成 FakeTimer，真实 socket 回调永远等不到（实测挂死 3 s 后超时）。
/// 因此脚本先用**真实内核**把各页首屏接口的响应抓成 JSON，这里按路径回放：
/// 页面渲染、反序列化、布局都是真的，只有网络往返被移出测量范围（RTT 单独在脚本侧测）。
///
/// 口径：
///   - 首屏：`pumpWidget` → `NasLoading` 消失的那一帧（含反序列化 + 首屏布局）；
///   - 滚动：一次「拖动 160 px + pump 一帧」的平均耗时，反映 build/layout 的 CPU 成本；
///   - 无真实窗口 → 不含 GPU 光栅化与 vsync，不能直接换算 fps。
const _dataPath = String.fromEnvironment('PERF_DATA');
const _scrollSteps = 20;

void main() {
  late Map<String, Object?> routes;
  // 注册时就要知道要不要 skip，所以同步判断一次（不能放到 setUpAll 里）
  final hasData = _dataPath.isNotEmpty && File(_dataPath).existsSync();

  setUpAll(() {
    if (!hasData) return;
    final raw = File(_dataPath).readAsStringSync();
    routes = (jsonDecode(raw) as Map<String, dynamic>).cast<String, Object?>();
  });

  /// 没有 `PERF_DATA`（即没先跑 `npm run bench:client`）时跳过，
  /// 这样普通 `flutter test` 不会因为缺数据而红。
  const skipReason = '需要 PERF_DATA：先跑 npm run bench:client';

  final pages = <String, Widget Function()>{
    'photo': () => const PhotoPage(),
    'video': () => const VideoPage(),
    'music': () => const MusicPage(),
    'book': () => const BookPage(),
    'files': () => const FilesPage(),
    'notes': () => const NotesPage(),
  };

  for (final entry in pages.entries) {
    testWidgets(
      'client perf: ${entry.key}${hasData ? '' : '（跳过：$skipReason）'}',
      (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // 每个用例重建 client：回放真实服务端抓下来的响应
      ApiSession.instance.token = 'perf';
      ApiSession.instance.client = ApiClient(
        baseUrl: 'http://perf.local',
        transport: _ReplayTransport(routes),
        tokenProvider: () async => 'perf',
      );

      final clock = Stopwatch()..start();
      await tester.pumpWidget(MaterialApp(home: entry.value()));
      final reached = await _settle(tester);
      clock.stop();
      final firstMs = clock.elapsedMicroseconds / 1000;

      var scrolled = 0;
      final scrollClock = Stopwatch()..start();
      for (var i = 0; i < _scrollSteps; i++) {
        final scrollable = find.byType(Scrollable);
        if (scrollable.evaluate().isNotEmpty) {
          await tester.drag(scrollable.last, const Offset(0, -160), warnIfMissed: false);
          await tester.pump(const Duration(milliseconds: 16));
          scrolled += 1;
        }
      }
      scrollClock.stop();

      final payload = <String, Object?>{
        'page': entry.key,
        'ready': reached,
        'firstMs': double.parse(firstMs.toStringAsFixed(2)),
        'scrollSteps': scrolled,
        'scrollTotalMs': double.parse((scrollClock.elapsedMicroseconds / 1000).toStringAsFixed(2)),
        'scrollStepMs': scrolled == 0
            ? null
            : double.parse((scrollClock.elapsedMicroseconds / 1000 / scrolled).toStringAsFixed(2)),
      };
      // ignore: avoid_print
      print('PERF ${jsonEncode(payload)}');
      },
      skip: !hasData,
    );
  }
}

/// 一直 pump 到页面离开加载态（`NasLoading` 消失）；最多 2 秒。
/// 返回是否等到了数据态/空态，避免把「加载卡住」当成一次漂亮的成绩。
Future<bool> _settle(WidgetTester tester) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (DateTime.now().isBefore(deadline)) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1)));
    await tester.pump();
    if (find.byType(NasLoading).evaluate().isEmpty) {
      await tester.pump();
      return true;
    }
  }
  return false;
}

/// 按「路径」回放真实响应的 Transport（query 不参与匹配，取第一次抓到的响应）。
class _ReplayTransport implements Transport {
  _ReplayTransport(this.routes);

  final Map<String, Object?> routes;

  @override
  Future<ApiResponse> send(
    String method,
    Uri url, {
    Map<String, String>? headers,
    List<int>? body,
  }) async {
    final route = routes[url.path];
    if (route == null) {
      return ApiResponse(
        statusCode: 404,
        body: utf8.encode('{"error":"notFound","message":"no replay for ${url.path}"}'),
        headers: const {'content-type': 'application/json'},
      );
    }
    return ApiResponse(
      statusCode: 200,
      body: utf8.encode(jsonEncode(route)),
      headers: const {'content-type': 'application/json'},
    );
  }

  @override
  void close() {}
}