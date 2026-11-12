import 'dart:convert';
import 'dart:io';

import 'package:colanas_os/core/session.dart';
import 'package:colanas_os/features/blog/ai_news_page.dart';
import 'package:colanas_os/features/blog/blog_player_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nas_core/nas_core.dart';

/// AI 新闻页的**带数据**渲染测试。
///
/// 为什么要有：`app_nav_matrix_test` 只覆盖「连不上时走错误态」，而这一页最复杂的是
/// 有数据时的排版（8 个下拉、两列条数、播放条）。2026-11-05 的真实事故就是
/// 下拉放在 Row 里没有宽度约束，运行时抛 `RenderBox was not laid out: RenderParagraph`
/// 并伴随 CanvasKit `memory access out of bounds` —— 静态检查与错误态测试都抓不到。
///
/// 这里用一个假 Transport 喂真实 JSON，断言：
///   1. 宽屏时「国内综合」与「国际综合」在同一行（左国内 / 右国外）；
///   2. 窄屏时退化成单列（国际在下面）；
///   3. 滚动到底、点开一个下拉，都不抛异常。
class _FakeTransport implements Transport {
  _FakeTransport({this.modelInstalled = true});

  /// 一键下载卡片的状态：true = 已下载，false = 首启未下载
  final bool modelInstalled;

  static final Map<String, Object?> _settings = {
    'voice': 'default',
    'speed': 1.0,
    'counts': {
      'domesticGeneral': 2,
      'worldGeneral': 3,
      'domesticTech': 1,
      'worldTech': 0,
      'domesticAi': 2,
      'worldAi': 1,
      'domesticFinance': 1,
      'worldFinance': 2,
    },
    'planHour': 4,
    'planMinute': 0,
    'planEnabled': true,
    'apiProvider': 'deepseek',
    'apiKey': 'sk-demo',
    'apiBase': 'https://api.deepseek.com',
    'apiModel': 'deepseek-flash',
    'secondsPerItem': 90,
    'lastPlanDate': null,
    'llmEnabled': true,
    'webSearch': false,
    'llmReady': true,
    'ttsAvailable': true,
    'ttsReason': null,
  };

  static final List<Map<String, Object?>> _episodes = [
    {
      'id': 'ep1',
      'title': '2026年11月6日 AI 新闻',
      'voice': 'default',
      'speed': 1.0,
      'durationSec': 612.5,
      'sizeBytes': 5242880,
      'itemCount': 12,
      'status': 'done',
      'error': null,
      'parts': 12,
      'doneParts': 12,
      'sections': ['国内综合新闻', '国际综合新闻'],
      'headlines': ['标题一', '标题二'],
      'createdAt': 1794000000,
      'finishedAt': 1794000400,
    },
    {
      'id': 'ep0',
      'title': '2026年11月5日 AI 新闻',
      'voice': 'deep',
      'speed': 1.2,
      'durationSec': 0,
      'sizeBytes': 0,
      'itemCount': 8,
      'status': 'failed',
      'error': '一条新闻都没抓到：检查网络 / 代理设置',
      'parts': 0,
      'doneParts': 0,
      'sections': <String>[],
      'headlines': <String>[],
      'createdAt': 1793900000,
      'finishedAt': 1793900100,
    },
  ];

  @override
  Future<ApiResponse> send(
    String method,
    Uri url, {
    Map<String, String>? headers,
    List<int>? body,
  }) async {
    final path = url.path;
    Object payload;
    if (path.endsWith('/blog/settings')) {
      payload = _settings;
    } else if (path.endsWith('/blog/episodes')) {
      // 服务端已改为真分页，响应必须带 total / limit / offset
      payload = {
        'items': _episodes,
        'total': _episodes.length,
        'limit': 10,
        'offset': 0,
      };
    } else if (path.endsWith('/blog/voices')) {
      payload = {
        'items': [
          {'id': 'default', 'gender': 'female', 'builtin': true, 'label': ''},
          {'id': 'deep', 'gender': 'male', 'builtin': true, 'label': ''},
        ],
        'defaultVoice': 'default',
      };
    } else if (path.endsWith('/blog/mt/model')) {
      // 翻译模型是另一张卡片，同样有「一键下载」按钮；测试只关心语音模型卡片，
      // 这里固定返回「已安装」，避免按钮数量干扰断言。
      payload = {
        'installed': true,
        'downloading': false,
        'percent': 100.0,
        'phase': '',
        'task': 'done',
        'error': null,
        'modelDir': 'C:/data/mt/models/m2m100',
        'sizeMb': 512,
      };
    } else if (path.endsWith('/blog/tts/model')) {
      payload = {
        'installed': modelInstalled,
        'downloading': false,
        'percent': modelInstalled ? 100.0 : 0.0,
        'phase': modelInstalled ? '语音模型已下载' : '',
        'task': modelInstalled ? 'done' : 'idle',
        'error': null,
        'binReady': modelInstalled,
        'modelReady': modelInstalled,
        'modelDir': modelInstalled ? 'C:/data/tts/models/qwen3-tts' : null,
      };
    } else if (path.endsWith('/blog/script')) {
      payload = {
        'id': 'ep1',
        'title': '2026年11月6日 AI 新闻',
        'script': '各位听众早上好。\n今天的第一条新闻……',
        'items': [
          {
            'category': '国内综合新闻',
            'title': '示例新闻',
            'link': 'https://example.com/a',
            'source': '示例源',
          },
        ],
      };
    } else if (path.endsWith('/blog/warmup')) {
      payload = {'ready': true, 'available': true};
    } else if (path.endsWith('/blog/status')) {
      payload = {
        'id': 'ep1',
        'status': 'done',
        'parts': 12,
        'doneParts': 12,
        'error': null,
        'message': '',
      };
    } else {
      return ApiResponse(
        statusCode: 404,
        body: utf8.encode('{}'),
        headers: const {},
      );
    }
    return ApiResponse(
      statusCode: 200,
      body: utf8.encode(jsonEncode(payload)),
      headers: const {'content-type': 'application/json'},
    );
  }

  @override
  void close() {}
}

Future<void> _pumpPage(
  WidgetTester tester, {
  double width = 1280,
  bool modelInstalled = true,
}) async {
  tester.view.physicalSize = Size(width, 1800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  ApiSession.instance.client = ApiClient(
    baseUrl: 'http://127.0.0.1:9',
    transport: _FakeTransport(modelInstalled: modelInstalled),
    tokenProvider: () async => 'test-token',
  );
  await tester.pumpWidget(
    const MaterialApp(home: Scaffold(body: AiNewsPage())),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() {
    final file = File('../../packages/nas_core/lib/l10n/zh-CN.json');
    final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final messages = (json['messages'] as Map).map(
      (k, v) => MapEntry(k.toString(), '$v'),
    );
    I18n.instance.useForTest('zh-CN', messages);
  });

  setUp(() {
    ApiSession.instance.baseUrl = 'http://127.0.0.1:9';
    ApiSession.instance.client = ApiClient(
      baseUrl: 'http://127.0.0.1:9',
      transport: _FakeTransport(),
      tokenProvider: () async => 'test-token',
    );
  });

  testWidgets('模型已下载：卡片常驻显示已下载，不再给下载按钮', (tester) async {
    await _pumpPage(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('语音模型'), findsOneWidget);
    expect(find.text('已下载 · 可以离线合成'), findsOneWidget);
    expect(find.text('一键下载'), findsNothing);
  });

  testWidgets('首启未下载：显示一键下载按钮', (tester) async {
    await _pumpPage(tester, modelInstalled: false);

    expect(tester.takeException(), isNull);
    expect(find.text('一键下载'), findsOneWidget);
    expect(find.text('已下载 · 可以离线合成'), findsNothing);
  });

  testWidgets('宽屏：条数两列，左边国内 / 右边国外', (tester) async {
    await _pumpPage(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('新闻条数'), findsOneWidget);

    final domestic = tester.getCenter(find.text('国内综合'));
    final world = tester.getCenter(find.text('国际综合'));
    // 同一行、且国际在右侧
    expect(world.dy, moreOrLessEquals(domestic.dy, epsilon: 4));
    expect(world.dx, greaterThan(domestic.dx));

    // 经济类在各自列的第四行（同列 dy 递增）
    final finance = tester.getCenter(find.text('国内财经'));
    expect(finance.dy, greaterThan(domestic.dy));
  });

  testWidgets('窄屏：退化成单列，国际排在下面', (tester) async {
    await _pumpPage(tester, width: 420);

    expect(tester.takeException(), isNull);
    final domestic = tester.getCenter(find.text('国内综合'));
    final world = tester.getCenter(find.text('国际综合'));
    expect(world.dy, greaterThan(domestic.dy));
  });

  testWidgets('滚动到底 + 打开条数下拉，不抛异常', (tester) async {
    await _pumpPage(tester);
    expect(tester.takeException(), isNull);

    // 已生成的音频列表在最上面（2026-11-06 调整）：进页就该看到，不用滚
    expect(find.text('已生成音频'), findsOneWidget);
    expect(find.text('2026年11月6日 AI 新闻'), findsOneWidget);

    // 滚到底部：生成设置区在最下面，确认两列配置卡片都能画出来
    await tester.drag(find.byType(ListView).first, const Offset(0, -1600));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('新闻条数'), findsOneWidget);

    // 打开第一个下拉（曾经的崩溃点：无宽度约束的 DropdownButton）
    await tester.tap(find.byType(DropdownButton<int>).first);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('条'), findsWidgets);
    // 关掉菜单，避免 pending 的遮罩影响后续断言
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
  });

  testWidgets('音频列表：宽屏一行两列，窄屏堆成一列', (tester) async {
    await _pumpPage(tester);
    expect(tester.takeException(), isNull);

    final newest = tester.getCenter(find.text('2026年11月6日 AI 新闻'));
    final older = tester.getCenter(find.text('2026年11月5日 AI 新闻'));
    // 同一行、较新的在左侧
    expect(older.dy, moreOrLessEquals(newest.dy, epsilon: 4));
    expect(newest.dx, lessThan(older.dx));

    await _pumpPage(tester, width: 420);
    expect(tester.takeException(), isNull);
    final narrowNewest = tester.getCenter(find.text('2026年11月6日 AI 新闻'));
    final narrowOlder = tester.getCenter(find.text('2026年11月5日 AI 新闻'));
    expect(narrowOlder.dy, greaterThan(narrowNewest.dy));
  });

  testWidgets('音频卡片：宽屏三个按钮，窄屏把重新生成与删除收进更多', (tester) async {
    await _pumpPage(tester);
    expect(tester.takeException(), isNull);
    expect(find.byTooltip('查看文稿'), findsNWidgets(2));
    expect(find.byTooltip('重新合成音频'), findsNWidgets(2));
    expect(find.byTooltip('删除'), findsNWidgets(2));

    await _pumpPage(tester, width: 420);
    expect(tester.takeException(), isNull);
    expect(find.byTooltip('查看文稿'), findsNWidgets(2));
    expect(find.byTooltip('重新合成音频'), findsNothing);
    expect(find.byTooltip('删除'), findsNothing);
    expect(find.byTooltip('更多'), findsNWidgets(2));
  });

  testWidgets('查看文稿：正文与底部引用链接都能看到', (tester) async {
    await _pumpPage(tester);
    await tester.tap(find.byTooltip('查看文稿').first);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('播报文稿'), findsOneWidget);
    expect(find.textContaining('各位听众早上好'), findsOneWidget);
    expect(find.text('引用链接'), findsOneWidget);
    expect(find.text('示例新闻'), findsOneWidget);
  });

  testWidgets('手机更多菜单：队列操作与重新生成 / 删除都在', (tester) async {
    await _pumpPage(tester, width: 420);
    await tester.tap(find.byTooltip('更多').first);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('加入播放列表'), findsOneWidget);
    expect(find.text('下一期播放'), findsOneWidget);
    expect(find.text('重新合成音频'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);
  });

  testWidgets('全屏播放页：没播放时给空提示，播放列表弹层也能打开', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: BlogPlayerPage()));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('还没有播放的期次'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.queue_music));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('播放列表'), findsOneWidget);
    expect(find.text('播放列表是空的，先点一期播放吧'), findsOneWidget);
  });

  testWidgets('老库残留 Kokoro 音色 id：不崩且下拉 value 回到有效项', (tester) async {
    // 2026-11-06 真实事故：换 Qwen3-TTS 后音色改为磁盘扫描，老库里仍是 zf_001，
    // DropdownButton 的 value 不在 items 里直接 assert 崩溃，整个播客页打不开。
    _FakeTransport._settings['voice'] = 'zf_001';
    addTearDown(() => _FakeTransport._settings['voice'] = 'default');

    await _pumpPage(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('zf_001'), findsNothing);
    for (final element in find.byType(DropdownButton<String>).evaluate()) {
      final d = element.widget as DropdownButton<String>;
      final ids = (d.items ?? const []).map((i) => i.value).toSet();
      expect(d.value == null || ids.contains(d.value), isTrue);
    }
  });
}
