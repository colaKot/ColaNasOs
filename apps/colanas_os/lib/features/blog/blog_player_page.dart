import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import 'blog_player.dart';
import 'blog_queue_sheet.dart';

/// 播客的**全屏播放页**：点底部迷你播放条进来。
///
/// 与音乐播放页同一套心智模型：封面区 + 可拖进度条 + 上/下一期 + 倍速 + 播放列表。
/// 播放器本身是全局单例，这里只是它的一个视图；返回 / 切模块 / 熄屏都不会停。
///
/// 新闻类期次（AI 新闻）不摆品牌图案：那块方形区域直接显示播报稿，并按播放进度
/// 高亮「正在读的那一条」——不做逐行高亮，一条新闻一段。
class BlogPlayerPage extends StatefulWidget {
  const BlogPlayerPage({super.key, this.player});

  final BlogPlayer? player;

  @override
  State<BlogPlayerPage> createState() => _BlogPlayerPageState();
}

class _BlogPlayerPageState extends State<BlogPlayerPage> {
  /// 拖动进度条期间用本地值，不然 position 流会把滑块往回拽
  double? _dragValue;

  BlogPlayer get _player => widget.player ?? BlogPlayer.instance;

  static const List<double> _rates = [1.0, 1.25, 1.5, 2.0];

  // ------------------------------------------------------------ 播报稿

  final ScrollController _scriptScroll = ScrollController();
  final Map<int, GlobalKey> _blockKeys = <int, GlobalKey>{};

  /// 已经为哪一期取过稿：播放器 10Hz 通知，靠它去重
  String? _scriptForId;
  List<_ScriptBlock> _blocks = const <_ScriptBlock>[];
  bool _scriptLoading = false;

  /// 当前高亮的段（按进度估算出来，只用于绘制 / 滚动）
  int _activeBlock = 0;

  @override
  void initState() {
    super.initState();
    _player.addListener(_onPlayerChanged);
    _onPlayerChanged();
  }

  @override
  void dispose() {
    _player.removeListener(_onPlayerChanged);
    _scriptScroll.dispose();
    super.dispose();
  }

  void _onPlayerChanged() {
    if (!mounted) return;
    // 本地博客没有新闻稿：不去请求 /blog/script，避免每切一首发一次无效请求
    if (_player.kind == BlogPlaybackKind.localBlog) return;
    final id = _player.episode?.id;
    if (id == null || id == _scriptForId || _scriptLoading) return;
    unawaited(_fetchScript(id));
  }

  Future<void> _fetchScript(String id) async {
    // 先占位再请求：播放进度每秒通知十次，不去重会连发十个请求
    _scriptForId = id;
    _scriptLoading = true;
    _blocks = const <_ScriptBlock>[];
    _blockKeys.clear();
    setState(() {});
    try {
      final res = await ApiSession.instance.client.blogScript(id: id);
      if (!mounted || _scriptForId != id) return;
      final blocks = _parseBlocks(res.script);
      setState(() {
        _blocks = blocks;
        _scriptLoading = false;
        _activeBlock = 0;
      });
    } catch (_) {
      // 取不到稿就退化成原来的品牌图案，播放不受影响
      if (!mounted || _scriptForId != id) return;
      setState(() => _scriptLoading = false);
    }
  }

  /// 把播报稿切成「一条新闻一段」。
  ///
  /// 稿件由服务端用空行分隔拼成：分类头（`下面是国内科技。`）、每条新闻的播报头
  /// （`第一，<一句总结>。`）、新闻正文、结尾。播报头 / 分类头 / 开头结尾各起一段，
  /// 正文并进上一段 —— 所以一段 = 一条新闻，正好是用户要的粒度。
  static final RegExp _leadRe = RegExp(r'^第[零一二三四五六七八九十百千0-9]+[，,、]');
  static final RegExp _headerRe = RegExp(r'^(下面是|最后是|以上就是)');

  static List<_ScriptBlock> _parseBlocks(String script) {
    final paragraphs = script
        .split(RegExp(r'\n{2,}'))
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty);
    final blocks = <_ScriptBlock>[];
    for (final p in paragraphs) {
      final starts =
          blocks.isEmpty || _leadRe.hasMatch(p) || _headerRe.hasMatch(p);
      if (starts) {
        blocks.add(_ScriptBlock(title: p, body: ''));
      } else {
        final last = blocks.removeLast();
        blocks.add(_ScriptBlock(title: last.title, body: '${last.body}$p'));
      }
    }
    return blocks;
  }

  /// 按「字数占比」把进度映射到段：TTS 语速稳定，按字数的线性估算足够对得上。
  int _activeIndexOf(Duration pos, Duration total) {
    if (_blocks.length <= 1 || total <= Duration.zero) return 0;
    var totalWeight = 0;
    for (final b in _blocks) {
      totalWeight += b.weight;
    }
    if (totalWeight <= 0) return 0;
    final ratio =
        (pos.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0).toDouble();
    var acc = 0;
    for (var i = 0; i < _blocks.length; i += 1) {
      acc += _blocks[i].weight;
      if (ratio <= acc / totalWeight) return i;
    }
    return _blocks.length - 1;
  }

  void _scheduleScrollToActive(int index) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctx = _blockKeys[index]?.currentContext;
      if (ctx == null) return;
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.3,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
    });
  }

  // ------------------------------------------------------------ 构建

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _player,
      builder: (context, _) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    final p = _player;
    final ep = p.episode;
    final local = p.kind == BlogPlaybackKind.localBlog;
    final total = p.duration.inMilliseconds > 0
        ? p.duration.inMilliseconds
        : (ep == null ? 0 : (ep.durationSec * 1000).round());
    final pos = p.position.inMilliseconds.clamp(0, total == 0 ? 0 : total);
    // 拖动时左侧时间跟着滑块走，松手后再回到真实播放位置
    final shown = _dragValue != null && total > 0
        ? (_dragValue! * total).round()
        : pos;
    final scheme = Theme.of(context).colorScheme;

    if (!local && _blocks.isNotEmpty) {
      final active = _activeIndexOf(
        Duration(milliseconds: pos),
        Duration(milliseconds: total),
      );
      if (active != _activeBlock) {
        _activeBlock = active;
        _scheduleScrollToActive(active);
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(local ? tr('blog.nav.localBlog') : tr('blog.player.title')),
        actions: [
          MenuAnchor(
            menuChildren: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: SizedBox(
                  width: 180,
                  child: Row(
                    children: [
                      Icon(
                        p.muted ? Icons.volume_off : Icons.volume_up,
                        size: 18,
                      ),
                      Expanded(
                        child: Slider(
                          value: p.volume,
                          max: 100,
                          onChanged: (v) => p.setVolume(v),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            builder: (context, controller, _) => IconButton(
              tooltip: tr('blog.player.volume'),
              icon: Icon(p.muted ? Icons.volume_off : Icons.volume_up),
              onPressed: () =>
                  controller.isOpen ? controller.close() : controller.open(),
            ),
          ),
          IconButton(
            tooltip: tr('blog.queue.title'),
            onPressed: () => showBlogQueueSheet(context, p),
            icon: const Icon(Icons.queue_music),
          ),
        ],
      ),
      body: ep == null
          ? Center(child: Text(tr('blog.player.noEpisode')))
          : Center(
              child: SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: Padding(
                    padding: const EdgeInsets.all(NasTokens.spaceLg),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AspectRatio(
                          aspectRatio: 1,
                          child: local
                              ? _localArtwork(ep.coverUrl, scheme)
                              : _blocks.isNotEmpty || _scriptLoading
                                  ? _scriptPanel(scheme)
                                  : _artwork(scheme),
                        ),
                        const SizedBox(height: NasTokens.spaceLg),
                        Text(
                          ep.title,
                          maxLines: 2,
                          textAlign: TextAlign.center,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: NasTokens.fontTitle,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: NasTokens.spaceXs),
                        Text(
                          local
                              ? formatDurationMs(total)
                              : [
                                  formatDateTimeSec(ep.createdAt),
                                  formatDurationMs(total),
                                  tr('blog.episodes.items', {'count': ep.itemCount}),
                                ].join(' · '),
                          style: TextStyle(
                            fontSize: NasTokens.fontCaption,
                            color: context.nasTextSecondary,
                          ),
                        ),
                        const SizedBox(height: NasTokens.spaceLg),
                        Slider(
                          value: _dragValue ?? (total > 0 ? (pos / total).clamp(0.0, 1.0) : 0.0),
                          onChanged: total > 0
                              ? (v) => setState(() => _dragValue = v)
                              : null,
                          onChangeEnd: total > 0
                              ? (v) {
                                  p.seek(Duration(milliseconds: (total * v).round()));
                                  setState(() => _dragValue = null);
                                }
                              : null,
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(formatDurationMs(shown)),
                              Text(formatDurationMs(total)),
                            ],
                          ),
                        ),
                        const SizedBox(height: NasTokens.spaceMd),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            TextButton(
                              onPressed: () {
                                final i = _rates.indexOf(p.rate);
                                p.setRate(_rates[(i + 1) % _rates.length]);
                              },
                              child: Text('${p.rate.toStringAsFixed(2).replaceAll(RegExp(r'0$'), '')}x'),
                            ),
                            IconButton(
                              tooltip: tr('blog.player.prev'),
                              onPressed: p.queue.isEmpty ? null : p.prev,
                              icon: const Icon(Icons.skip_previous),
                            ),
                            const SizedBox(width: NasTokens.spaceSm),
                            // 颜色写死：`IconButton.filled` 默认取 onPrimary，
                            // 主题一旦把它覆盖成主色，图标就和底色糊在一起看不见了；
                            // loading 时的转圈同理，必须用白色才看得见「正在加载」。
                            IconButton.filled(
                              tooltip: p.playing
                                  ? tr('blog.player.pause')
                                  : tr('blog.player.play'),
                              onPressed: p.toggle,
                              iconSize: 40,
                              style: IconButton.styleFrom(
                                backgroundColor: scheme.primary,
                                foregroundColor: Colors.white,
                                disabledBackgroundColor:
                                    scheme.primary.withValues(alpha: 0.6),
                                disabledForegroundColor: Colors.white,
                              ),
                              icon: p.loading
                                  ? const SizedBox(
                                      width: 24,
                                      height: 24,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : Icon(
                                      p.playing ? Icons.pause : Icons.play_arrow,
                                      color: Colors.white,
                                    ),
                            ),
                            const SizedBox(width: NasTokens.spaceSm),
                            IconButton(
                              tooltip: tr('blog.player.next'),
                              onPressed: p.queue.isEmpty ? null : p.next,
                              icon: const Icon(Icons.skip_next),
                            ),
                            TextButton.icon(
                              onPressed: () => showBlogQueueSheet(context, p),
                              icon: const Icon(Icons.queue_music, size: 18),
                              label: Text('${p.index + 1} / ${p.queue.length}'),
                            ),
                          ],
                        ),
                        if (p.error != null)
                          Padding(
                            padding: const EdgeInsets.only(top: NasTokens.spaceMd),
                            child: Text(
                              p.error!,
                              style: const TextStyle(
                                color: Color(NasTokens.colorDanger),
                                fontSize: NasTokens.fontCaption,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
    );
  }

  /// 非新闻 / 稿子还没到：原来的品牌色块
  Widget _artwork(ColorScheme scheme) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(NasTokens.radiusLg),
        gradient: LinearGradient(
          colors: [scheme.primaryContainer, scheme.tertiaryContainer],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Icon(
        Icons.podcasts,
        size: 96,
        color: scheme.onPrimaryContainer,
      ),
    );
  }

  /// 本地博客：有同名图片就整块铺满封面，没有就用统一的博客图标（与列表页一致）
  Widget _localArtwork(String? coverUrl, ColorScheme scheme) {
    if (coverUrl == null || coverUrl.isEmpty) {
      return Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(NasTokens.radiusLg),
          gradient: LinearGradient(
            colors: [scheme.primaryContainer, scheme.tertiaryContainer],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Icon(
          Icons.podcasts,
          size: 96,
          color: scheme.onPrimaryContainer,
        ),
      );
    }
    return NasCoverImage(
      url: coverUrl,
      icon: Icons.podcasts,
      cacheWidth: 1024,
      borderRadius: NasTokens.radiusLg,
    );
  }

  /// 新闻稿面板：整块方形区域变成可滚动的播报稿，跟着进度高亮当前这一条
  Widget _scriptPanel(ColorScheme scheme) {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(NasTokens.radiusLg),
        gradient: LinearGradient(
          colors: [scheme.primaryContainer, scheme.tertiaryContainer],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: _scriptLoading
          ? const Center(
              child: SizedBox(
                width: 26,
                height: 26,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              ),
            )
          : SingleChildScrollView(
              controller: _scriptScroll,
              padding: const EdgeInsets.all(NasTokens.spaceMd),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < _blocks.length; i += 1)
                    _scriptBlock(i, active: i == _activeBlock),
                ],
              ),
            ),
    );
  }

  Widget _scriptBlock(int index, {required bool active}) {
    final block = _blocks[index];
    final key = _blockKeys.putIfAbsent(index, () => GlobalKey());
    return AnimatedContainer(
      key: key,
      duration: const Duration(milliseconds: 200),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: active ? Colors.white.withValues(alpha: 0.22) : Colors.transparent,
        borderRadius: BorderRadius.circular(NasTokens.radiusSm),
        border: Border.all(
          color: active ? Colors.white.withValues(alpha: 0.55) : Colors.transparent,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            block.title,
            style: TextStyle(
              color: Colors.white,
              fontSize: 13,
              height: 1.45,
              fontWeight: active ? FontWeight.w700 : FontWeight.w600,
            ),
          ),
          if (block.body.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              block.body,
              style: TextStyle(
                color: Colors.white.withValues(alpha: active ? 0.92 : 0.7),
                fontSize: 12,
                height: 1.5,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 播报稿里的一段：`title` 是这一条的首段（播报头 / 分类头），`body` 是正文
class _ScriptBlock {
  const _ScriptBlock({required this.title, required this.body});

  final String title;
  final String body;

  /// 估算时长用的字数权重：空白不算，标点影响很小可以忽略
  int get weight => '$title$body'.replaceAll(RegExp(r'\s'), '').length;
}
