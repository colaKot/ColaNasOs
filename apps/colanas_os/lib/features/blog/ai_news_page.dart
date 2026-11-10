import 'dart:async';
import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/audio_focus.dart';
import '../../core/external_link.dart';
import '../../core/session.dart';
import '../../core/settings_store.dart';
import 'blog_player.dart';
import 'blog_player_page.dart';
import 'blog_queue_sheet.dart';

/// 8 类新闻。顺序与「播报顺序」一致，也是服务端稿件里的顺序。
const List<({String key, String labelKey})> _kCategories = [
  (key: 'domesticGeneral', labelKey: 'blog.cat.domesticGeneral'),
  (key: 'worldGeneral', labelKey: 'blog.cat.worldGeneral'),
  (key: 'domesticTech', labelKey: 'blog.cat.domesticTech'),
  (key: 'worldTech', labelKey: 'blog.cat.worldTech'),
  (key: 'domesticAi', labelKey: 'blog.cat.domesticAi'),
  (key: 'worldAi', labelKey: 'blog.cat.worldAi'),
  (key: 'domesticFinance', labelKey: 'blog.cat.domesticFinance'),
  (key: 'worldFinance', labelKey: 'blog.cat.worldFinance'),
];

/// 内置音色 id → 文案键。音色来自参考音频，用户上传的音色直接用文件名做标签。
const Map<String, String> _kBuiltinVoiceKeys = {
  'default': 'blog.voice.default',
  'warm': 'blog.voice.warm',
  'deep': 'blog.voice.deep',
};

/// 眼睛（明文 / 密文）状态存客户端本地：用户在这台机器上看过明文，下次还是明文。
const String _kKeyVisible = 'blog.apiKeyVisible';

/// AI 新闻：选条数 → 选音色（可试听）→ 倍速与预计时长 → API Key → 生成计划 → 已生成列表。
///
/// 所有设置都存服务端（同一台 NAS 换设备一致），只有「眼睛」的展开状态存本机。
class AiNewsPage extends StatefulWidget {
  const AiNewsPage({super.key});

  @override
  State<AiNewsPage> createState() => _AiNewsPageState();
}

class _AiNewsPageState extends State<AiNewsPage> {
  bool _loading = true;
  String? _error;

  BlogSettingsResponse? _settings;
  /// 只存**服务端返回的当前页**，不再一次拉 200 期在前端切片
  List<BlogEpisodeItem> _episodes = const [];
  int _total = 0;
  static const int _perPage = 20;
  int _page = 0;

  // ---- 编辑态（保存前只改本地）
  List<BlogVoiceItem> _voices = const [];
  String _voice = 'default';
  double _speed = 1;
  final Map<String, int> _counts = {
    for (final c in _kCategories) c.key: 0,
  };
  bool _planEnabled = true;
  int _planHour = 4;
  int _planMinute = 0;
  String _apiProvider = 'deepseek';
  bool _llmEnabled = true;
  bool _webSearch = false;
  bool _ttsAvailable = true;
  String? _ttsReason;

  // ---- 语音模型一键下载（状态来自服务端实时探测磁盘，不在本地存「已下载」）
  BlogTtsModelResponse? _model;
  Timer? _modelPoll;
  bool _modelBusy = false;

  // ---- 本地翻译模型（Qwen3-1.7B GGUF）：与语音模型同样的「实时探测磁盘」口径
  BlogMtModelResponse? _mt;
  Timer? _mtPoll;
  bool _mtBusy = false;

  final TextEditingController _keyCtrl = TextEditingController();
  final TextEditingController _baseCtrl = TextEditingController();
  final TextEditingController _modelCtrl = TextEditingController();

  bool _keyVisible = false;
  bool _saving = false;
  bool _previewing = false;

  // ---- 生成
  String? _generatingId;
  BlogStatusResponse? _genStatus;
  Timer? _poll;

  /// 全局单例：页面重建 / 切模块不会停播，手机上熄屏、最小化也能继续听。
  final BlogPlayer _player = BlogPlayer.instance;
  Player? _previewPlayer;

  @override
  void initState() {
    super.initState();
    _keyVisible = SettingsStore.instance.getBool(_kKeyVisible) ?? false;
    _load();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _modelPoll?.cancel();
    _mtPoll?.cancel();
    // 不要 dispose _player：它是全局单例，切页面 / 熄屏 / 最小化都要继续播。
    // 试听是页内短音频，销毁前必须**先同步 pause**，否则 Web 端那个 <video>
    // 元素会留在 globalContext 里继续出声（以前「刷新还在播」就是这么来的）。
    unawaited(_disposePreview());
    _keyCtrl.dispose();
    _baseCtrl.dispose();
    _modelCtrl.dispose();
    super.dispose();
  }

  Future<void> _disposePreview() async {
    final p = _previewPlayer;
    _previewPlayer = null;
    if (p == null) return;
    AudioFocus.instance.release(p);
    try {
      await p.pause();
      await p.dispose();
    } catch (_) {
      // 已经销毁过就算了
    }
  }

  // ------------------------------------------------------------------ 数据

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final client = ApiSession.instance.client;
      final s = await client.blogSettings();
      // 服务端真分页：一次只拿当前页（新的在前）
      final episodes = await client.blogEpisodes(
        limit: _perPage,
        offset: _page * _perPage,
      );
      // 下载状态单独兜底：老版本服务端没有这个接口时，页面其余部分照常可用
      BlogTtsModelResponse? model;
      try {
        model = await client.blogTtsModel();
      } catch (_) {
        model = null;
      }
      // 翻译模型同样兜底：老服务端没有这个接口时，页面其余部分照常可用
      BlogMtModelResponse? mt;
      try {
        mt = await client.blogMtModel();
      } catch (_) {
        mt = null;
      }
      // 音色清单来自服务端磁盘扫描（内置 3 段 + 用户上传），不能在前端写死
      final voices = await client.blogVoices().catchError(
            (_) => const BlogVoiceListResponse(items: [], defaultVoice: 'default'),
          );
      if (!mounted) return;
      setState(() {
        _applySettings(s);
        _voices = voices.items;
        _normalizeVoice();
        _episodes = episodes.items;
        _total = episodes.total;
        _model = model;
        _mt = mt;
        _loading = false;
      });
      // 刷新页面时下载还在跑（下载是服务端后台进程），继续接上进度
      if (model?.downloading == true) _startModelPolling();
      if (mt?.downloading == true) _startMtPolling();
      // 正在生成的那一期：刷新页面后继续显示进度
      final running = episodes.items.where((e) => e.status == 'pending' || e.status == 'running');
      if (running.isNotEmpty) {
        _generatingId = running.first.id;
        _startPolling();
      }
      if (s.ttsAvailable) {
        // 预热：跑一句极短的合成，把 Vulkan 着色器编译挪到进入页面时（只做一次）
        unawaited(
          client.blogWarmup().then<void>((_) {}).catchError((_) {}),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  void _applySettings(BlogSettingsResponse s) {
    _settings = s;
    _voice = s.voice;
    _speed = s.speed;
    _planEnabled = s.planEnabled;
    _planHour = s.planHour;
    _planMinute = s.planMinute;
    _apiProvider = switch (s.apiProvider) {
      'openai' => 'openai',
      'deepseek' => 'deepseek',
      'bailian' => 'bailian',
      _ => 'custom',
    };
    _llmEnabled = s.llmEnabled;
    _webSearch = s.webSearch;
    _ttsAvailable = s.ttsAvailable;
    _ttsReason = s.ttsReason;
    _keyCtrl.text = s.apiKey;
    _baseCtrl.text = s.apiBase;
    _modelCtrl.text = s.apiModel;
    for (final c in _kCategories) {
      _counts[c.key] = switch (c.key) {
        'domesticGeneral' => s.counts.domesticGeneral,
        'worldGeneral' => s.counts.worldGeneral,
        'domesticTech' => s.counts.domesticTech,
        'worldTech' => s.counts.worldTech,
        'domesticAi' => s.counts.domesticAi,
        'worldAi' => s.counts.worldAi,
        'domesticFinance' => s.counts.domesticFinance,
        _ => s.counts.worldFinance,
      };
    }
  }

  BlogCounts _countsModel() => BlogCounts(
        domesticGeneral: _counts['domesticGeneral'] ?? 0,
        worldGeneral: _counts['worldGeneral'] ?? 0,
        domesticTech: _counts['domesticTech'] ?? 0,
        worldTech: _counts['worldTech'] ?? 0,
        domesticAi: _counts['domesticAi'] ?? 0,
        worldAi: _counts['worldAi'] ?? 0,
        domesticFinance: _counts['domesticFinance'] ?? 0,
        worldFinance: _counts['worldFinance'] ?? 0,
      );

  int get _totalItems => _counts.values.fold(0, (a, b) => a + b);

  /// 预计时长 = 条数 × 每条 90 秒 ÷ 倍速（90 秒来自服务端 `secondsPerItem`，与 TTS 稿面一致）
  String get _estimate {
    final perItem = _settings?.secondsPerItem ?? 90;
    final seconds = (_totalItems * perItem / _speed).round();
    return tr('blog.duration', {
      'minutes': seconds ~/ 60,
      'seconds': seconds % 60,
    });
  }

  Future<void> _reloadEpisodes() async => _fetchPage(_page);

  Future<void> _fetchPage(int page) async {
    try {
      final res = await ApiSession.instance.client.blogEpisodes(
        limit: _perPage,
        offset: page * _perPage,
      );
      if (!mounted) return;
      setState(() {
        _episodes = res.items;
        _total = res.total;
      });
    } catch (_) {
      // 列表刷新失败不打断当前操作
    }
  }

  Future<void> _goPage(int page) async {
    if (page < 0 || page == _page) return;
    setState(() => _page = page);
    await _fetchPage(page);
  }

  // ------------------------------------------------------------------ 语音模型一键下载

  /// 下载进程跑在服务端，页面只负责起 / 停与轮询。
  /// 「已下载」不存客户端：每次 status 都是服务端现场探测磁盘，删了文件也会变回未下载。
  void _startModelPolling() {
    _modelPoll?.cancel();
    _modelPoll = Timer.periodic(const Duration(seconds: 1), (_) => _refreshModel());
  }

  Future<void> _refreshModel() async {
    try {
      final m = await ApiSession.instance.client.blogTtsModel();
      if (!mounted) return;
      setState(() => _model = m);
      if (!m.downloading) {
        _modelPoll?.cancel();
        _modelPoll = null;
        // 刚下完：设置里的 ttsAvailable 是引擎算的，重新拉一次才能放开「立即生成」
        if (m.installed) await _refreshAfterInstall();
      }
    } catch (_) {
      // 网络抖动：下一轮再试
    }
  }

  Future<void> _refreshAfterInstall() async {
    try {
      final client = ApiSession.instance.client;
      final s = await client.blogSettings();
      final voices = await client.blogVoices();
      if (!mounted) return;
      setState(() {
        _applySettings(s);
        _voices = voices.items;
        _normalizeVoice();
      });
      if (s.ttsAvailable) {
        unawaited(client.blogWarmup().then<void>((_) {}).catchError((_) {}));
      }
    } catch (_) {
      // 刷新失败不影响「已下载」本身，用户点刷新按钮还能重来
    }
  }

  Future<void> _downloadModel() async {
    if (_modelBusy) return;
    setState(() => _modelBusy = true);
    try {
      final m = await ApiSession.instance.client.blogTtsModelDownload();
      if (!mounted) return;
      setState(() => _model = m);
      if (m.downloading) {
        _startModelPolling();
      } else if (m.installed) {
        await _refreshAfterInstall();
      }
    } catch (e) {
      if (mounted) {
        NasSnack.show(context, tr('blog.tts.model.failed', {'error': '$e'}), error: true);
      }
    } finally {
      if (mounted) setState(() => _modelBusy = false);
    }
  }

  Future<void> _cancelModel() async {
    _modelPoll?.cancel();
    _modelPoll = null;
    try {
      final m = await ApiSession.instance.client.blogTtsModelCancel();
      if (mounted) setState(() => _model = m);
    } catch (_) {
      // 取消失败也不把界面卡在「下载中」
    }
  }

  // ------------------------------------------------------------------ 翻译模型

  void _startMtPolling() {
    _mtPoll?.cancel();
    _mtPoll = Timer.periodic(const Duration(seconds: 1), (_) => _refreshMt());
  }

  Future<void> _refreshMt() async {
    try {
      final m = await ApiSession.instance.client.blogMtModel();
      if (!mounted) return;
      setState(() => _mt = m);
      if (!m.downloading) {
        _mtPoll?.cancel();
        _mtPoll = null;
      }
    } catch (_) {
      // 网络抖动：下一轮再试
    }
  }

  Future<void> _downloadMt() async {
    if (_mtBusy) return;
    setState(() => _mtBusy = true);
    try {
      final m = await ApiSession.instance.client.blogMtModelDownload();
      if (!mounted) return;
      setState(() => _mt = m);
      if (m.downloading) _startMtPolling();
    } catch (e) {
      // 服务端三源都失败时会把原因放在这里；直接弹出来，别让用户只看到按钮没反应
      if (mounted) {
        NasSnack.show(context, tr('blog.mt.model.failed', {'error': '$e'}), error: true);
      }
    } finally {
      if (mounted) setState(() => _mtBusy = false);
    }
  }

  Future<void> _cancelMt() async {
    _mtPoll?.cancel();
    _mtPoll = null;
    try {
      final m = await ApiSession.instance.client.blogMtModelCancel();
      if (mounted) setState(() => _mt = m);
    } catch (_) {
      // 取消失败也不把界面卡在「下载中」
    }
  }

  // ------------------------------------------------------------------ 保存

  Future<bool> _save({bool silent = false}) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() => _saving = true);
    try {
      final res = await ApiSession.instance.client.blogSaveSettings(
        body: BlogSettingsBody(
          voice: _voice,
          speed: _speed,
          counts: _countsModel(),
          planHour: _planHour,
          planMinute: _planMinute,
          planEnabled: _planEnabled,
          apiProvider: _apiProvider,
          llmEnabled: _llmEnabled,
          webSearch: _webSearch,
          apiKey: _keyCtrl.text.trim(),
          apiBase: _baseCtrl.text.trim(),
          apiModel: _modelCtrl.text.trim(),
        ),
      );
      if (!mounted) return true;
      setState(() {
        _settings = res;
        _saving = false;
      });
      if (!silent && messenger != null) {
        NasSnack.showOn(messenger, tr('blog.saved'), icon: true);
      }
      return true;
    } catch (e) {
      if (!mounted) return false;
      setState(() => _saving = false);
      if (messenger != null) {
        NasSnack.showOn(
          messenger,
          tr('blog.saveFailed', {'error': '$e'}),
          error: true,
        );
      }
      return false;
    }
  }

  // ------------------------------------------------------------------ 上传音色

  /// 上传一段参考音：服务端会转成 24kHz 单声道，前端只管把字节送过去。
  /// 用 base64 而不是 multipart，是因为契约层只有 JSON body，一处改动就够了。
  Future<void> _uploadVoice() async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      const group = XTypeGroup(
        label: 'audio',
        extensions: ['wav', 'mp3', 'm4a', 'flac', 'ogg'],
      );
      final file = await openFile(acceptedTypeGroups: const [group]);
      if (file == null) return;
      final bytes = await file.readAsBytes();
      final name = file.name.replaceAll(RegExp(r'\.[^.]+$'), '');
      final res = await ApiSession.instance.client.blogVoiceUpload(
        body: BlogVoiceUploadBody(name: name, data: base64Encode(bytes)),
      );
      final list = await ApiSession.instance.client.blogVoices();
      if (!mounted) return;
      setState(() {
        _voices = list.items;
        _voice = res.voice.id;
      });
      if (messenger != null) {
        NasSnack.showOn(messenger, tr('blog.voice.uploaded', {'name': res.voice.id}));
      }
    } catch (e) {
      if (messenger != null) {
        NasSnack.showOn(
          messenger,
          tr('blog.voice.uploadFailed', {'error': '$e'}),
          error: true,
        );
      }
    }
  }

  // ------------------------------------------------------------------ 试听

  Future<void> _preview() async {
    if (_previewing) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() => _previewing = true);
    try {
      final res = await ApiSession.instance.client.blogPreview(
        body: BlogPreviewBody(voice: _voice),
      );
      final url = '${ApiSession.instance.baseUrl}${res.url}';
      final p = _previewPlayer ??= Player();
      // 试听也是一路音频：开播前先让音乐 / 播客让路
      await AudioFocus.instance.request(p, () async => p.pause());
      await p.open(Media(url), play: true);
    } catch (e) {
      if (messenger != null) {
        NasSnack.showOn(
          messenger,
          tr('blog.voice.previewFailed', {'error': '$e'}),
          error: true,
        );
      }
    } finally {
      if (mounted) setState(() => _previewing = false);
    }
  }

  // ------------------------------------------------------------------ 生成

  Future<void> _generateNow() async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (_totalItems == 0) {
      NasSnack.showOn(messenger!, tr('blog.generate.noCount'), error: true);
      return;
    }
    // 生成用的是服务端已保存的设置：先把这一屏的选择存下来，避免"点了生成但播的是旧音色"
    final ok = await _save(silent: true);
    if (!ok || !mounted) return;
    try {
      final res = await ApiSession.instance.client.blogGenerate(
        body: BlogGenerateBody(
          counts: _countsModel(),
          voice: _voice,
          speed: _speed,
        ),
      );
      if (!mounted) return;
      setState(() {
        _generatingId = res.id;
        _genStatus = null;
      });
      _startPolling();
      await _reloadEpisodes();
      if (messenger != null) NasSnack.showOn(messenger, tr('blog.generate.started'));
    } catch (e) {
      final text = '$e';
      if (messenger != null) {
        NasSnack.showOn(
          messenger,
          text.contains('conflict') || text.contains('生成')
              ? tr('blog.generate.busy')
              : tr('blog.generate.failed', {'error': text}),
          error: true,
        );
      }
    }
  }

  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 2), (timer) async {
      final id = _generatingId;
      if (id == null) {
        timer.cancel();
        return;
      }
      try {
        final st = await ApiSession.instance.client.blogStatus(id: id);
        if (!mounted) return;
        setState(() => _genStatus = st);
        if (st.status == 'done' || st.status == 'failed') {
          timer.cancel();
          _poll = null;
          if (!mounted) return;
          setState(() => _generatingId = null);
          await _reloadEpisodes();
        }
      } catch (_) {
        // 网络抖动：下一轮再试
      }
    });
  }

  Future<void> _removeEpisode(BlogEpisodeItem ep) async {
    final ok = await NasConfirmDialog.show(
      context,
      title: tr('blog.episodes.delete'),
      message: tr('blog.episodes.deleteConfirm'),
      danger: true,
      confirmText: tr('blog.episodes.delete'),
      cancelText: tr('common.cancel'),
    );
    if (!ok || !mounted) return;
    try {
      if (_player.isCurrent(ep.id)) await _player.stop();
      await ApiSession.instance.client.blogRemove(body: BlogRemoveBody(id: ep.id));
      await _reloadEpisodes();
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(
        context,
        tr('blog.loadFailed', {'error': '$e'}),
        error: true,
      );
    }
  }

  /// 从已有稿件重跑音频合成：服务端只读 script/voice/speed，不抓新闻、不调云端模型，
  /// 因此不消耗任何 token。改代码导致内核重启打断的那一期，点这个就能续上。
  Future<void> _resynthEpisode(BlogEpisodeItem ep) async {
    try {
      if (_player.isCurrent(ep.id)) await _player.stop();
      await ApiSession.instance.client.blogResynth(
        body: BlogResynthBody(id: ep.id),
      );
      if (!mounted) return;
      setState(() {
        _generatingId = ep.id;
        _genStatus = null;
      });
      _startPolling();
      await _reloadEpisodes();
      if (!mounted) return;
      NasSnack.show(context, tr('blog.generate.started'));
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, tr('blog.loadFailed', {'error': '$e'}), error: true);
    }
  }

  // ------------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    if (_loading) return NasLoading(message: tr('blog.loading'));
    if (_error != null) {
      return NasErrorState(
        message: tr('blog.loadFailed', {'error': _error}),
        onRetry: _load,
        retryText: tr('blog.retry'),
      );
    }

    // Web 端铺满：原来卡在 920 居中，1440 屏两侧白掉一大半（用户 2026-11-06 反馈）。
    // 全宽后靠「列表 2 列 + 配置 2 列」把横向空间用起来，仍留一档 padding 不贴边。
    return LayoutBuilder(
      builder: (context, outer) {
        final wide = outer.maxWidth >= 1024;
        final twoCol = outer.maxWidth >= 900;
        const perPage = _perPage;
        final cols = twoCol ? 2 : 1;
        final pages = (_total / perPage).ceil().clamp(1, 9999);
        if (_page > pages - 1) {
          // 删完最后一条 / 换页后总数变小：回到最后一页，别停在空白页
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _page > pages - 1) _goPage(pages - 1);
          });
        }
        final page = _page.clamp(0, pages - 1);
        final visible = _episodes;
        final modelReady = _model?.installed ?? false;
        final mtReady = _mt?.installed ?? false;

        return Column(
          children: [
            Expanded(
              child: ListView(
                padding: EdgeInsets.symmetric(
                  horizontal: wide ? NasTokens.spaceXl : NasTokens.spaceLg,
                  vertical: NasTokens.spaceLg,
                ),
                children: [
                  _header(context),
                  // 首启时模型还没下载：这张卡必须先看到，否则用户找半天不知道要下模型
                  if (!modelReady) ...[
                    const SizedBox(height: NasTokens.spaceMd),
                    _modelCard(context),
                  ],
                  if (!mtReady) ...[
                    const SizedBox(height: NasTokens.spaceMd),
                    _mtCard(context),
                  ],
                  if (_settings?.ttsAvailable == false && modelReady) ...[
                    const SizedBox(height: NasTokens.spaceMd),
                    _banner(context, _ttsReason ?? tr('blog.generate.needsVoice')),
                  ],
                  const SizedBox(height: NasTokens.spaceMd),

                  // ---------------- 已生成音频（最上面，最新在前）
                  _episodesHeader(pages: pages, page: page, perPage: perPage),
                  const SizedBox(height: NasTokens.spaceSm),
                  if (_episodes.isEmpty)
                    NasEmptyState(
                      title: tr('blog.episodes.empty'),
                      icon: Icons.podcasts_outlined,
                    )
                  else ...[
                    _episodeGrid(visible, cols),
                    if (pages > 1) ...[
                      const SizedBox(height: NasTokens.spaceXs),
                      _pager(pages: pages, page: page, perPage: perPage, compact: !twoCol),
                    ],
                  ],

                  // ---------------- 生成设置（列表下方 2 列）
                  const SizedBox(height: NasTokens.spaceXl),
                  Row(
                    children: [
                      Text(
                        tr('blog.settings.title'),
                        style: const TextStyle(
                          fontSize: NasTokens.fontTitle,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: NasTokens.spaceSm),
                      if (_generatingId != null)
                        Text(
                          tr('blog.episodes.status.running'),
                          style: const TextStyle(
                            fontSize: NasTokens.fontCaption,
                            color: Color(NasTokens.colorWarning),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: NasTokens.spaceSm),
                  if (_generatingId != null) ...[
                    _progressCard(),
                    const SizedBox(height: NasTokens.spaceMd),
                  ],
                  _configGrid(twoCol: twoCol),
                  if (modelReady) ...[
                    const SizedBox(height: NasTokens.spaceMd),
                    _modelCard(context),
                  ],
                  if (mtReady) ...[
                    const SizedBox(height: NasTokens.spaceMd),
                    _mtCard(context),
                  ],
                  const SizedBox(height: NasTokens.spaceXl),
                ],
              ),
            ),
            AnimatedBuilder(
              animation: _player,
              builder: (context, _) => _PlayerBar(player: _player),
            ),
          ],
        );
      },
    );
  }

  /// 生成设置分两列：左「内容」（条数 / 音色 / 倍速），右「运行」（API / 计划 / 动作）。
  Widget _configGrid({required bool twoCol}) {
    final left = <Widget>[
      _countsCard(),
      const SizedBox(height: NasTokens.spaceMd),
      _voiceCard(),
      const SizedBox(height: NasTokens.spaceMd),
      _speedCard(),
    ];
    final right = <Widget>[
      _apiCard(),
      const SizedBox(height: NasTokens.spaceMd),
      _planCard(),
      const SizedBox(height: NasTokens.spaceMd),
      _actions(context),
      const SizedBox(height: NasTokens.spaceXs),
      Text(
        // 实测：一条 400 字 ≈ 90 秒音频，本机 Vulkan 合成 1.3x 实时，
        // 加上每块一次模型加载，约 1.4 分钟/条
        tr('blog.generate.eta', {
          'minutes': (_totalItems * 1.4).round().clamp(1, 999),
        }),
        style: TextStyle(
          fontSize: NasTokens.fontCaption,
          color: context.nasTextSecondary,
        ),
      ),
    ];
    if (!twoCol) return Column(children: [...left, const SizedBox(height: NasTokens.spaceMd), ...right]);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: Column(children: left)),
        const SizedBox(width: NasTokens.spaceLg),
        Expanded(child: Column(children: right)),
      ],
    );
  }

  /// 音频卡片网格：宽屏一行 2 张。同一行用 IntrinsicHeight 对齐高度，
  /// 免得「失败」那条多一行错误文案把两列拉不齐。
  Widget _episodeGrid(List<BlogEpisodeItem> items, int cols) {
    if (cols <= 1) {
      return Column(
        children: [
          for (final ep in items) ...[
            _episodeTile(ep),
            const SizedBox(height: NasTokens.spaceSm),
          ],
        ],
      );
    }
    final rows = <Widget>[];
    for (var i = 0; i < items.length; i += cols) {
      final slice = items.sublist(i, (i + cols).clamp(0, items.length));
      rows.add(
        Padding(
          padding: const EdgeInsets.only(bottom: NasTokens.spaceSm),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var j = 0; j < cols; j += 1) ...[
                  if (j > 0) const SizedBox(width: NasTokens.spaceMd),
                  Expanded(
                    child: j < slice.length
                        ? _episodeTile(slice[j])
                        : const SizedBox.shrink(),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }
    return Column(children: rows);
  }

  Widget _pager({
    required int pages,
    required int page,
    required int perPage,
    required bool compact,
  }) {
    final from = page * perPage + 1;
    final to = (page + 1) * perPage;
    final total = _total;
    const btnStyle = TextStyle(fontSize: NasTokens.fontCaption);
    final prev = OutlinedButton(
      onPressed: page > 0 ? () => _goPage(page - 1) : null,
      child: Text(tr('blog.episodes.prev'), style: btnStyle),
    );
    final next = OutlinedButton(
      onPressed: page < pages - 1 ? () => _goPage(page + 1) : null,
      child: Text(tr('blog.episodes.next'), style: btnStyle),
    );
    // 窄屏放不下「上一页 + 7 个页码 + 下一页 + 区间文字」，
    // 只留 上一页 / 第 x/y 页 / 下一页，避免整行溢出。
    if (compact) {
      return Row(
        children: [
          prev,
          const Spacer(),
          Text(
            '${page + 1} / $pages',
            style: TextStyle(
              fontSize: NasTokens.fontCaption,
              color: context.nasTextSecondary,
            ),
          ),
          const Spacer(),
          next,
        ],
      );
    }
    return Row(
      children: [
        prev,
        const SizedBox(width: NasTokens.spaceXs),
        // 页码按钮最多 7 个，多的用省略号，避免几百期时把一行撑爆
        for (final p in _pageWindow(pages, page)) ...[
          if (p == null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text('…', style: btnStyle),
            )
          else
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: p == page
                  // 当前页用实心块而不是 disabled 按钮：置灰按钮看着像「点不了」，
                  // 用户会以为分页坏了
                  ? Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primary,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '${p + 1}',
                        style: btnStyle.copyWith(
                          color: Theme.of(context).colorScheme.onPrimary,
                        ),
                      ),
                    )
                  : OutlinedButton(
                      onPressed: () => _goPage(p),
                      child: Text('${p + 1}', style: btnStyle),
                    ),
            ),
        ],
        const SizedBox(width: NasTokens.spaceXs),
        next,
        const Spacer(),
        Text(
          tr('blog.episodes.range', {
            'from': '$from',
            'to': '${to > total ? total : to}',
            'total': '$total',
          }),
          style: TextStyle(
            fontSize: NasTokens.fontCaption,
            color: context.nasTextSecondary,
          ),
        ),
      ],
    );
  }

  /// 当前页附近最多 7 个页码；`null` 表示省略号
  List<int?> _pageWindow(int pages, int page) {
    if (pages <= 7) return [for (var i = 0; i < pages; i += 1) i];
    final out = <int?>[0];
    final lo = (page - 1).clamp(1, pages - 2);
    final hi = (page + 1).clamp(1, pages - 2);
    if (lo > 1) out.add(null);
    for (var i = lo; i <= hi; i += 1) {
      out.add(i);
    }
    if (hi < pages - 2) out.add(null);
    out.add(pages - 1);
    return out;
  }

  Widget _header(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tr('blog.title'),
                style: const TextStyle(
                  fontSize: NasTokens.fontTitle,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                tr('blog.subtitle'),
                style: TextStyle(
                  fontSize: NasTokens.fontCaption,
                  color: context.nasTextSecondary,
                ),
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: tr('blog.refresh'),
          onPressed: _load,
          icon: const Icon(Icons.refresh),
        ),
      ],
    );
  }

  Widget _banner(BuildContext context, String text) {
    return NasCard(
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, color: Color(NasTokens.colorWarning)),
          const SizedBox(width: NasTokens.spaceSm),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }

  /// 语音模型下载卡片：未下载给按钮、下载中给进度条、下完显示「已下载」。
  /// 进度条复用 `_ThinBar`（自绘）而不是 `LinearProgressIndicator`——后者在
  /// CanvasKit 上高频重建时出过 `memory access out of bounds`。
  Widget _modelCard(BuildContext context) {
    final m = _model;
    final installed = m?.installed ?? false;
    final downloading = m?.downloading ?? false;
    final dir = m?.modelDir;
    final errorText = m?.error ?? '';
    final failed = errorText.isNotEmpty && !installed;
    final cancelled = !installed && !downloading && !failed && (m?.percent ?? 0) > 0;
    final percent = (m?.percent ?? 0.0).clamp(0.0, 100.0);
    final phaseKey = switch (m?.task ?? 'idle') {
      'bin' => 'blog.tts.model.phase.bin',
      'model1' => 'blog.tts.model.phase.model',
      'model2' => 'blog.tts.model.phase.vocoder',
      _ => '',
    };
    final percentLabel = tr('blog.tts.model.downloading', {
      'percent': percent.toStringAsFixed(1),
    });

    return NasCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _cardTitle(context, tr('blog.tts.model.title')),
          if (installed) ...[
            Row(
              children: [
                Icon(Icons.check_circle_outline, size: 18, color: context.nasSuccess),
                const SizedBox(width: NasTokens.spaceSm),
                Expanded(
                  child: Text(
                    tr('blog.tts.model.installed'),
                    style: TextStyle(
                      color: context.nasSuccess,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            if (dir != null) ...[
              const SizedBox(height: 4),
              Text(
                tr('blog.tts.model.dir', {'dir': dir}),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: NasTokens.fontCaption,
                  color: context.nasTextSecondary,
                ),
              ),
            ],
          ] else if (downloading) ...[
            Text(
              phaseKey.isEmpty ? percentLabel : '$percentLabel · ${tr(phaseKey)}',
            ),
            const SizedBox(height: NasTokens.spaceSm),
            _ThinBar(value: percent / 100, height: 6),
            const SizedBox(height: NasTokens.spaceSm),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _cancelModel,
                icon: const Icon(Icons.close, size: 18),
                label: Text(tr('blog.tts.model.cancel')),
              ),
            ),
          ] else ...[
            Text(
              tr('blog.tts.model.hint'),
              style: TextStyle(
                fontSize: NasTokens.fontCaption,
                color: context.nasTextSecondary,
              ),
            ),
            if (failed) ...[
              const SizedBox(height: 4),
              Text(
                tr('blog.tts.model.failed', {'error': errorText}),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: NasTokens.fontCaption,
                  color: context.nasDanger,
                ),
              ),
            ] else if (cancelled) ...[
              const SizedBox(height: 4),
              Text(
                tr('blog.tts.model.cancelled'),
                style: TextStyle(
                  fontSize: NasTokens.fontCaption,
                  color: context.nasWarning,
                ),
              ),
            ] else if (_ttsReason != null && _ttsReason!.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                _ttsReason!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: NasTokens.fontCaption,
                  color: context.nasWarning,
                ),
              ),
            ],
            const SizedBox(height: NasTokens.spaceSm),
            FilledButton.icon(
              onPressed: _modelBusy ? null : _downloadModel,
              icon: _modelBusy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.download),
              label: Text(tr(failed ? 'blog.tts.model.retry' : 'blog.tts.model.download')),
            ),
          ],
        ],
      ),
    );
  }

  /// 本地翻译模型卡片：下载源在国内/国外自动切换（ModelScope → HF 镜像 → HuggingFace），
  /// 三个都失败才报错，错误原文直接展示，用户能看出是网络还是别的。
  Widget _mtCard(BuildContext context) {
    final m = _mt;
    final installed = m?.installed ?? false;
    final downloading = m?.downloading ?? false;
    final dir = m?.modelDir;
    final errorText = m?.error ?? '';
    final failed = errorText.isNotEmpty && !installed;
    final cancelled = !installed && !downloading && !failed && (m?.percent ?? 0) > 0;
    final percent = (m?.percent ?? 0.0).clamp(0.0, 100.0);
    final switching = (m?.phase ?? '').startsWith('切换下载源');
    final percentLabel = switching
        ? tr('blog.mt.model.switching')
        : tr('blog.mt.model.downloading', {'percent': percent.toStringAsFixed(1)});

    return NasCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _cardTitle(context, tr('blog.mt.model.title')),
          if (installed) ...[
            Row(
              children: [
                Icon(Icons.check_circle_outline, size: 18, color: context.nasSuccess),
                const SizedBox(width: NasTokens.spaceSm),
                Expanded(
                  child: Text(
                    tr('blog.mt.model.installed'),
                    style: TextStyle(
                      color: context.nasSuccess,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            if (dir != null) ...[
              const SizedBox(height: 4),
              Text(
                tr('blog.mt.model.dir', {'dir': dir}),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: NasTokens.fontCaption,
                  color: context.nasTextSecondary,
                ),
              ),
            ],
          ] else if (downloading) ...[
            Text(percentLabel),
            const SizedBox(height: NasTokens.spaceSm),
            _ThinBar(value: percent / 100, height: 6),
            const SizedBox(height: NasTokens.spaceSm),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _cancelMt,
                icon: const Icon(Icons.close, size: 18),
                label: Text(tr('blog.mt.model.cancel')),
              ),
            ),
          ] else ...[
            Text(
              tr('blog.mt.model.hint'),
              style: TextStyle(
                fontSize: NasTokens.fontCaption,
                color: context.nasTextSecondary,
              ),
            ),
            if (failed) ...[
              const SizedBox(height: 4),
              Text(
                tr('blog.mt.model.failed', {'error': errorText}),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: NasTokens.fontCaption,
                  color: context.nasDanger,
                ),
              ),
            ] else if (cancelled) ...[
              const SizedBox(height: 4),
              Text(
                tr('blog.mt.model.cancelled'),
                style: TextStyle(
                  fontSize: NasTokens.fontCaption,
                  color: context.nasWarning,
                ),
              ),
            ],
            const SizedBox(height: NasTokens.spaceSm),
            FilledButton.icon(
              onPressed: _mtBusy ? null : _downloadMt,
              icon: _mtBusy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.download),
              label: Text(tr(failed ? 'blog.mt.model.retry' : 'blog.mt.model.download')),
            ),
          ],
        ],
      ),
    );
  }

  Widget _cardTitle(BuildContext context, String title, {String? trailing}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: NasTokens.spaceSm),
      child: Row(
        children: [
          Flexible(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: NasTokens.fontSubtitle,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                trailing,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: TextStyle(
                  fontSize: NasTokens.fontCaption,
                  color: context.nasTextSecondary,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _countsCard() {
    // 左列全是国内、右列全是国外（用户要求）；窄屏退化成单列，否则中文标签 + 下拉会挤成两行
    const domestic = ['domesticGeneral', 'domesticTech', 'domesticAi', 'domesticFinance'];
    const world = ['worldGeneral', 'worldTech', 'worldAi', 'worldFinance'];

    return NasCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _cardTitle(
            context,
            tr('blog.counts.title'),
            trailing: tr('blog.total', {'count': _totalItems}),
          ),
          LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth < 560) {
                return Column(
                  children: [
                    for (final key in [...domestic, ...world]) _countRow(key),
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      children: [for (final key in domestic) _countRow(key)],
                    ),
                  ),
                  const SizedBox(width: NasTokens.spaceLg),
                  Expanded(
                    child: Column(
                      children: [for (final key in world) _countRow(key)],
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  /// 一行一个类别。下拉**必须**给固定宽度 + `expanded`：
  /// DropdownButton 在 Row 里拿的是无界宽度，未 expanded 时会去做 intrinsic 测量，
  /// 在 CanvasKit 上会抛 `RenderBox was not laid out: RenderParagraph` 并连带崩溃。
  Widget _countRow(String key) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _countLabel(key),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 92,
            child: NasDropdown<int>(
              expanded: true,
              value: _counts[key] ?? 0,
              items: [
                for (var i = 0; i <= 10; i++)
                  DropdownMenuItem(
                    value: i,
                    child: Text(tr('blog.count.unit', {'count': i})),
                  ),
              ],
              onChanged: (v) => setState(() => _counts[key] = v ?? 0),
            ),
          ),
        ],
      ),
    );
  }

  String _countLabel(String key) {
    for (final c in _kCategories) {
      if (c.key == key) return tr(c.labelKey);
    }
    return key;
  }

  String _voiceLabel(BlogVoiceItem v) {
    final key = _kBuiltinVoiceKeys[v.id];
    if (key != null) return tr(key);
    return v.label.isNotEmpty ? v.label : v.id;
  }

  /// DropdownButton 要求 value 严格等于 items 中的某一项，否则直接 assert 崩溃。
  /// 老库里可能存着 Kokoro 时代的固定音色 id（zf_001…），或用户上传的 wav 已被删除；
  /// 统一回落到内置音色，保证页面永远能打开。
  String? _selectedVoice() {
    for (final v in _voices) {
      if (v.id == _voice) return v.id;
    }
    for (final v in _voices) {
      if (v.id == 'default') return v.id;
    }
    return _voices.isEmpty ? null : _voices.first.id;
  }

  /// 顺手把状态也修正，避免预览 / 保存 / 生成又把失效 id 发回服务端。
  void _normalizeVoice() {
    final picked = _selectedVoice();
    if (picked != null) _voice = picked;
  }

  Widget _voiceCard() {
    return NasCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _cardTitle(context, tr('blog.voice.title')),
          if (!_ttsAvailable)
            Padding(
              padding: const EdgeInsets.only(bottom: NasTokens.spaceSm),
              child: Text(
                _ttsReason ??
                    tr('blog.voice.unavailable', {'reason': 'npm run tts:model'}),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: NasTokens.fontCaption,
                  color: context.nasDanger,
                ),
              ),
            ),
          Row(
            children: [
              Expanded(
                child: NasDropdown<String>(
                  expanded: true,
                  value: _selectedVoice(),
                  items: [
                    for (final v in _voices)
                      DropdownMenuItem(
                        value: v.id,
                        child: Text(_voiceLabel(v)),
                      ),
                  ],
                  onChanged: (v) => setState(() => _voice = v ?? _voice),
                ),
              ),
              const SizedBox(width: NasTokens.spaceSm),
              FilledButton.tonalIcon(
                onPressed: _previewing ? null : _preview,
                icon: _previewing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.play_arrow),
                label: Text(
                  _previewing
                      ? tr('blog.voice.previewing')
                      : tr('blog.voice.preview'),
                ),
              ),
              const SizedBox(width: NasTokens.spaceXs),
              Tooltip(
                message: tr('blog.voice.upload'),
                child: IconButton(
                  onPressed: _uploadVoice,
                  icon: const Icon(Icons.upload_file),
                ),
              ),
            ],
          ),
          const SizedBox(height: NasTokens.spaceXs),
          Text(
            tr('blog.voice.previewHint'),
            style: TextStyle(
              fontSize: NasTokens.fontCaption,
              color: context.nasTextSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _speedCard() {
    return NasCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _cardTitle(
            context,
            tr('blog.speed.title'),
            trailing: tr('blog.speed.value', {'value': _speed.toStringAsFixed(1)}),
          ),
          Slider(
            value: _speed,
            min: 0.5,
            max: 2,
            divisions: 15,
            label: tr('blog.speed.value', {'value': _speed.toStringAsFixed(1)}),
            onChanged: (v) => setState(() => _speed = v),
          ),
          Row(
            children: [
              Text(
                tr('blog.estimate'),
                style: TextStyle(
                  fontSize: NasTokens.fontCaption,
                  color: context.nasTextSecondary,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _estimate,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _apiCard() {
    return NasCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _cardTitle(context, tr('blog.api.title')),
          if (_settings?.llmReady == false)
            Padding(
              padding: const EdgeInsets.only(bottom: NasTokens.spaceXs),
              child: Text(
                tr('blog.api.notConfigured'),
                style: TextStyle(
                  fontSize: NasTokens.fontCaption,
                  color: const Color(NasTokens.colorWarning),
                ),
              ),
            ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _llmEnabled,
            onChanged: (v) => setState(() => _llmEnabled = v),
            title: Text(tr('blog.api.enable')),
            subtitle: Text(
              tr('blog.api.enableHint'),
              style: TextStyle(
                fontSize: NasTokens.fontCaption,
                color: context.nasTextSecondary,
              ),
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _webSearch,
            onChanged: (v) => setState(() => _webSearch = v),
            title: Text(tr('blog.api.webSearch')),
            subtitle: Text(
              tr('blog.api.webSearchHint'),
              style: TextStyle(
                fontSize: NasTokens.fontCaption,
                color: context.nasTextSecondary,
              ),
            ),
          ),
          Row(
            children: [
              Text(
                tr('blog.api.provider'),
                style: TextStyle(
                  fontSize: NasTokens.fontCaption,
                  color: context.nasTextSecondary,
                ),
              ),
              const SizedBox(width: NasTokens.spaceSm),
              SizedBox(
                width: 160,
                child: NasDropdown<String>(
                  expanded: true,
                  value: _apiProvider,
                  items: [
                    const DropdownMenuItem(value: 'deepseek', child: Text('DeepSeek')),
                    DropdownMenuItem(
                      value: 'bailian',
                      child: Text(tr('settings.llm.providerBailian')),
                    ),
                    const DropdownMenuItem(value: 'openai', child: Text('OpenAI')),
                    DropdownMenuItem(
                      value: 'custom',
                      child: Text(tr('blog.api.custom')),
                    ),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() => _apiProvider = v);
                    // 选服务商就把地址与模型带出来，用户只填 Key 即可；自定义则保留手填值
                    if (v == 'deepseek') {
                      _baseCtrl.text = 'https://api.deepseek.com';
                      _modelCtrl.text = 'deepseek-flash';
                      _webSearch = false;
                    } else if (v == 'bailian') {
                      // 百炼是唯一带联网搜索插件的：选它就把地址/模型/联网一起带出来
                      _baseCtrl.text = 'https://dashscope.aliyuncs.com/compatible-mode/v1';
                      _modelCtrl.text = 'deepseek-v3';
                      _webSearch = true;
                    } else if (v == 'openai') {
                      _baseCtrl.text = 'https://api.openai.com/v1';
                      _modelCtrl.text = 'gpt-4o-mini';
                    }
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: NasTokens.spaceSm),
          TextField(
            controller: _keyCtrl,
            obscureText: !_keyVisible,
            decoration: InputDecoration(
              labelText: tr('blog.api.key'),
              isDense: true,
              suffixIcon: IconButton(
                tooltip: _keyVisible ? tr('blog.api.hide') : tr('blog.api.show'),
                icon: Icon(
                  _keyVisible ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                ),
                onPressed: () async {
                  final next = !_keyVisible;
                  setState(() => _keyVisible = next);
                  await SettingsStore.instance.setBool(_kKeyVisible, next);
                },
              ),
            ),
          ),
          const SizedBox(height: NasTokens.spaceXs),
          Text(
            tr('blog.api.hint'),
            style: TextStyle(
              fontSize: NasTokens.fontCaption,
              color: context.nasTextSecondary,
            ),
          ),
          const SizedBox(height: NasTokens.spaceSm),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _baseCtrl,
                  decoration: InputDecoration(
                    labelText: tr('blog.api.base'),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: NasTokens.spaceSm),
              Expanded(
                child: TextField(
                  controller: _modelCtrl,
                  decoration: InputDecoration(
                    labelText: tr('blog.api.model'),
                    isDense: true,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _planCard() {
    final minutes = [for (var i = 0; i < 60; i += 5) i];
    final currentMinute = minutes.reduce(
      (a, b) => (_planMinute - a).abs() <= (_planMinute - b).abs() ? a : b,
    );
    return NasCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          SwitchListTile(
            value: _planEnabled,
            onChanged: (v) => setState(() => _planEnabled = v),
            title: Text(tr('blog.plan.title')),
            subtitle: Text(tr('blog.plan.enable')),
          ),
          const Divider(height: 1),
          ListTile(
            title: Text(tr('blog.plan.time')),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 78,
                  child: NasDropdown<int>(
                    expanded: true,
                    value: _planHour,
                    items: [
                      for (var h = 0; h < 24; h++)
                        DropdownMenuItem(
                          value: h,
                          child: Text(h.toString().padLeft(2, '0')),
                        ),
                    ],
                    onChanged: _planEnabled
                        ? (v) => setState(() => _planHour = v ?? _planHour)
                        : null,
                  ),
                ),
                const SizedBox(
                  width: 24,
                  child: Text(' : ', textAlign: TextAlign.center),
                ),
                SizedBox(
                  width: 78,
                  child: NasDropdown<int>(
                    expanded: true,
                    value: currentMinute,
                    items: [
                      for (final m in minutes)
                        DropdownMenuItem(
                          value: m,
                          child: Text(m.toString().padLeft(2, '0')),
                        ),
                    ],
                    onChanged: _planEnabled
                        ? (v) => setState(() => _planMinute = v ?? _planMinute)
                        : null,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              NasTokens.spaceMd,
              0,
              NasTokens.spaceMd,
              NasTokens.spaceMd,
            ),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                tr('blog.plan.hint'),
                style: TextStyle(
                  fontSize: NasTokens.fontCaption,
                  color: context.nasTextSecondary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _actions(BuildContext context) {
    final busy = _saving || _generatingId != null;
    return Row(
      children: [
        FilledButton.icon(
          onPressed: busy ? null : () => _save(),
          icon: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.save_outlined),
          label: Text(tr('blog.save')),
        ),
        const SizedBox(width: NasTokens.spaceSm),
        OutlinedButton.icon(
          onPressed: busy || _settings?.ttsAvailable == false ? null : _generateNow,
          icon: const Icon(Icons.auto_awesome),
          label: Text(tr('blog.generate.now')),
        ),
      ],
    );
  }

  Widget _progressCard() {
    final st = _genStatus;
    final done = st?.doneParts ?? 0;
    final total = st?.parts ?? 0;
    final running = st == null || st.status == 'pending' || st.status == 'running';
    final failed = st?.status == 'failed';
    return NasCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (running)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              const SizedBox(width: NasTokens.spaceSm),
              Expanded(
                child: Text(
                  failed
                      ? tr('blog.generate.failed', {'error': st?.error ?? ''})
                      : total > 0
                          ? tr('blog.generate.running', {'done': done, 'total': total})
                          : tr('blog.generate.preparing'),
                  style: TextStyle(
                    color: failed
                        ? const Color(NasTokens.colorDanger)
                        : null,
                  ),
                ),
              ),
            ],
          ),
          if (running && total > 0) ...[
            const SizedBox(height: NasTokens.spaceSm),
            _ThinBar(value: done / total, height: 4),
          ],
        ],
      ),
    );
  }

  Widget _episodesHeader({
    required int pages,
    required int page,
    required int perPage,
  }) {
    final meta = [
      if (_total > 0) tr('blog.episodes.total', {'count': _total}),
      tr('blog.episodes.newest'),
      tr('blog.episodes.perPage', {'count': perPage}),
      if (pages > 1) '${page + 1} / $pages',
    ].join(' · ');
    return NasSectionHeader(
      title: tr('blog.episodes.title'),
      subtitle: _episodes.isEmpty ? null : meta,
    );
  }

  Widget _episodeTile(BlogEpisodeItem ep) {
    final playingThis = _player.isCurrent(ep.id) && _player.playing;
    final ready = ep.status == 'done';
    // 手机 / 窄屏放不下 3 个按钮：文稿常驻，重新生成 / 删除收进「更多」。
    // 用屏幕宽度而不是 LayoutBuilder：宽屏列表套了 IntrinsicHeight，
    // LayoutBuilder 不支持 intrinsic dimensions，会直接在布局期抛断言。
    final compact = MediaQuery.sizeOf(context).width < 600;
    final canResynth = ep.status != 'running' && ep.status != 'pending';
    return NasCard(
      padding: const EdgeInsets.symmetric(
        horizontal: NasTokens.spaceMd,
        vertical: NasTokens.spaceSm,
      ),
      child: Row(
        children: [
          // 不要套 40×40 的盒子：IconButton 默认最小 48，套小了会被裁掉一半
          IconButton.filledTonal(
            tooltip: playingThis ? tr('blog.player.pause') : tr('blog.player.play'),
            onPressed: ready
                ? () {
                    if (_player.isCurrent(ep.id)) {
                      _player.toggle();
                    } else {
                      _player.play(ep, _episodes);
                    }
                  }
                : null,
            icon: Icon(playingThis ? Icons.pause : Icons.play_arrow),
          ),
          const SizedBox(width: NasTokens.spaceMd),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  ep.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  [
                    formatDateTimeSec(ep.createdAt),
                    if (ready) formatDurationMs((ep.durationSec * 1000).round()),
                    if (ready) formatBytes(ep.sizeBytes),
                    if (!ready) _statusLabel(ep.status),
                    tr('blog.episodes.items', {'count': ep.itemCount}),
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: NasTokens.fontCaption,
                    color: context.nasTextSecondary,
                  ),
                ),
                if (ep.status == 'failed' && ep.error != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    ep.error!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: NasTokens.fontCaption,
                      color: Color(NasTokens.colorDanger),
                    ),
                  ),
                ],
              ],
            ),
          ),
          // 文稿放最前面：听之前先看这期讲了什么
          IconButton(
            tooltip: tr('blog.episodes.script'),
            onPressed: () => _openScript(ep),
            icon: const Icon(Icons.description_outlined),
          ),
          if (!compact) ...[
            if (canResynth)
              IconButton(
                tooltip: tr('blog.episodes.resynth'),
                onPressed: () => _resynthEpisode(ep),
                icon: const Icon(Icons.refresh),
              ),
            IconButton(
              tooltip: tr('blog.episodes.delete'),
              onPressed: () => _removeEpisode(ep),
              icon: const Icon(Icons.delete_outline),
            ),
          ] else
                PopupMenuButton<String>(
                  tooltip: tr('common.more'),
                  onSelected: (value) {
                    if (value == 'enqueue') _enqueue(ep);
                    if (value == 'playNext') _playNext(ep);
                    if (value == 'resynth') _resynthEpisode(ep);
                    if (value == 'delete') _removeEpisode(ep);
                  },
                  itemBuilder: (context) => [
                    if (ready) ...[
                      PopupMenuItem<String>(
                        value: 'enqueue',
                        child: Row(
                          children: [
                            const Icon(Icons.playlist_add, size: 18),
                            const SizedBox(width: 8),
                            Text(tr('blog.queue.enqueue')),
                          ],
                        ),
                      ),
                      PopupMenuItem<String>(
                        value: 'playNext',
                        child: Row(
                          children: [
                            const Icon(Icons.play_arrow, size: 18),
                            const SizedBox(width: 8),
                            Text(tr('blog.queue.playNext')),
                          ],
                        ),
                      ),
                    ],
                    if (canResynth)
                      PopupMenuItem<String>(
                        value: 'resynth',
                        child: Row(
                          children: [
                            const Icon(Icons.refresh, size: 18),
                            const SizedBox(width: 8),
                            Text(tr('blog.episodes.resynth')),
                          ],
                        ),
                      ),
                PopupMenuItem<String>(
                  value: 'delete',
                  child: Row(
                    children: [
                      const Icon(Icons.delete_outline, size: 18),
                      const SizedBox(width: 8),
                      Text(tr('blog.episodes.delete')),
                    ],
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  String _statusLabel(String status) => switch (status) {
        'pending' => tr('blog.episodes.status.pending'),
        'running' => tr('blog.episodes.status.running'),
        'failed' => tr('blog.episodes.status.failed'),
        _ => tr('blog.episodes.status.done'),
      };

  Future<void> _openScript(BlogEpisodeItem ep) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _ScriptDialog(episode: ep),
    );
  }

  Future<void> _enqueue(BlogEpisodeItem ep) async {
    await _player.enqueue(ep);
    if (mounted) NasSnack.show(context, tr('blog.queue.added'));
  }

  Future<void> _playNext(BlogEpisodeItem ep) async {
    await _player.enqueueNext(ep);
    if (mounted) NasSnack.show(context, tr('blog.queue.added'));
  }
}

/// 文稿弹窗：上半是播报稿全文，最下面是这一期引用的原文链接。
/// 数据进来前先显示 loading，避免点开后空白一下。
class _ScriptDialog extends StatefulWidget {
  const _ScriptDialog({required this.episode});

  final BlogEpisodeItem episode;

  @override
  State<_ScriptDialog> createState() => _ScriptDialogState();
}

class _ScriptDialogState extends State<_ScriptDialog> {
  BlogScriptResponse? _data;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final res = await ApiSession.instance.client.blogScript(id: widget.episode.id);
      if (!mounted) return;
      setState(() => _data = res);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(tr('blog.script.title')),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 680,
          maxHeight: MediaQuery.sizeOf(context).height * 0.72,
        ),
        child: SizedBox(
          width: 680,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.episode.title,
                  style: TextStyle(
                    fontSize: NasTokens.fontCaption,
                    color: context.nasTextSecondary,
                  ),
                ),
                const SizedBox(height: NasTokens.spaceMd),
                if (_error != null)
                  Text(
                    tr('blog.loadFailed', {'error': _error ?? ''}),
                    style: const TextStyle(color: Color(NasTokens.colorDanger)),
                  )
                else if (data == null)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else ...[
                  if (data.script.trim().isEmpty)
                    Text(tr('blog.script.empty'))
                  else
                    SelectableText(
                      data.script,
                      style: const TextStyle(fontSize: 14, height: 1.6),
                    ),
                  const SizedBox(height: NasTokens.spaceLg),
                  const Divider(height: 1),
                  const SizedBox(height: NasTokens.spaceMd),
                  Text(
                    tr('blog.script.links'),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: NasTokens.spaceSm),
                  if (data.items.isEmpty)
                    Text(
                      tr('blog.script.noLinks'),
                      style: TextStyle(
                        fontSize: NasTokens.fontCaption,
                        color: context.nasTextSecondary,
                      ),
                    )
                  else ...[
                    for (var i = 0; i < data.items.length; i += 1)
                      _linkTile(data.items[i], i, scheme),
                    if (data.items.every((e) => e.link.isEmpty))
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          tr('blog.script.noLinks'),
                          style: TextStyle(
                            fontSize: NasTokens.fontCaption,
                            color: context.nasTextSecondary,
                          ),
                        ),
                      ),
                  ],
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('common.close')),
        ),
      ],
    );
  }

  Widget _linkTile(BlogScriptItem item, int index, ColorScheme scheme) {
    final canOpen = canOpenExternalLinks && item.link.isNotEmpty;
    final caption = TextStyle(
      fontSize: NasTokens.fontCaption,
      color: context.nasTextSecondary,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: NasTokens.spaceSm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${index + 1}. ', style: caption),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (canOpen)
                  InkWell(
                    onTap: () => openExternalLink(item.link),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            item.title,
                            style: TextStyle(color: scheme.primary),
                          ),
                        ),
                        Icon(Icons.open_in_new, size: 14, color: scheme.primary),
                      ],
                    ),
                  )
                else
                  Text(item.title),
                if (item.category.isNotEmpty || item.source.isNotEmpty)
                  Text(
                    [item.category, item.source]
                        .where((s) => s.isNotEmpty)
                        .join(' · '),
                    style: caption,
                  ),
                // 非 Web 端点不开，就把地址显示出来让用户复制
                if (item.link.isNotEmpty && !canOpen)
                  SelectableText(item.link, style: caption),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 细进度条（自绘）。
///
/// 为什么不用 `LinearProgressIndicator`：它在 CanvasKit 上 3px 高度 + 高频重建
/// （播放位置每帧 notify）时遇到过渲染层 `memory access out of bounds`；
/// 自己用两个色块画，零动画、零语义节点，稳。
class _ThinBar extends StatelessWidget {
  const _ThinBar({required this.value, this.height = 3});

  final double value;
  final double height;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final v = value.clamp(0.0, 1.0);
    return SizedBox(
      height: height,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: scheme.surfaceContainerHighest),
          Align(
            alignment: Alignment.centerLeft,
            child: FractionallySizedBox(
              widthFactor: v,
              child: ColoredBox(color: scheme.primary),
            ),
          ),
        ],
      ),
    );
  }
}

/// 底部迷你播放条：只有播过东西才出现。
/// 点整条进全屏播放页（可拖进度 + 播放列表），右边图标直接开播放队列。
class _PlayerBar extends StatelessWidget {
  const _PlayerBar({required this.player});

  final BlogPlayer player;

  void _open(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BlogPlayerPage(player: player),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ep = player.episode;
    if (ep == null) return const SizedBox.shrink();
    final total = player.duration.inMilliseconds > 0
        ? player.duration.inMilliseconds
        : (ep.durationSec * 1000).round();
    final pos = player.position.inMilliseconds.clamp(0, total == 0 ? 0 : total);
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: InkWell(
        onTap: () => _open(context),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 自绘而不是 LinearProgressIndicator：3px 高的 Material 进度条在 CanvasKit 上
                // 配合高频 position 通知重绘，出现过 `memory access out of bounds`。
                _ThinBar(value: total > 0 ? (pos / total).clamp(0.0, 1.0) : 0.0),
                Row(
                  children: [
                    const SizedBox(width: 4),
                    IconButton(
                      tooltip: tr('blog.player.prev'),
                      onPressed: player.prev,
                      icon: const Icon(Icons.skip_previous),
                    ),
                    IconButton(
                      tooltip: player.playing ? tr('blog.player.pause') : tr('blog.player.play'),
                      onPressed: player.toggle,
                      icon: player.loading
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(player.playing ? Icons.pause_circle : Icons.play_circle),
                    ),
                    IconButton(
                      tooltip: tr('blog.player.next'),
                      onPressed: player.next,
                      icon: const Icon(Icons.skip_next),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            ep.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          Text(
                            '${formatDurationMs(pos)} / ${formatDurationMs(total)} · ${player.index + 1}/${player.queue.length}',
                            style: TextStyle(
                              fontSize: NasTokens.fontCaption,
                              color: context.nasTextSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (player.error != null)
                      Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: Text(
                          player.error!,
                          style: const TextStyle(
                            fontSize: NasTokens.fontCaption,
                            color: Color(NasTokens.colorDanger),
                          ),
                        ),
                      ),
                    IconButton(
                      tooltip: tr('blog.queue.title'),
                      onPressed: () => showBlogQueueSheet(context, player),
                      icon: const Icon(Icons.queue_music),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
