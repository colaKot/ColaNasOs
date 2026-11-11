/// 影视详情体系（电影 / 剧集总览 / 季详情）的公共零件。
///
/// 为什么单独一份：三个页面除了「中间放季列表还是集列表」之外，头部、板块、
/// 演职、文件信息完全同构；各写一份必然改一处漏一处（这是音乐详情重构后
/// 定下的规矩，影视这边照抄同一套设计语言）。
///
/// 断点一律走 `layoutFor()`（600 / 1024），与音乐页同一个口子，不另立标准。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../video_card.dart';

/// 演职人员名清洗（原在 `cola_video_detail_page.dart`，挪过来给三页共用）。
///
/// NFO / 刮削偶尔把「名字 头像地址 TMDB-id」拼成一整串塞进 actors / directors，
/// 直接展示会把整条 URL 打到页面上，拿去当演员筛选条件也永远匹配不到。
/// 只剥掉地址与纯数字 id，**不动名字里的空格**（`Grace Chan` 这种必须原样保留）。
String videoPersonName(String raw) {
  var s = raw.trim();
  s = s.replaceAll(RegExp(r'\s*https?://\S+'), '');
  s = s.replaceAll(RegExp(r'\s+\d{3,}$'), '');
  return s.trim();
}

/// 一个演职人员条目（三页通用）。
///
/// `role` 是「导演 / 演员」这类**职位**；将来服务端把 NFO `<role>` /
/// TMDB `character` 落库后，这里会直接显示「饰 杰森·海斯」，界面不用改。
class VideoPerson {
  const VideoPerson({
    required this.name,
    required this.role,
    this.avatarUrl,
    this.isDirector = false,
  });

  final String name;
  final String role;
  final String? avatarUrl;
  final bool isDirector;
}

/// 从一条影片 + 演员头像表（`/video/actor/avatars` 的返回）拼出演职列表。
///
/// 排序按 PRD：**导演在前，演员在后**，各自保持库里的先后（= 番位）。
/// 头像表里若带 `role` 字段（服务端补角色名后就会有）优先用它。
List<VideoPerson> videoPeopleOf(
  VideoItem item, {
  Map<String, Map<String, dynamic>> avatarInfo = const {},
}) {
  final out = <VideoPerson>[];
  final seen = <String>{};

  void add(String raw, {required bool director}) {
    final name = videoPersonName(raw);
    if (name.isEmpty || !seen.add('$director:$name')) return;
    final info = avatarInfo[name];
    final avatar = '${info?['avatarUrl'] ?? ''}'.trim();
    final extraRole = '${info?['role'] ?? ''}'.trim();
    out.add(
      VideoPerson(
        name: name,
        role: extraRole.isNotEmpty
            ? extraRole
            : tr(director ? 'video.detail.director' : 'video.detail.actor'),
        avatarUrl: avatar.isEmpty ? null : avatar,
        isDirector: director,
      ),
    );
  }

  for (final n in item.directors) {
    add(n, director: true);
  }
  for (final n in item.actors) {
    add(n, director: false);
  }
  return out;
}

/// 画质小标签（4K / HDR / DV / Atmos）：圆角小胶囊，与正文文字区隔。
class VideoTagBadge extends StatelessWidget {
  const VideoTagBadge(this.text, {super.key, this.accent = false});

  final String text;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: accent
            ? scheme.primary.withValues(alpha: 0.14)
            : scheme.surfaceContainerHighest.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          height: 1.2,
          fontWeight: FontWeight.w700,
          color: accent
              ? scheme.primary
              : scheme.onSurface.withValues(alpha: 0.86),
        ),
      ),
    );
  }
}

/// 统一详情头部：**左竖版海报 + 右信息**（标题 / 原文名 / 元信息 / 画质标签 / 操作）。
///
/// 三页共用一份，海报宽度、字号、间距都随断点走：
/// 桌面 220、平板 176、窄屏取内容宽的 40%（PRD 的 220 / 40% 口径）。
/// 窄屏改为「海报在上、信息在下」的垂直排布（PRD 移动端降级）。
class VideoDetailHeader extends StatelessWidget {
  const VideoDetailHeader({
    super.key,
    required this.title,
    required this.mode,
    this.originalTitle,
    this.posterUrl,
    this.posterText,
    this.meta = const <String>[],
    this.badges = const <String>[],
    this.score = 0,
    this.actions,
    this.trailingReserve = 0,
  });

  final String title;

  /// 断点（由页面用 `layoutFor()` 算好传进来，避免嵌套 LayoutBuilder）
  final LayoutMode mode;

  /// 原文名 / 副标题（灰色小字，可为空）
  final String? originalTitle;
  final String? posterUrl;

  /// 海报加载失败时的占位文字（一般传片名）
  final String? posterText;

  /// 元信息行：年份 / 类型 / 地区 / 时长 / 集数……（用 ` · ` 连接）
  final List<String> meta;

  /// 画质标签：4K / HDR / DV / Atmos
  final List<String> badges;

  final double score;

  /// 操作按钮组（播放 / 收藏 / 已看 / 更多）
  final Widget? actions;

  /// 标题行右侧要让出的宽度（嵌入模式右上角浮层胶囊会压住内容）
  final double trailingReserve;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final width = c.maxWidth;
        final posterW = switch (mode) {
          LayoutMode.expanded => 220.0,
          LayoutMode.medium => 176.0,
          LayoutMode.compact => (width * 0.4).clamp(112.0, 150.0),
        };
        final titleSize = switch (mode) {
          LayoutMode.expanded => 26.0,
          LayoutMode.medium => 24.0,
          LayoutMode.compact => 20.0,
        };
        final poster = _Poster(
          width: posterW,
          url: posterUrl,
          fallbackText: posterText ?? title,
        );
        final info = _info(context, titleSize);

        if (mode == LayoutMode.compact) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[poster, const SizedBox(height: 14), info],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            poster,
            SizedBox(width: mode == LayoutMode.expanded ? 22 : 14),
            Expanded(child: info),
          ],
        );
      },
    );
  }

  Widget _info(BuildContext context, double titleSize) {
    final scheme = Theme.of(context).colorScheme;
    final secondary = TextStyle(
      fontSize: NasTokens.fontCaption,
      color: context.nasTextSecondary,
    );
    final original = (originalTitle ?? '').trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: EdgeInsets.only(right: trailingReserve),
          child: Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: titleSize,
              height: 1.2,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        if (original.isNotEmpty && original != title) ...<Widget>[
          const SizedBox(height: 3),
          Text(
            original,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: secondary,
          ),
        ],
        if (meta.isNotEmpty || score > 0) ...<Widget>[
          const SizedBox(height: 8),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              if (score > 0) ...<Widget>[
                Text(
                  '★ ${score.toStringAsFixed(1)}',
                  style: TextStyle(
                    fontSize: NasTokens.fontCaption,
                    fontWeight: FontWeight.w700,
                    color: scheme.primary,
                  ),
                ),
                if (meta.isNotEmpty) Text(' · ', style: secondary),
              ],
              for (var i = 0; i < meta.length; i++) ...<Widget>[
                if (i > 0) Text(' · ', style: secondary),
                Text(meta[i], style: secondary),
              ],
            ],
          ),
        ],
        if (badges.isNotEmpty) ...<Widget>[
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: <Widget>[for (final b in badges) VideoTagBadge(b)],
          ),
        ],
        if (actions != null) ...<Widget>[const SizedBox(height: 14), actions!],
      ],
    );
  }
}

class _Poster extends StatelessWidget {
  const _Poster({
    required this.width,
    required this.url,
    required this.fallbackText,
  });

  final double width;
  final String? url;
  final String fallbackText;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: width,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: scheme.shadow.withValues(alpha: 0.22),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: AspectRatio(
        aspectRatio: 2 / 3,
        child: NasCoverImage(
          url: url,
          headers: videoArtHeaders,
          fallbackText: fallbackText,
          icon: Icons.movie_outlined,
          cacheWidth: (width * 2).round(),
          borderRadius: 12,
        ),
      ),
    );
  }
}

/// 板块标题一行（可选右侧计数小字）。
///
/// 单独抽出来是给「标题与内容分属两个 sliver」的场景（集数网格要懒加载，
/// 不能和标题挤在一个 SliverToBoxAdapter 里）。
Widget videoSectionHead(
  BuildContext context,
  String title, {
  String? trailing,
}) {
  return Row(
    children: <Widget>[
      Text(
        title,
        style: const TextStyle(
          fontSize: NasTokens.fontSubtitle,
          fontWeight: FontWeight.w600,
        ),
      ),
      if ((trailing ?? '').isNotEmpty) ...<Widget>[
        const SizedBox(width: 8),
        Text(
          trailing!,
          style: TextStyle(
            fontSize: NasTokens.fontCaption,
            color: context.nasTextSecondary,
          ),
        ),
      ],
    ],
  );
}

/// 板块卡片：独立区块标题 + 内容容器（背景比页面底色深一级，圆角 8）。
///
/// 横向滚动类内容（演职 / 季卡）传 `cardPadding: EdgeInsets.zero`，
/// 让卡片内容自己带左右内边距，滚动时不会被卡片的圆角切掉。
class VideoSection extends StatelessWidget {
  const VideoSection({
    super.key,
    required this.title,
    required this.child,
    this.trailing,
    this.card = true,
    this.cardPadding = const EdgeInsets.all(14),
  });

  final String title;
  final String? trailing;
  final Widget child;
  final bool card;
  final EdgeInsetsGeometry cardPadding;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        videoSectionHead(context, title, trailing: trailing),
        const SizedBox(height: 10),
        if (!card)
          child
        else
          Container(
            width: double.infinity,
            padding: cardPadding,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.40),
              borderRadius: BorderRadius.circular(NasTokens.radiusMd),
            ),
            child: child,
          ),
      ],
    );
  }
}

/// 可折叠简介：默认 [maxLines] 行，**只有真的超出**才显示「展开 / 收起」。
///
/// 以前是「无脑给按钮」，短简介下面挂一个点了没反应的「展开」，很难看。
class VideoExpandableText extends StatefulWidget {
  const VideoExpandableText(
    this.text, {
    super.key,
    this.maxLines = 3,
    this.style,
  });

  final String text;
  final int maxLines;
  final TextStyle? style;

  @override
  State<VideoExpandableText> createState() => _VideoExpandableTextState();
}

class _VideoExpandableTextState extends State<VideoExpandableText> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final text = widget.text.trim();
    if (text.isEmpty) return const SizedBox.shrink();

    final style =
        widget.style ??
        TextStyle(
          fontSize: NasTokens.fontBody,
          height: 1.65,
          color: context.nasTextSecondary,
        );

    return LayoutBuilder(
      builder: (context, c) {
        final painter = TextPainter(
          text: TextSpan(text: text, style: style),
          maxLines: widget.maxLines,
          textDirection: Directionality.of(context),
        )..layout(maxWidth: c.maxWidth);
        final overflowing = painter.didExceedMaxLines;

        final body = AnimatedSize(
          duration: const Duration(milliseconds: 180),
          alignment: Alignment.topCenter,
          child: Text(
            text,
            style: style,
            maxLines: _expanded ? null : widget.maxLines,
            overflow: _expanded ? TextOverflow.visible : TextOverflow.ellipsis,
          ),
        );

        if (!overflowing) return body;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            body,
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  minimumSize: const Size(0, 30),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: () => setState(() => _expanded = !_expanded),
                child: Text(
                  tr(_expanded ? 'common.collapse' : 'common.expand'),
                  style: const TextStyle(fontSize: NasTokens.fontCaption),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 演职人员横向滚动列表：圆形头像 + 姓名 + 角色 / 职位。
class VideoActorRail extends StatelessWidget {
  const VideoActorRail({super.key, required this.people, this.onTap});

  final List<VideoPerson> people;
  final void Function(VideoPerson person)? onTap;

  static const double _cardH = 118;

  @override
  Widget build(BuildContext context) {
    if (people.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: _cardH,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
        itemCount: people.length,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (context, i) {
          final p = people[i];
          return _ActorCard(
            person: p,
            onTap: onTap == null ? null : () => onTap!(p),
          );
        },
      ),
    );
  }
}

class _ActorCard extends StatelessWidget {
  const _ActorCard({required this.person, this.onTap});

  final VideoPerson person;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return NasHoverBuilder(
      onTap: onTap,
      focusRadius: 12,
      builder: (hovered) => SizedBox(
        width: 80,
        child: Column(
          children: <Widget>[
            Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: hovered
                      ? scheme.primary.withValues(alpha: 0.6)
                      : Colors.transparent,
                ),
              ),
              padding: const EdgeInsets.all(2),
              child: ClipOval(
                child: SizedBox(
                  width: 64,
                  height: 64,
                  // 不要 fallbackText：没头像时会把名字按 64×64 画成巨字
                  child: NasCoverImage(
                    url: person.avatarUrl,
                    icon: Icons.person_outline,
                    cacheWidth: 128,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              person.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
            Text(
              person.role,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: NasTokens.fontMicro,
                color: person.isDirector
                    ? scheme.primary
                    : context.nasTextSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 文件与技术信息：**一个板块、三列**（基础 / 视频轨 / 音轨字幕）。
///
/// 以前是「文件信息」+「视频/音频/字幕三列」两张卡，路径和参数分开看很断；
/// PRD 要求收成一块，零散的播放器说明文字挪进「更多 → 关于」。
/// 窄屏自动退成一列堆叠。
class VideoFilePanel extends StatelessWidget {
  const VideoFilePanel({super.key, required this.item, required this.mode});

  final VideoItem item;
  final LayoutMode mode;

  /// 整片平均码率：库表没有码率列，`size × 8 ÷ 时长` 就是它。
  static double bitrateMbps(VideoItem item) {
    final ms = item.durationMs ?? 0;
    if (item.size <= 0 || ms <= 0) return 0;
    return (item.size * 8) / (ms / 1000) / 1000000;
  }

  @override
  Widget build(BuildContext context) {
    final unknown = tr('common.unknown');
    final w = item.width ?? 0;
    final h = item.height ?? 0;
    final mbps = bitrateMbps(item);

    Widget cell(String label, String value) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label,
            style: TextStyle(
              fontSize: NasTokens.fontMicro,
              color: context.nasTextSecondary,
            ),
          ),
          const SizedBox(height: 2),
          SelectableText(
            value,
            style: const TextStyle(
              fontSize: NasTokens.fontCaption,
              height: 1.35,
            ),
          ),
        ],
      ),
    );

    Widget group(String title, IconData icon, List<Widget> cells) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(icon, size: 14, color: context.nasTextSecondary),
              const SizedBox(width: 5),
              Text(
                title,
                style: TextStyle(
                  fontSize: NasTokens.fontMicro,
                  fontWeight: FontWeight.w600,
                  color: context.nasTextSecondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ...cells,
        ],
      );
    }

    final basics = <Widget>[
      cell(
        tr('video.detail.fileSize'),
        item.size > 0 ? formatBytes(item.size) : unknown,
      ),
      cell(
        tr('video.detail.format'),
        item.container.trim().isEmpty ? unknown : item.container.toUpperCase(),
      ),
      cell(
        tr('video.detail.source'),
        '${item.nfoSource ?? ''}'.trim().isEmpty ? 'none' : '${item.nfoSource}',
      ),
    ];

    final video = <Widget>[
      cell(tr('video.detail.resolution'), w > 0 && h > 0 ? '$w×$h' : unknown),
      cell(
        tr('video.detail.codec'),
        (item.videoCodec ?? '').trim().isEmpty
            ? unknown
            : item.videoCodec!.toUpperCase(),
      ),
      cell(
        tr('video.detail.bitrate'),
        mbps > 0 ? '${mbps.toStringAsFixed(2)} Mbps' : unknown,
      ),
    ];

    final audio = <Widget>[
      cell(
        tr('video.detail.trackAudio'),
        (item.audioCodec ?? '').trim().isEmpty
            ? unknown
            : item.audioCodec!.toUpperCase(),
      ),
      cell(
        tr('video.detail.subtitleType'),
        item.hasSubtitle ? tr('ui.video.hbe1c0c') : tr('ui.video.h720777'),
      ),
    ];

    final groups = <Widget>[
      group(tr('video.detail.baseInfo'), Icons.folder_outlined, basics),
      group(tr('video.detail.trackVideo'), Icons.movie_outlined, video),
      group(tr('video.detail.audioSub'), Icons.audiotrack_outlined, audio),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _PathRow(path: item.path),
        const SizedBox(height: 12),
        if (mode == LayoutMode.compact)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              for (var i = 0; i < groups.length; i++) ...<Widget>[
                if (i > 0) const SizedBox(height: 12),
                groups[i],
              ],
            ],
          )
        else
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(child: groups[0]),
              const SizedBox(width: 12),
              Expanded(child: groups[1]),
              const SizedBox(width: 12),
              Expanded(child: groups[2]),
            ],
          ),
      ],
    );
  }
}

/// 文件路径一行：超长自动省略；桌面 hover 出完整路径（Tooltip），
/// 右侧一键复制（移动端没有 hover，复制按钮就是它的等价入口）。
class _PathRow extends StatelessWidget {
  const _PathRow({required this.path});

  final String path;

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: path));
    if (!context.mounted) return;
    NasSnack.show(context, tr('common.pathCopied'));
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                tr('video.detail.fileLocation'),
                style: TextStyle(
                  fontSize: NasTokens.fontMicro,
                  color: context.nasTextSecondary,
                ),
              ),
              const SizedBox(height: 2),
              Tooltip(
                message: path,
                waitDuration: const Duration(milliseconds: 500),
                child: Text(
                  path,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: NasTokens.fontCaption,
                    height: 1.35,
                  ),
                ),
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: tr('common.copy'),
          visualDensity: VisualDensity.compact,
          onPressed: () => _copy(context),
          icon: const Icon(Icons.copy_all_outlined, size: 18),
        ),
      ],
    );
  }
}

/// 详情骨架屏：海报 + 标题 + 三块内容的大致形状，避免白屏闪一下。
///
/// 刻意不做 shimmer（与 `NasSkeleton` 保持一致的口径）。
class VideoDetailSkeleton extends StatelessWidget {
  const VideoDetailSkeleton({super.key, required this.mode});

  final LayoutMode mode;

  Widget _box(BuildContext context, double w, double h, {double r = 8}) {
    return Container(
      width: w,
      height: h,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(r),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final compact = mode == LayoutMode.compact;
    final posterW = switch (mode) {
      LayoutMode.expanded => 220.0,
      LayoutMode.medium => 176.0,
      LayoutMode.compact => 132.0,
    };

    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _box(context, compact ? 180 : 240, compact ? 22 : 28),
        const SizedBox(height: 10),
        _box(context, 140, 12),
        const SizedBox(height: 14),
        _box(context, compact ? 220 : 320, 12),
        const SizedBox(height: 16),
        _box(context, 128, 38, r: 999),
      ],
    );

    final poster = _box(context, posterW, posterW * 1.5, r: 12);

    return SingleChildScrollView(
      physics: const NeverScrollableScrollPhysics(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (compact) ...<Widget>[
            poster,
            const SizedBox(height: 14),
            info,
          ] else
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                poster,
                const SizedBox(width: 18),
                Expanded(child: info),
              ],
            ),
          for (var i = 0; i < 3; i++) ...<Widget>[
            const SizedBox(height: 24),
            _box(context, 96, 16),
            const SizedBox(height: 10),
            _box(context, double.infinity, i == 1 ? 118 : 92, r: 8),
          ],
        ],
      ),
    );
  }
}

/// 集数数字网格（Sliver 版）：方形号码块，选中主色填充、已看带 ✓、hover 提亮。
///
/// 用 sliver 而不是 `Wrap` / `GridView(shrinkWrap: true)`：
/// 50 集以上的剧一次性铺完会让滚动掉帧，sliver 只建可见的那几行。
///
/// **点一下就走**（用户 2026-11-11 19:24 要求）：点集数立刻开播，
/// 不做「先选中、再点一次才播」那套两步交互——点集就是想看那一集。
/// `selectedId` 只用来高亮「当前这一集」（= 本页所属的那一集，或刚播过的那一集），
/// 文件信息面板也跟它走。
SliverPadding videoEpisodeGridSliver({
  required List<VideoItem> episodes,
  required String? selectedId,
  required void Function(VideoItem ep) onPlay,
  required EdgeInsetsGeometry padding,
  List<NasMenuEntry> Function(VideoItem ep)? menuEntries,
}) {
  return SliverPadding(
    padding: padding,
    sliver: SliverGrid(
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 64,
        mainAxisExtent: 44,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      delegate: SliverChildBuilderDelegate((context, i) {
        final ep = episodes[i];
        final cell = _EpisodeNumberCell(
          number: ep.episode ?? (i + 1),
          watched: ep.watched,
          selected: ep.id == selectedId,
          onTap: () => onPlay(ep),
        );
        final menu = menuEntries?.call(ep) ?? const <NasMenuEntry>[];
        final wrapped = menu.isEmpty
            ? cell
            : NasContextMenuRegion(entries: menu, child: cell);
        return Tooltip(message: ep.title, child: wrapped);
      }, childCount: episodes.length),
    ),
  );
}

class _EpisodeNumberCell extends StatefulWidget {
  const _EpisodeNumberCell({
    required this.number,
    required this.watched,
    required this.selected,
    required this.onTap,
  });

  final int number;
  final bool watched;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_EpisodeNumberCell> createState() => _EpisodeNumberCellState();
}

class _EpisodeNumberCellState extends State<_EpisodeNumberCell> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final selected = widget.selected;
    final base = scheme.surfaceContainerHighest.withValues(alpha: 0.7);
    final color = selected
        ? scheme.primary
        : (_hovered
              ? scheme.surfaceContainerHighest
              : (widget.watched ? base.withValues(alpha: 0.45) : base));
    final fg = selected
        ? scheme.onPrimary
        : (widget.watched
              ? scheme.onSurface.withValues(alpha: 0.55)
              : scheme.onSurface);

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: NasTokens.durationFast),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(NasTokens.radiusMd),
            border: selected
                ? null
                : Border.all(
                    color: widget.watched
                        ? scheme.primary.withValues(alpha: 0.35)
                        : Colors.transparent,
                  ),
          ),
          child: Stack(
            alignment: Alignment.center,
            children: <Widget>[
              Text(
                '${widget.number}',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: fg,
                ),
              ),
              if (widget.watched && !selected)
                Positioned(
                  top: 2,
                  right: 3,
                  child: Icon(
                    Icons.check,
                    size: 11,
                    color: scheme.primary.withValues(alpha: 0.9),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
