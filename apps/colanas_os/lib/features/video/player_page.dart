import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/codec_support.dart';
import '../../core/play_preferences.dart';
import '../../core/play_quality.dart';
import '../../core/play_quality_scope.dart';
import '../../core/play_timeline.dart';
import '../../core/session.dart';
import '../../core/settings_store.dart';
import '../../core/video_subtitle_prefs.dart';
import 'player_screen.dart';

/// 内置播放器：media_kit 作为跨平台内核，**控制层全部自绘**。
///
/// 之前直接套 SDK 默认控件，右下角一个参数项都没有，画质/码率只能在详情页
/// 「更多 → 转码」里选一次、播放中不能改；倍速、音轨、铺满、列表、信息全缺。
///
/// 底部右侧固定顺序（从左到右）：倍速 · 画质 · 字幕 · 音轨 · 音量 · 播放列表 ·
/// 信息 · 设置 · 全屏，窄屏把后六项收进「更多」。
/// 原来还挂了一个「画面比例（铺满/适应）」按钮，2026-11-05 按要求去掉：
/// 铺满会裁掉画面边缘，而 HDR 片源本来就要靠 tonemap 保住高光，裁切得不偿失。
///
/// 杜比 / HDR / HEVC / EAC3：stream-url 会带 `compat.needTranscode`。命中时
/// 自动建 HLS 转码会话（服务端做 HDR→SDR + yuv420p + BT.709 + AAC），
/// 用户不用自己去找「转码播放」，也避免把原流原样丢给浏览器导致黑屏发灰。
class PlayerPage extends StatefulWidget {
  const PlayerPage({
    super.key,
    required this.url,
    this.title,
    this.itemId,
    this.compat,
    this.initialPreset,
    this.durationMs,
    this.sourceHeight,
    this.sourceBytes,
    this.initialSessionId,
  });

  /// 带短期令牌的原画直链（`/api/v1/video/stream-url` 签发）
  final String url;
  final String? title;

  /// 片源总时长（库里的元数据）。
  ///
  /// 边转边播的 HLS 是 EVENT 播放列表，`#EXT-X-ENDLIST` 写完之前 `<video>.duration`
  /// 是 `Infinity`，media_kit 会折成 `-9007199254740990` 毫秒。进度条不能拿这个
  /// 当总长，所以这里带一份片源时长兜底。
  final int? durationMs;

  /// 影片 id：用于拉外挂字幕 / 建转码会话；为空则只当纯 URL 播放器
  final String? itemId;

  /// `VideoStreamUrlResponse.compat`：媒体兼容判定
  final Map<String, dynamic>? compat;

  /// 从详情页「转码」入口进来时，url 已经是某个档位的 HLS 会话；
  /// 传这个档位是为了让画质菜单显示真实档位、换档时不再误用直链。
  final String? initialPreset;

  /// 片源高度（像素）。画质菜单按它收敛：转不出 1080p 的片就不列 1080P。
  /// 直链进来时 `compat.height` 也有，两者取先有的那个。
  final int? sourceHeight;

  /// 片源字节数。媒体信息面板用它算「源码率 → 目标码率」
  /// （库表没有码率列，`size ÷ duration` 就是整片平均码率）。
  final int? sourceBytes;

  /// 从详情页「转码」入口进来时已经建好的会话 id —— 有了它，
  /// 媒体信息面板才能查「转码中 / 完成」和实际编码（否则只剩本地猜）。
  final String? initialSessionId;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  late final Player _player;
  late final VideoController _controller;

  String? _error;
  late String _url;
  late String _directUrl;
  int _renewTries = 0;
  bool _renewing = false;

  List<VideoSubtitleFile> _subs = const [];
  String? _activeSub;

  /// 当前字幕的结构化 cue。字幕由控制层按播放位置自绘，不再交给
  /// media_kit 的 `SubtitleTrack.data`（Web 端会在 open 时清空 `<track>`，
  /// 且切换字幕永远读 `textTracks[0]`）。
  List<VideoSubtitleCue> _cues = const [];

  late String _preset;
  /// 当前编码：用用户偏好，但本机解不出来时回落 H.264。
  String _codec = codecPlayable(PlayPreferences.codec)
      ? PlayPreferences.codec
      : 'h264';
  int _audioIndex = 0;
  double _rate = 1.0;
  double _volume = 100.0;

  /// 画面填充方式。**没有 UI 入口**：铺满（cover）会裁掉画面边缘，而 HDR 片源
  /// 本来就要靠 tonemap 保住高光，裁切得不偿失，2026-11-05 按用户要求去掉按钮。
  /// 字段留着是因为 `Video(fit:)` 还要传，且别处可能按需覆盖。
  final BoxFit _fit = BoxFit.contain;
  PlaylistMode _loop = PlaylistMode.none;
  bool _shuffle = false;
  bool _isTranscode = false;
  bool _preparing = false;
  bool _switching = false;
  bool _boosting = false;
  bool _controls = true;
  bool _locked = false;
  bool _immersive = false;
  Timer? _hideTimer;

  /// 当前转码会话（只有转码时才有）。媒体信息面板要显示
  /// 「是否转码中」和「实际用了什么编码」—— 实际编码是服务端读
  /// sidecar 首片自报的结果，用户请求的 AV1 可能已经降级成 H.264 了。
  String? _sessionId;
  String? _jobStatus;

  /// 服务端回传的**实际**编码（降级后以它为准）；为空表示还没出片。
  String? _actualCodec;

  /// 上次刷新隐藏定时器的时间，用来给 `onHover` 做节流。
  DateTime _lastPoke = DateTime.fromMillisecondsSinceEpoch(0);

  /// 本次播放内不再缓存会话地址：服务端建会话时会把同一部片还在跑的旧会话
  /// 取消掉（换档），本地缓存拿到的可能是已取消的半个播放列表。
  /// 已转完的档位由服务端 `dupe` 直接复用，多一次请求但不会拿到坏地址。

  /// 浏览器 `<video>` 只认这几类容器；MKV / AVI / RMVB / TS 交给 Chromium
  /// 只会报 `DEMUXER_ERROR_COULD_NOT_PARSE`。桌面 mpv 不受此限。
  static const _webContainers = {'mp4', 'm4v', 'mov', 'webm', 'ogv', 'ogg'};

  bool get _needTranscode {
    final compat = widget.compat;
    // 没有 compat 说明调用方已经指定了播放地址（如详情页的「转码」对话框），
    // 此时不该再自己建会话，否则会丢掉字幕等转码参数。
    if (compat == null) return false;
    if (compat['needTranscode'] == true) return true;
    if (!kIsWeb) return false;
    final c = (compat['container'] as String? ?? '').toLowerCase();
    return c.isNotEmpty && !_webContainers.contains(c);
  }

  List<String> get _reasons =>
      ((widget.compat?['reasons'] as List?) ?? const []).map((e) => '$e').toList();

  /// 片源高度：显式参数优先，其次 stream-url 的 compat，最后当未知（0）。
  int get _srcHeight {
    final h = widget.sourceHeight ?? (widget.compat?['height'] as int?);
    return h == null || h <= 0 ? 0 : h;
  }

  String get _reasonText {
    if (_reasons.isEmpty) return tr('player.hdr');
    return _reasons
        .map((r) {
          final key = 'player.reason.$r';
          // 未登记的 reason 直接回原文，别在界面上显示键名
          final text = tr(key);
          return text == key ? r : text;
        })
        .join(' / ');
  }

  @override
  void initState() {
    super.initState();
    // 偏好档位先按片源收敛：片源只有 720p 时，1080P 档转出来只是放大后的
    // 假高清，白白多花一倍流量。收敛放在建会话之前，界面显示的档位才和实际一致。
    _preset = clampPresetForSource(
      widget.initialPreset ?? PlayPreferences.preset,
      _srcHeight,
      codec: _codec,
    );
    // 详情页「转码」入口给的已经是 HLS 地址，不能再当直链处理
    _isTranscode = widget.initialPreset != null;
    _sessionId = widget.initialSessionId;
    // 会话是调用方建的，状态得自己盯：不然面板上永远是「转码中」
    if (_sessionId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _sessionId != null) _watchSession(_sessionId!);
      });
    }
    _url = widget.url;
    _directUrl = widget.url;
    _player = Player();
    _controller = VideoController(_player);
    _loadUiPrefs();

    _player.stream.error.listen((message) {
      if (!mounted) return;
      setState(() => _error = message);
      _renewIfTokenExpired(message);
    });

    // initState 里不能取 ScaffoldMessenger 这类 InheritedWidget：
    // dependOnInheritedWidgetOfExactType 要求 initState 已经走完，否则
    // _prepareCompatible 的第一行就会抛「called before initState() completed」，
    // 连带转码会话与 open() 全都不执行（黑屏）。统一推到首帧之后再启动。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_needTranscode && widget.itemId != null) {
        // 「原画」在必须转码时等价于「不降分辨率」，直接按 4K/原尺寸转太慢；
        // 统一收敛到默认档位（并再按片源高度收一次），界面显示的档位也才是
        // 真正在跑的档位。
        if (_preset == 'original') {
          _preset = clampPresetForSource(defaultPlayPreset, _srcHeight, codec: _codec);
        }
        _prepareCompatible();
      } else {
        _openUrl(_url);
      }
      _loadSubtitles();
      _resetHideTimer();
    });
  }

  void _loadUiPrefs() {
    final store = SettingsStore.instance;
    final rate = double.tryParse(store.getString('player.speed') ?? '');
    if (rate != null && rate > 0) _rate = rate;
    final vol = double.tryParse(store.getString('player.volume') ?? '');
    if (vol != null && vol >= 0 && vol <= 100) _volume = vol;
    // `player.fitCover` 不再读：铺满按钮已去掉，老用户存过的 cover 值不该继续生效，
    // 否则画面永远是裁切过的，而且界面上已经没有办法改回来。
  }

  Future<void> _saveUiPrefs() async {
    final store = SettingsStore.instance;
    await store.setString('player.speed', '$_rate');
    await store.setString('player.volume', '$_volume');
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _player.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------ 播放源

  Future<void> _openUrl(String u, {Duration? seekTo, int retries = 0}) async {
    _url = u;
    try {
      await _player.open(Media(u));
      // 字幕走控制层自绘；关掉内核自带字幕轨，避免内嵌字幕再叠一层。
      // 自绘的 cue 是 State 字段，重开 Media 不需要重新挂载。
      try {
        await _player.setSubtitleTrack(SubtitleTrack.no());
      } catch (_) {
        /* 部分平台没有字幕轨接口，忽略 */
      }
      await _player.setRate(_rate);
      await _player.setVolume(_volume);
      await _player.setPlaylistMode(_loop);
      await _player.setShuffle(_shuffle);
      if (seekTo != null && seekTo > Duration.zero) {
        // HLS 首帧就绪前 seek 会被吞掉，等一小拍再跳
        await Future<void>.delayed(const Duration(milliseconds: 350));
        await _player.seek(seekTo);
      }
      if (mounted) setState(() => _error = null);
    } catch (e) {
      // 边转边播的第一次打开会「打不开」：播放器拉 index.m3u8 时首片可能还没落盘
      // （服务端最多等 15s，超时就先给空 EVENT 列表），内核当场就报错退出。
      // 转码本身没失败，过一两秒分片就有了 —— 直接弹「播放失败」太冤。
      // 《匹诺曹》这种 4K DV 片首片要 5s 上下（HDR→SDR + 4K 解码初始化），
      // 正是最容易踩到这条的片源。重试 2 次（+3s）能给足首片时间。
      if (retries > 0 && _isTranscode && mounted) {
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        if (!mounted) return;
        return _openUrl(u, seekTo: seekTo, retries: retries - 1);
      }
      if (mounted) setState(() => _error = e.toString());
      _renewIfTokenExpired(e.toString());
    }
  }

  /// 拿到某个 preset/codec 的 HLS 地址。
  ///
  /// 服务端用 EVENT 播放列表边转边播：第一个分片落盘时 index.m3u8 就可读，
  /// 所以这里创建完会话立刻返回地址起播，**不再轮询到 done**（全片转码一次
  /// 实测 254s 起，4K/AV1 更久，等完再把流丢给播放器就是长时间黑屏）。
  /// 已转完的同参会话由服务端 `dupe` 直接复用，不在客户端缓存地址。
  Future<String> _ensureTranscode(String preset, String codec) async {
    final id = widget.itemId!;
    // 请求的编码在本机解不出来时回落 H.264（桌面端一律解得出来，浏览器由
    // `MediaSource.isTypeSupported` 说了算 —— 真 Chrome 上 AV1 / HEVC 都是支持的）。
    final outCodec = codecPlayable(codec) ? codec : 'h264';
    final created = await ApiSession.instance.client.playerSessionCreate(
      body: PlayerSessionCreateBody(
        id: id,
        preset: preset,
        codec: outCodec,
        audioIndex: _audioIndex,
        // 只让服务端按片源标记决定 HDR→SDR。以前这里跟 needTranscode 一起传
        // true，会把普通 SDR 片也塞进 tonemap 链：zscale 报「no path between
        // colorspaces」，多绕两次失败重试，起播更慢。
        forceSdr: null,
        audioNormalize: PlayPreferences.audioNormalize ? true : null,
        audioDownmix: PlayPreferences.audioDownmix ? true : null,
      ),
    );
    final u = created.url.startsWith('http')
        ? created.url
        : '${ApiSession.instance.baseUrl}${created.url}';
    // 记下会话：媒体信息面板要拿它查「转码中 / 完成」和实际编码
    _sessionId = created.id;
    _jobStatus = null;
    // 实际编码换会话后必须清空，否则换了档还显示上一轮的结果
    _actualCodec = null;
    // 后台只盯失败：转码挂了要明确说出来，别让用户对着无限缓冲猜。
    _watchSession(created.id);
    return u;
  }

  /// 后台盯会话状态：失败要明确说出来，成功就静默结束。
  ///
  /// 顺手把「转码中 / 完成」和**实际编码**写进 State：媒体信息面板直接读这两个
  /// 字段。用户选的 AV1 可能已经被服务端降级成 H.264（编码器起不来 / 硬编不支持），
  /// 面板必须显示真的那个，否则就是「我设了 AV1，为什么跑的是 264」。
  Future<void> _watchSession(String id) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    for (var i = 0; i < 120; i++) {
      await Future<void>.delayed(const Duration(seconds: 5));
      // 换档 / 换片后旧会话的轮询要立刻停手，否则会把新会话的字段覆盖成旧值
      if (!mounted || _sessionId != id) return;
      try {
        final job = await ApiSession.instance.client.playerSessionGet(id: id);
        if (!mounted || _sessionId != id) return;
        final st = '${job.status}';
        final codec = job.codec ?? '';
        setState(() {
          _jobStatus = st;
          if (codec.isNotEmpty) _actualCodec = codec;
        });
        if (st == 'done' || st == 'canceled') return;
        if (st == 'failed') {
          if (messenger != null) {
            NasSnack.showOn(
              messenger,
              '${tr('player.playFailed')}: ${job.error ?? 'transcode failed'}',
              error: true,
            );
          }
          return;
        }
      } catch (_) {
        return;
      }
    }
  }

  Future<void> _prepareCompatible() async {
    setState(() => _preparing = true);
    try {
      final u = await _ensureTranscode(_preset, _codec);
      if (!mounted) return;
      setState(() {
        _preparing = false;
        _isTranscode = true;
      });
      // retries: 首片还没落盘时内核会「打不开」，不是转码失败，给两次重试
      await _openUrl(u, retries: 2);
    } catch (e) {
      if (!mounted) return;
      // 不能退回直链：走到这里就说明片源直链本来解不了（HEVC / MKV / HDR），
      // 退回直链只会再报一次 DEMUXER_ERROR，把真正的失败原因盖掉。
      setState(() {
        _preparing = false;
        _error = tr('player.switchFailed', {'error': '$e'});
      });
    }
  }

  Future<void> _switchQuality(String preset, {String? codec}) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final targetCodec = codec ?? _codec;
    // 直链要求：调用方给的是真直链（compat 存在）且片源本身能直链。
    // 详情页「转码」入口拿的是 HLS 地址（compat=null），那里不存在直链可退。
    final toDirect = preset == 'original' && widget.compat != null && !_needTranscode;
    if (!toDirect && widget.itemId == null) return;
    // 必须转码时「原画」没法真原样播，实际跑默认档；界面也跟着显示实际档位，
    // 不要出现「显示原画、跑的是 1080p」。同样按片源高度收敛。
    final effective = preset == 'original' && !toDirect
        ? clampPresetForSource(defaultPlayPreset, _srcHeight, codec: targetCodec)
        : preset;
    final pos = _player.state.position;
    setState(() => _switching = true);
    try {
      // 服务端建新会话会取消这部片还在排队 / 正在转的旧会话，
      // 所以换档不会让上一档的转码继续占 CPU。
      final u = toDirect
          ? _directUrl
          : await _ensureTranscode(effective, targetCodec);
      // 换档也是新建会话，同样可能撞上「首片还没落盘」，给两次重试
      await _openUrl(u, seekTo: pos, retries: toDirect ? 0 : 2);
      if (!mounted) return;
      setState(() {
        _preset = effective;
        _codec = targetCodec;
        _isTranscode = !toDirect;
      });
      // 偏好仍记用户点的那个档位：下一部片能直链时「原画」就该直链
      await PlayPreferences.save(preset: preset, codec: targetCodec);
    } catch (e) {
      if (messenger != null) {
        NasSnack.showOn(messenger, tr('player.switchFailed', {'error': '$e'}));
      }
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  /// 令牌过期（暂停久了 / 长时间投屏）静默重签 + 从原位置续播。
  /// HLS 分片自带会话令牌，不走这条。
  Future<void> _renewIfTokenExpired(String message) async {
    final id = widget.itemId;
    if (id == null || id.isEmpty || _isTranscode) return;
    if (_renewing || _renewTries >= 3) return;
    if (!RegExp(r'40[13]|unauthor|forbidden|expired|token', caseSensitive: false)
        .hasMatch(message)) {
      return;
    }
    _renewing = true;
    _renewTries += 1;
    final pos = _player.state.position;
    try {
      final res = await ApiSession.instance.client.videoStreamUrl(id: id);
      final u = res.url.startsWith('http')
          ? res.url
          : '${ApiSession.instance.baseUrl}${res.url}';
      _directUrl = u;
      await _openUrl(u, seekTo: pos);
    } catch (_) {
      // 重签也失败：保留原错误，让用户看到
    } finally {
      _renewing = false;
    }
  }

  // -------------------------------------------------------------------- 字幕

  Future<void> _loadSubtitles() async {
    final id = widget.itemId;
    if (id == null || id.isEmpty) return;
    try {
      final res = await ApiSession.instance.client.videoSubtitles(id: id);
      if (!mounted) return;
      setState(() => _subs = res.items);
      final pick = pickSubtitle(res.items, VideoSubtitlePrefs.instance.preferred);
      if (pick != null) await _applySubtitle(pick);
    } catch (_) {
      // 没有字幕 / 接口失败都不影响播放
    }
  }

  /// 按字幕文件名取结构化 cue；渲染由 [_subtitleLayer] 按播放位置完成。
  /// 这里不再调用 `setSubtitleTrack(SubtitleTrack.data(vtt))`：
  /// Web 内核把它做成 blob `<track>`，但 `open()` 会执行 `element.innerHTML = ''`
  /// 把已挂的 track 清掉、`textTracks[0]` 也永远指向第一次挂的那条，
  /// 于是「首次加载失败 / 切字幕不生效」是必现的。
  Future<void> _applySubtitle(VideoSubtitleFile? file) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (file == null) {
      if (mounted) {
        setState(() {
          _activeSub = null;
          _cues = const [];
        });
      }
      return;
    }
    final id = widget.itemId;
    if (id == null) return;
    try {
      final res = await ApiSession.instance.client.videoSubtitle(
        id: id,
        name: file.name,
      );
      if (!mounted) return;
      setState(() {
        _activeSub = file.name;
        _cues = res.cues;
      });
    } catch (e) {
      if (mounted && messenger != null) {
        NasSnack.showOn(
          messenger,
          tr('video.subtitleFailed', {'error': '$e'}),
          error: true,
        );
      }
    }
  }

  Future<void> _chooseSubtitle(String preferred, VideoSubtitleFile? file) async {
    await VideoSubtitlePrefs.instance.set(preferred);
    await _applySubtitle(file);
  }

  VideoSubtitleFile? _findSub(String name) {
    for (final sub in _subs) {
      if (sub.name == name) return sub;
    }
    return null;
  }

  /// 字幕菜单显示名：语言标签优先；内嵌字幕轨没有有效语言（常见是 `und`），
  /// 显示成「内嵌字幕 N」而不是把 `#embedded:0` / `und` 直接丢给用户。
  String _subLabel(VideoSubtitleFile sub) {
    final lang = sub.lang;
    if (lang != null && lang.isNotEmpty && lang.toLowerCase() != 'und') return lang;
    final m = RegExp(r'^#embedded:(\d+)$').firstMatch(sub.name);
    if (m != null) {
      final n = (int.tryParse(m.group(1) ?? '') ?? 0) + 1;
      return tr('player.embeddedSubtitle', {'n': '$n'});
    }
    return sub.name;
  }

  // -------------------------------------------------------------------- 交互

  void _resetHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && !_locked && _error == null && !_preparing) {
        setState(() => _controls = false);
      }
    });
  }

  void _poke() {
    final show = !_controls;
    if (show) setState(() => _controls = true);
    // 鼠标在画面上移动时 onHover 每秒能来几十次，没必要每次都重排定时器。
    final now = DateTime.now();
    if (!show && now.difference(_lastPoke).inMilliseconds < 400) return;
    _lastPoke = now;
    _resetHideTimer();
  }

  Future<void> _setRate(double v) async {
    _rate = v;
    await _player.setRate(v);
    await _saveUiPrefs();
    if (mounted) setState(() {});
  }

  Future<void> _setVolume(double v) async {
    _volume = v;
    await _player.setVolume(v);
    await _saveUiPrefs();
    if (mounted) setState(() {});
  }

  /// 全屏 / 退出全屏。
  ///
  /// 朝向跟着**视频自身**的宽高比走：竖屏片子（手机拍的、竖构图动画短片）进全屏
  /// 后应该还是竖屏，否则整屏都是黑边、正片只剩中间一条。以前只切
  /// `SystemUiMode`，手机上竖屏视频进全屏后依然是横屏 + 大黑边。
  /// Web 端没有朝向可锁，改调浏览器 Fullscreen API（见 `player_screen_web.dart`），
  /// 否则点了「全屏」页面纹丝不动，像是按钮坏了。
  Future<void> _toggleImmersive() async {
    final next = !_immersive;
    setState(() => _immersive = next);
    _poke();
    final w = _player.state.width ?? 0;
    final h = _player.state.height ?? 0;
    if (next) {
      await enterPlayerFullscreen(videoWidth: w, videoHeight: h);
    } else {
      await exitPlayerFullscreen();
    }
  }

  Future<void> _seekBy(int seconds) async {
    final p = _player.state.position;
    final limit = _seekLimit(_player.state.duration);
    var target = p + Duration(seconds: seconds);
    if (target < Duration.zero) target = Duration.zero;
    if (limit > Duration.zero && target > limit) target = limit;
    await _player.seek(target);
    _poke();
  }

  Future<void> _setLoop(PlaylistMode mode, {bool shuffle = false}) async {
    _loop = mode;
    _shuffle = shuffle;
    await _player.setPlaylistMode(mode);
    await _player.setShuffle(shuffle);
    if (mounted) setState(() {});
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final k = event.logicalKey;
    if (k == LogicalKeyboardKey.space) {
      _player.playOrPause();
      _poke();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowLeft) {
      _seekBy(-10);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowRight) {
      _seekBy(30);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.keyF) {
      _toggleImmersive();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.keyM) {
      _setVolume(_volume > 0 ? 0 : 100);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.escape && _immersive) {
      _toggleImmersive();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  String _fmt(Duration d) {
    // 拿不到总长时 media_kit 会给一个负的哨兵值，别把它格式化成 -106751991167:00:54
    if (d < Duration.zero) return '--:--';
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  /// 片源时长：转码还没跑完时用来兜底。
  Duration get _sourceDuration {
    final ms = widget.durationMs ?? 0;
    return ms > 0 ? Duration(milliseconds: ms) : Duration.zero;
  }

  /// 画进度条用的总长：**片源时长优先**（恒定），播放器报的值只兜底。
  ///
  /// 以前反着来（"播放器报的有限值优先"），转码播放就会抽搐：EVENT 播放列表的
  /// `duration` 只等于已转出的那一段，hls.js 刷新时又会短暂归零 → 进度条在
  /// 「已转出长度」和「整片长度」之间反复横跳（1:40 ↔ 1:57:45）。规则见
  /// `core/play_timeline.dart`。
  Duration _timelineDuration(Duration raw) =>
      timelineDuration(reported: raw, source: _sourceDuration);

  /// 能跳到哪儿：转码流只能跳到已经转出来的位置，否则 hls.js 拿不到分片干转圈。
  Duration _seekLimit(Duration raw) => seekLimit(
        reported: raw,
        source: _sourceDuration,
        isTranscode: _isTranscode,
      );

  // -------------------------------------------------------------------- 控件

  Widget _btn(
    IconData icon,
    String tip,
    VoidCallback onTap, {
    bool active = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      onPressed: () {
        onTap();
        _poke();
      },
      icon: Icon(icon, size: 20, color: active ? scheme.primary : Colors.white),
      tooltip: tip,
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
    );
  }

  Widget _checked(String label, bool on) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (on)
            const Icon(Icons.check, size: 16, color: Colors.white)
          else
            const SizedBox(width: 16),
          const SizedBox(width: 8),
          Text(label),
        ],
      );

  Widget _speedButton() => PopupMenuButton<double>(
        tooltip: tr('player.speed'),
        color: const Color(0xFF222222),
        onSelected: (v) => _setRate(v),
        itemBuilder: (_) => [
          for (final v in const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0])
            PopupMenuItem<double>(
              value: v,
              child: _checked('${v}x', _rate == v),
            ),
        ],
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(
            '${_rate}x',
            style: const TextStyle(color: Colors.white, fontSize: 13),
          ),
        ),
      );

  Widget _qualityButton() {
    // 一档一行：`1080P 1.4Mbps`（码率跟着当前编码走）。别再把分辨率和码率
    // 拆成两段拼「·」，同一档位并排两个码率看着像重复行。
    final cur = playQualityPresetOf(_preset)?.labelFor(_codec) ?? _preset;
    // 只列这部片转得出来的档位：没有 1080p 的片就别给 1080P 选项。
    final options = presetsForSource(_srcHeight);
    return PopupMenuButton<String>(
      tooltip: tr('player.quality'),
      color: const Color(0xFF222222),
      onSelected: (v) {
        if (v.startsWith('codec:')) {
          _switchQuality(_preset, codec: v.substring(6));
        } else {
          _switchQuality(v);
        }
      },
      itemBuilder: (_) => [
        PopupMenuItem<String>(
          enabled: false,
          child: Text(
            tr('player.qualityHint', {'preset': cur}),
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ),
        for (final p in options)
          PopupMenuItem<String>(
            value: p.key,
            child: _checked(p.labelFor(_codec), _preset == p.key),
          ),
        const PopupMenuDivider(),
        // 只列本机能解的编码：列了点了却黑屏，比不列更糟
        for (final c in playableCodecs())
          PopupMenuItem<String>(
            value: 'codec:${c.key}',
            child: _checked(c.label, _codec == c.key),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.hd_outlined, size: 18, color: Colors.white),
            const SizedBox(width: 4),
            Text(cur, style: const TextStyle(color: Colors.white, fontSize: 13)),
          ],
        ),
      ),
    );
  }

  Widget _subtitleButton() => PopupMenuButton<String>(
        tooltip: tr('player.subtitle'),
        color: const Color(0xFF222222),
        icon: Icon(
          _activeSub == null ? Icons.subtitles_outlined : Icons.subtitles,
          color: Colors.white,
          size: 20,
        ),
        onSelected: (value) {
          if (value == VideoSubtitlePrefs.off) {
            _chooseSubtitle(VideoSubtitlePrefs.off, null);
          } else if (value == VideoSubtitlePrefs.auto) {
            _chooseSubtitle(
              VideoSubtitlePrefs.auto,
              _subs.isEmpty ? null : _subs.first,
            );
          } else {
            final file = _findSub(value);
            _chooseSubtitle(file?.lang ?? VideoSubtitlePrefs.auto, file);
          }
          _poke();
        },
        itemBuilder: (_) => [
          PopupMenuItem<String>(
            value: VideoSubtitlePrefs.off,
            child: _checked(tr('ui.video.023'), _activeSub == null),
          ),
          if (_subs.length > 1)
            PopupMenuItem<String>(
              value: VideoSubtitlePrefs.auto,
              child: _checked(tr('ui.video.024'), false),
            ),
          for (final sub in _subs)
            PopupMenuItem<String>(
              value: sub.name,
              child: _checked(_subLabel(sub), _activeSub == sub.name),
            ),
          if (_subs.isEmpty)
            PopupMenuItem<String>(
              enabled: false,
              child: Text(tr('player.noSubtitles')),
            ),
        ],
      );

  Widget _audioButton() {
    final tracks = _player.state.tracks.audio;
    return PopupMenuButton<int>(
      tooltip: tr('player.audioTrack'),
      color: const Color(0xFF222222),
      icon: const Icon(Icons.audiotrack_outlined, color: Colors.white, size: 20),
      onSelected: (i) async {
        if (i >= 0 && i < tracks.length) {
          await _player.setAudioTrack(tracks[i]);
        } else if (widget.itemId != null) {
          // 转码流只有一条音轨：切源里的第 N 条需要重建会话
          _audioIndex = i - tracks.length;
          final u = await _ensureTranscode(_preset, _codec);
          await _openUrl(u, seekTo: _player.state.position);
        }
        _poke();
      },
      itemBuilder: (_) => [
        for (var i = 0; i < tracks.length; i++)
          PopupMenuItem<int>(
            value: i,
            child: Text(
              tracks[i].title ?? tracks[i].language ?? '${i + 1}',
              overflow: TextOverflow.ellipsis,
            ),
          ),
        if (_isTranscode && widget.itemId != null) ...[
          const PopupMenuDivider(),
          for (var i = 1; i <= 3; i++)
            PopupMenuItem<int>(
              value: tracks.length + i,
              child: Text('${tr('player.audioTrack')} ${i + 1}'),
            ),
        ],
        if (tracks.isEmpty)
          PopupMenuItem<int>(
            enabled: false,
            child: Text(tr('player.noAudioTracks')),
          ),
      ],
    );
  }

  void _showVolume() {
    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          backgroundColor: const Color(0xFF222222),
          title: Text(
            tr('player.volume'),
            style: const TextStyle(color: Colors.white),
          ),
          content: SizedBox(
            width: 320,
            child: Row(
              children: [
                const Icon(Icons.volume_down, color: Colors.white70),
                Expanded(
                  child: Slider(
                    value: _volume,
                    min: 0,
                    max: 100,
                    onChanged: (v) {
                      setLocal(() => _volume = v);
                      _player.setVolume(v);
                    },
                    onChangeEnd: (_) => _saveUiPrefs(),
                  ),
                ),
                Text(
                  '${_volume.round()}%',
                  style: const TextStyle(color: Colors.white70),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr('player.back')),
            ),
          ],
        ),
      ),
    );
  }

  /// 打开面板前主动拉一次会话：转码中的状态和实际编码只存在服务端。
  Future<void> _refreshJob() async {
    final id = _sessionId;
    if (id == null) return;
    try {
      final job = await ApiSession.instance.client.playerSessionGet(id: id);
      if (!mounted) return;
      final codec = job.codec ?? '';
      setState(() {
        _jobStatus = '${job.status}';
        if (codec.isNotEmpty) _actualCodec = codec;
      });
    } catch (_) {
      // 查不到就用手上已有的值，面板不能因为一次请求失败就打不开
    }
  }

  /// 转码状态文案。`_jobStatus` 为空 = 会话刚建、还没被服务端领走。
  String get _jobStateText {
    switch (_jobStatus) {
      case 'done':
        return tr('player.transcodeDone');
      case 'pending':
        return tr('player.transcodePending');
      case 'failed':
      case 'canceled':
        return tr('player.playFailed');
      default:
        return tr('player.transcoding');
    }
  }

  /// 实际输出编码的文案：服务端降级过就直说「谁不可用、回落成了什么」。
  String get _outputCodecText {
    final actual = _actualCodec;
    if (actual == null || actual.isEmpty) {
      // 还没出片：先把请求值标成「待定」，别让人以为已经在跑这个编码
      return '${playCodecOf(_codec)?.label ?? _codec}（${tr('player.transcodePending')}）';
    }
    final actualLabel = playCodecOf(actual)?.label ?? actual;
    if (actual == _codec) return actualLabel;
    return tr('player.codecFallback', {
      'want': playCodecOf(_codec)?.label ?? _codec,
      'actual': actualLabel,
    });
  }

  Future<void> _showInfo() async {
    final c = widget.compat ?? const <String, dynamic>{};
    String? v(dynamic x) => x == null || '$x'.isEmpty ? '—' : '$x';
    if (_sessionId != null) {
      await _refreshJob();
      if (!mounted) return;
    }
    // 码率：源码率按「文件大小 ÷ 时长」算，目标码率取当前档位 × 实际编码
    final srcKbps = sourceKbpsOf(widget.sourceBytes ?? 0, widget.durationMs ?? 0);
    final tgtKbps = _isTranscode
        ? (playQualityPresetOf(_preset)?.bitrateFor(_actualCodec ?? _codec) ?? 0)
        : 0;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1B1B1B),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(NasTokens.spaceLg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              tr('player.mediaInfo'),
              style: const TextStyle(color: Colors.white, fontSize: 17),
            ),
            const SizedBox(height: NasTokens.spaceMd),
            _infoRow(tr('player.playbackSource'),
                _isTranscode ? tr('player.sourceTranscode') : tr('player.sourceDirect')),
            // 是否转码中：直连时这一行没有意义，不显示
            if (_isTranscode) _infoRow(tr('player.transcodeState'), _jobStateText),
            _infoRow(
              tr('player.bitrate'),
              _isTranscode && tgtKbps > 0
                  ? tr('player.rateTo', {
                      'from': mbpsLabel(srcKbps),
                      'to': mbpsLabel(tgtKbps),
                    })
                  : mbpsLabel(srcKbps),
            ),
            _infoRow(tr('player.quality'),
                playQualityPresetOf(_preset)?.labelFor(_actualCodec ?? _codec) ?? _preset),
            _infoRow(tr('player.videoCodec'), v(c['videoCodec']) ?? '—'),
            if (_isTranscode) _infoRow(tr('player.outputCodec'), _outputCodecText),
            _infoRow(tr('player.audioCodec'), v(c['audioCodec']) ?? '—'),
            _infoRow(
              tr('player.resolution'),
              c['width'] == null ? '—' : '${c['width']} × ${v(c['height'])}',
            ),
            if (_reasons.isNotEmpty)
              _infoRow(tr('player.hdr'), _reasonText),
            _infoRow(tr('player.audioNormalize'),
                PlayPreferences.audioNormalize ? tr('player.on') : tr('player.off')),
            _infoRow(tr('player.audioDownmix'),
                PlayPreferences.audioDownmix ? tr('player.on') : tr('player.off')),
            const SizedBox(height: NasTokens.spaceSm),
          ],
        ),
      ),
    );
  }

  Widget _infoRow(String k, String val) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(k, style: const TextStyle(color: Colors.white54, fontSize: 13)),
            const SizedBox(width: 12),
            Flexible(
              child: Text(
                val,
                textAlign: TextAlign.end,
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
            ),
          ],
        ),
      );

  void _showSettings() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1B1B1B),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => Padding(
          padding: const EdgeInsets.all(NasTokens.spaceLg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                tr('player.settings'),
                style: const TextStyle(color: Colors.white, fontSize: 17),
              ),
              SwitchListTile(
                title: Text(
                  tr('player.audioNormalize'),
                  style: const TextStyle(color: Colors.white),
                ),
                value: PlayPreferences.audioNormalize,
                onChanged: (v) async {
                  await PlayPreferences.saveAudio(normalize: v);
                  setLocal(() {});
                },
              ),
              SwitchListTile(
                title: Text(
                  tr('player.audioDownmix'),
                  style: const TextStyle(color: Colors.white),
                ),
                value: PlayPreferences.audioDownmix,
                onChanged: (v) async {
                  await PlayPreferences.saveAudio(downmix: v);
                  setLocal(() {});
                },
              ),
              ListTile(
                leading: const Icon(Icons.help_outline, color: Colors.white70),
                title: Text(
                  tr('player.help'),
                  style: const TextStyle(color: Colors.white),
                ),
                subtitle: Text(
                  tr('player.helpContent'),
                  style: const TextStyle(color: Colors.white54, fontSize: 11),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showPlaylist() async {
    List<VideoItem> items = const [];
    try {
      final res = await ApiSession.instance.client.videoList(limit: 50);
      items = res.items;
    } catch (_) {
      // 拿不到列表就只提示，不摆空菜单
    }
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1B1B1B),
      builder: (_) => items.isEmpty
          ? Padding(
              padding: const EdgeInsets.all(NasTokens.spaceLg),
              child: Text(
                tr('player.noPlaylist'),
                style: const TextStyle(color: Colors.white70),
              ),
            )
          : ListView.builder(
              shrinkWrap: true,
              itemCount: items.length,
              itemBuilder: (_, i) {
                final it = items[i];
                return ListTile(
                  selected: it.id == widget.itemId,
                  title: Text(
                    it.title,
                    style: TextStyle(
                      color: it.id == widget.itemId
                          ? Theme.of(context).colorScheme.primary
                          : Colors.white,
                    ),
                  ),
                  onTap: () => _playOther(it),
                );
              },
            ),
    );
  }

  Future<void> _playOther(VideoItem it) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final res = await ApiSession.instance.client.videoStreamUrl(id: it.id);
      final u = res.url.startsWith('http')
          ? res.url
          : '${ApiSession.instance.baseUrl}${res.url}';
      if (!mounted) return;
      Navigator.of(context).pop();
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => PlayerPage(
            url: u,
            title: it.title,
            itemId: it.id,
            compat: res.compat,
            sourceBytes: it.size,
            durationMs: it.durationMs,
          ),
        ),
      );
    } catch (e) {
      if (messenger != null) {
        NasSnack.showOn(messenger, tr('player.switchFailed', {'error': '$e'}));
      }
    }
  }

  List<Widget> _rightControls(bool wide) {
    // 顺序就是用户看到的从左到右顺序，**别再 reversed**：反过一次以后
    // 整排按钮跟常见的播放器（倍速在最左、全屏在最右）完全对不上。
    final all = <Widget>[
      _speedButton(),
      _qualityButton(),
      _subtitleButton(),
      _audioButton(),
      _btn(Icons.volume_up, tr('player.volume'), _showVolume),
      _btn(Icons.playlist_play, tr('player.playlist'), _showPlaylist),
      _btn(Icons.info_outline, tr('player.info'), _showInfo),
      _btn(Icons.settings_outlined, tr('player.settings'), _showSettings),
      _btn(
        _immersive ? Icons.fullscreen_exit : Icons.fullscreen,
        _immersive ? tr('player.fullscreenExit') : tr('player.fullscreen'),
        _toggleImmersive,
        active: _immersive,
      ),
      if (!wide) _btn(Icons.lock_outline, tr('player.lock'), () {
        setState(() => _locked = true);
      }),
    ];
    if (wide) return all;
    // 窄屏：前三项常驻（倍速 / 画质 / 字幕）+「更多」，其余全进底部面板。
    // 顺序必须和宽屏同向 —— 外层横向滚动条是 `reverse: true`（内容靠右对齐、
    // 溢出时优先保住最右边那个），所以**列表顺序就是从左到右的视觉顺序**，
    // 别再倒着写（写成 [more, subtitle, quality, speed] 会真的显示成
    // 更多 · 字幕 · 画质 · 倍速）。
    // `all.skip(3)` 的 3 = 前面常驻的倍速/画质/字幕三项，改上面顺序时一起改。
    return [
      _speedButton(),
      _qualityButton(),
      _subtitleButton(),
      _btn(Icons.more_horiz, tr('common.more'), () => _showMore(all.skip(3).toList())),
    ];
  }

  void _showMore(List<Widget> extras) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1B1B1B),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(NasTokens.spaceLg),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: extras,
        ),
      ),
    );
  }

  Widget _progressRow() => StreamBuilder<Duration>(
        stream: _player.stream.position,
        builder: (_, pos) => StreamBuilder<Duration>(
          stream: _player.stream.duration,
          builder: (_, dur) {
            final p = pos.data ?? Duration.zero;
            final d = _timelineDuration(dur.data ?? Duration.zero);
            final max = d.inMilliseconds;
            return Row(
              children: [
                Text(_fmt(p),
                    style: const TextStyle(color: Colors.white70, fontSize: 12)),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 6,
                      ),
                    ),
                    child: Slider(
                      value: max > 0
                          ? (p.inMilliseconds / max).clamp(0.0, 1.0)
                          : 0.0,
                      // 拖到还没转出来的位置就停在转码进度上，别让 hls.js 干等分片
                      onChanged: max > 0
                          ? (v) {
                              final limit =
                                  _seekLimit(dur.data ?? Duration.zero);
                              var target =
                                  Duration(milliseconds: (max * v).round());
                              if (limit > Duration.zero && target > limit) {
                                target = limit;
                              }
                              _player.seek(target);
                            }
                          : null,
                    ),
                  ),
                ),
                Text(_fmt(d),
                    style: const TextStyle(color: Colors.white70, fontSize: 12)),
              ],
            );
          },
        ),
      );

  Widget _leftControls(bool wide) => StreamBuilder<bool>(
        stream: _player.stream.playing,
        builder: (_, snap) {
          final playing = snap.data ?? false;
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _btn(
                playing ? Icons.pause : Icons.play_arrow,
                playing ? tr('player.pause') : tr('player.play'),
                () => _player.playOrPause(),
              ),
              if (wide) ...[
                _btn(Icons.skip_previous, tr('player.prev'),
                    () => _showPlaylist()),
                _btn(Icons.skip_next, tr('player.next'),
                    () => _showPlaylist()),
              ],
              _btn(Icons.replay_10, tr('player.rewind10'),
                  () => _seekBy(-10)),
              _btn(Icons.forward_30, tr('player.forward30'),
                  () => _seekBy(30)),
              PopupMenuButton<String>(
                tooltip: tr('player.loop'),
                color: const Color(0xFF222222),
                icon: Icon(
                  _loop == PlaylistMode.single
                      ? Icons.repeat_one
                      : _loop == PlaylistMode.loop || _shuffle
                          ? Icons.repeat
                          : Icons.format_list_numbered,
                  color: Colors.white,
                  size: 20,
                ),
                onSelected: (v) {
                  if (v == 'single') {
                    _setLoop(PlaylistMode.single);
                  } else if (v == 'all') {
                    _setLoop(PlaylistMode.loop);
                  } else if (v == 'shuffle') {
                    _setLoop(PlaylistMode.loop, shuffle: true);
                  } else {
                    _setLoop(PlaylistMode.none);
                  }
                  _poke();
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                      value: 'sequence',
                      child: _checked(tr('player.loopSequence'),
                          _loop == PlaylistMode.none && !_shuffle)),
                  PopupMenuItem(
                      value: 'single',
                      child: _checked(tr('player.loopSingle'),
                          _loop == PlaylistMode.single)),
                  PopupMenuItem(
                      value: 'all',
                      child: _checked(tr('player.loopAll'),
                          _loop == PlaylistMode.loop && !_shuffle)),
                  PopupMenuItem(
                      value: 'shuffle',
                      child:
                          _checked(tr('player.loopShuffle'), _shuffle)),
                ],
              ),
            ],
          );
        },
      );

  Widget _topBar(bool wide) => Positioned(
        top: 0,
        left: 0,
        right: 0,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xAA000000), Color(0x00000000)],
            ),
          ),
          child: SafeArea(
            bottom: false,
            child: Row(
              children: [
                _btn(Icons.arrow_back, tr('player.back'),
                    () => Navigator.of(context).maybePop()),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    widget.title ?? tr('ui.video.001'),
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 15),
                  ),
                ),
                if (wide) _btn(Icons.info_outline, tr('player.info'), _showInfo),
                if (wide) _btn(Icons.help_outline, tr('player.help'), _showSettings),
              ],
            ),
          ),
        ),
      );

  Widget _bottomBar(bool wide) => Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 28, 12, 8),
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [Color(0xCC000000), Color(0x00000000)],
            ),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _progressRow(),
                Row(
                  children: [
                    _leftControls(wide),
                    const SizedBox(width: 8),
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        reverse: true,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: _rightControls(wide),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );

  Widget _centerControls(bool wide) {
    if (wide) return const SizedBox.shrink();
    return Positioned.fill(
      child: IgnorePointer(
        ignoring: !_controls,
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _btn(Icons.replay_30, tr('player.rewind10'), () => _seekBy(-10)),
              const SizedBox(width: 24),
              StreamBuilder<bool>(
                stream: _player.stream.playing,
                builder: (_, snap) => IconButton(
                  iconSize: 52,
                  icon: Icon(
                    (snap.data ?? false)
                        ? Icons.pause_circle_outline
                        : Icons.play_circle_outline,
                    color: Colors.white,
                  ),
                  onPressed: () {
                    _player.playOrPause();
                    _poke();
                  },
                ),
              ),
              const SizedBox(width: 24),
              _btn(Icons.forward_30, tr('player.forward30'),
                  () => _seekBy(30)),
            ],
          ),
        ),
      ),
    );
  }

  /// 自绘字幕：跟着播放位置取当前 cue，不依赖内核的 <track> / blob 链路。
  /// 控制条出现时抬高一点，别被进度条和控制按钮压住。
  Widget _subtitleLayer() {
    if (_activeSub == null || _cues.isEmpty) return const SizedBox.shrink();
    return Positioned.fill(
      child: IgnorePointer(
        child: StreamBuilder<Duration>(
          stream: _player.stream.position,
          initialData: _player.state.position,
          builder: (_, snap) {
            final text = activeSubtitleText(
              _cues,
              (snap.data ?? Duration.zero).inMilliseconds,
            );
            if (text.isEmpty) return const SizedBox.shrink();
            return Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: EdgeInsets.only(
                  left: 32,
                  right: 32,
                  bottom: _controls && !_locked ? 140 : 48,
                ),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    text,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      height: 1.35,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _statusLayer() {
    if (_preparing) {
      return Positioned.fill(
        child: ColoredBox(
          color: Colors.black.withValues(alpha: 0.82),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(NasTokens.spaceLg),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: NasTokens.spaceMd),
                  Text(
                    tr('player.preparing'),
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                  ),
                  const SizedBox(height: NasTokens.spaceSm),
                  Text(
                    tr('player.preparingHint', {'reason': _reasonText}),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                  const SizedBox(height: NasTokens.spaceMd),
                  OutlinedButton(
                    onPressed: () {
                      setState(() => _preparing = false);
                      _openUrl(_directUrl);
                    },
                    child: Text(tr('player.tryOriginal')),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    if (_switching) {
      return Positioned(
        top: 16,
        right: 16,
        child: Card(
          color: Color(0xCC222222),
          child: Padding(
            padding: EdgeInsets.all(10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: 8),
                Text(tr('player.switching'),
                    style: const TextStyle(color: Colors.white)),
              ],
            ),
          ),
        ),
      );
    }
    return const SizedBox.shrink();
  }

  /// 画面本体。
  ///
  /// 注意别在上层再套一层默认 `StackFit.loose` 的 Stack：Web 上平台视图
  /// 在零尺寸盒子里拿不到 slot，表现是黑屏但声音正常。
  Widget _videoSurface() {
    return Video(
      controller: _controller,
      controls: null,
      fit: _fit,
      fill: Colors.black,
    );
  }

  Widget _errorLayer() => Center(
        child: Padding(
          padding: const EdgeInsets.all(NasTokens.spaceLg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                tr('ui.video.h891441'),
                style: TextStyle(
                  color: context.nasDanger,
                  fontSize: NasTokens.fontSubtitle,
                ),
              ),
              const SizedBox(height: NasTokens.spaceSm),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: NasTokens.fontCaption,
                ),
              ),
              const SizedBox(height: NasTokens.spaceMd),
              OutlinedButton(
                onPressed: () => Navigator.of(context).maybePop(),
                child: Text(tr('ui.mount.019')),
              ),
              const SizedBox(height: NasTokens.spaceSm),
              Text(
                tr('ui.video.h4ad584'),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: NasTokens.fontCaption,
                ),
              ),
            ],
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 720;
    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          // 必须 expand：字幕层 / 状态层在没内容时返回 SizedBox.shrink()，
          // 它们是「非定位子节点」，默认的 StackFit.loose 会据此把整个 Stack
          // 算成 0×0 —— 画面、进度条、工具栏全部落在一个零尺寸盒子里，
          // 表现就是黑屏 + 只有声音（平台视图也拿不到有效尺寸，不生成 slot）。
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: MouseRegion(
                // 桌面端鼠标一动就把控件唤回来：只靠 onTap 的话控件隐藏后
                // 用户得先点一下才看得到进度条，Web 上尤其反直觉。
                onHover: (_) => _poke(),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _poke,
                  onDoubleTap: () {
                    _player.playOrPause();
                    _poke();
                  },
                  onLongPressStart: (_) {
                    _boosting = true;
                    _player.setRate(2.0);
                    setState(() {});
                  },
                  onLongPressEnd: (_) {
                    _boosting = false;
                    _player.setRate(_rate);
                    setState(() {});
                  },
                  child: _videoSurface(),
                ),
              ),
            ),
            if (_error != null)
              Positioned.fill(child: _errorLayer())
            else ...[
              _subtitleLayer(),
              _statusLayer(),
              if (_controls && !_locked) ...[
                // Web 上「全屏」是浏览器 Fullscreen API，顶栏即使留着也在全屏页里，
                // 藏掉反而让用户按 Esc 退出后回不到上一页 —— 所以 Web 不藏顶栏。
                if (!_immersive || kIsWeb) _topBar(wide),
                _centerControls(wide),
                _bottomBar(wide),
              ],
              if (_locked)
                Positioned(
                  left: 12,
                  bottom: 12,
                  child: _btn(Icons.lock, tr('player.unlock'), () {
                    setState(() => _locked = false);
                    _poke();
                  }),
                ),
              if (_boosting)
                Positioned(
                  top: 16,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Card(
                      color: const Color(0xCC222222),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        child: Text(
                          tr('player.speedBoost'),
                          style: const TextStyle(color: Colors.white),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
