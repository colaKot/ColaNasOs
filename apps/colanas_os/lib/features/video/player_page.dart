import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/audio_focus.dart';
import '../../core/audio_track_label.dart';
import '../../core/client_log.dart';
import '../../core/codec_support.dart';
import '../../core/play_preferences.dart';
import '../../core/play_quality.dart';
import '../../core/play_quality_scope.dart';
import '../../core/play_related.dart';
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
/// 底部右侧顺序（从左到右）：倍速 · 画质 · 字幕 · 音轨 · 音量 · 〔播放列表〕·
/// 信息 · 设置 · 全屏，窄屏把后几项收进「更多」。〔播放列表〕只在真的存在
/// 同系列剧集 / 同目录分卷时出现，其余按钮依次左移，不留空位。
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
    this.playlist,
    this.playlistIsSeries = false,
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

  /// 外部指定的播放队列（合集 / 自定义列表）。
  ///
  /// 传了就不再按「同系列 / 同目录分卷」去探测：合集里的影片彼此毫无命名
  /// 规律，探测出来的只会是「同目录其它文件」这种不相干的东西。
  final List<VideoItem>? playlist;

  /// 队列是否按剧集口径排（决定列表副标题显示 `S1 · E2` 还是文件名）。
  final bool playlistIsSeries;

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

  /// 播放状态上报用的订阅：playing / buffering / completed 都写进服务端日志，
  /// 装机版排障时不用连设备也能还原「到底卡在哪一步」。
  final List<StreamSubscription> _logSubs = [];

  late String _preset;
  /// 当前编码：用用户偏好，但本机解不出来时回落 H.264。
  String _codec = codecPlayable(PlayPreferences.codec)
      ? PlayPreferences.codec
      : 'h264';
  int _audioIndex = 0;

  /// 源文件的音轨清单（语言 / 音轨名 / 声道），菜单里显示成「1 · 中文 · TrueHD 7.1」。
  /// 空表示还没探到或探失败，此时退回 media_kit 的轨道列表。
  List<VideoAudioTrack> _audioTracks = const [];

  /// 播放列表：电视剧给同系列各集，电影给同目录下的分卷（cd1/cd2、-1/-2）。
  /// 少于 2 项时连按钮都不显示，别摆一个只有「正在播放」的空菜单。
  List<VideoItem> _playlist = const [];
  bool _playlistIsSeries = false;
  bool get _hasPlaylist => _playlist.length > 1;

  /// 音量浮窗的锚点：浮窗要贴在音量按钮正上方弹出来。
  final GlobalKey _volumeAnchor = GlobalKey();

  /// 音量图标跟着滑块实时变（静音 / 低音量 / 正常），但不能用 setState ——
  /// 拖滑块是每帧一次，整个播放页重排会明显掉帧。
  final ValueNotifier<double> _volumeVN = ValueNotifier<double>(100);
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
  /// 进播放器时的朝向（null = 还没读到，按竖屏处理）
  bool? _entryPortrait;

  // —— 进度手势（横向拖动 / 双击左右两侧）
  /// 拖动起点的片源绝对位置（毫秒）；null = 当前没在拖
  double? _dragStartMs;
  /// 相对起点的偏移（毫秒），拖动过程中实时变
  double _dragDeltaMs = 0;
  bool _dragSeeking = false;
  /// 快进快退的短暂提示（800ms 后自动消失）
  String? _seekHint;
  Timer? _seekHintTimer;

  bool _immersive = false;
  Timer? _hideTimer;

  /// 当前转码会话（只有转码时才有）。媒体信息面板要显示
  /// 「是否转码中」和「实际用了什么编码」—— 实际编码是服务端读
  /// sidecar 首片自报的结果，用户请求的 AV1 可能已经降级成 H.264 了。
  String? _sessionId;
  String? _jobStatus;

  /// 已转出的总时长（毫秒）：进度条上「已加载」那一段画到这里。
  /// **片源绝对位置**（含下面的起转偏移）。0 = 还没转出来 / 没开会话。
  int _transcodedMs = 0;
  /// 当前会话的「提前量」（毫秒）。0 = 整片一次转完。
  ///
  /// 分段会话的播放列表是**按整片时长预列**的（VOD + ENDLIST），所以 libmpv 报的
  /// `duration` 是整片、不是「已转出」；拿它算 `_loadedEnd` 会让 seek 判定
  /// 「目标在已加载区间内」，于是拖到没转的位置也只做原地 seek —— 分片不存在，
  /// 等 10 秒超时。这就是「播放时无法跳转」的根因。
  int _leadMs = 0;

  /// 本会话时间轴 0 对应的片源位置（毫秒）。
  ///
  /// 通常 0（从片头转）。进度条被拖到还没转出来的位置时会另建一个
  /// 「从该位置起转」的会话，这时播放器的 0 不等于片头 —— 显示、seek、
  /// 上报播放位置全都要加这个偏移，否则时间会整整差一个跳跃点。
  int _startMs = 0;

  /// 正在按目标位置重建会话（跳到未转码区），期间忽略再次拖动。
  bool _jumping = false;

  /// 上次重建会话的时刻：刚建完就再掐一次 ffmpeg 没有意义，2 秒冷却。
  DateTime _lastJumpAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 服务端回传的**实际**编码（降级后以它为准）；为空表示还没出片。
  String? _actualCodec;

  /// 上次刷新隐藏定时器的时间，用来给 `onHover` 做节流。
  DateTime _lastPoke = DateTime.fromMillisecondsSinceEpoch(0);

  /// 「play() 被 pause() 打断」这类良性错误的静默重试次数。
  /// 浏览器换 src 时必然先 pause 旧的 play()，产生的 DOMException 长得像错误，
  /// 但播放器随后会继续 —— 直接弹「播放失败」是误报（SMB 转码起播时高发）。
  int _benignRetries = 0;

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
    // 开硬件解码：media_kit 默认不设 hwdec，libmpv 会走软解。H.264 720p 软解
    // 还撑得住，但 AV1 走 dav1d 软解、同时服务端在做 4K tonemap + AV1 编码，
    // 客户端会掉到 0.5fps（实测 30s 只有 12~16 帧，而 raster 仅 2.3ms ——
    // 卡在解码而不是渲染）。auto-safe 在 GPU 解不了该编码时自动回落软解。
    //
    // Web 上没有 NativePlayer（且解码交给浏览器），而且 Web 版那个空壳类
    // 不含 setProperty，静态调用会让 flutter build web 直接编译失败 ——
    // 所以这里用运行时动态调用 + kIsWeb 短路。
    if (!kIsWeb) {
      try {
        // ignore: avoid_dynamic_calls
        (_player.platform as dynamic).setProperty('hwdec', 'auto-safe');
      } catch (_) {
        // 拿不到就算了，退回软解
      }
    }
    _controller = VideoController(_player);
    _logSubs.add(_player.stream.playing.listen((playing) {
      ClientLogger.instance.info(
        'playing=$playing',
        route: 'player.state/${_sessionId ?? 'direct'}',
      );
    }));
    _logSubs.add(_player.stream.buffering.listen((buffering) {
      ClientLogger.instance.info(
        'buffering=$buffering',
        route: 'player.state/${_sessionId ?? 'direct'}',
      );
    }));
    _logSubs.add(_player.stream.completed.listen((done) {
      if (done) {
        ClientLogger.instance.info(
          '播放结束 transcodedMs=$_transcodedMs',
          route: 'player.state/${_sessionId ?? 'direct'}',
        );
      }
    }));
    _loadUiPrefs();

    _player.stream.error.listen((message) {
      if (!mounted) return;
      // 播放失败必须进服务端日志：装上就用的人看不到控制台，界面只显示一行
      // 「播放失败」，光靠它没法判断是解码器、令牌还是转码的问题。
      ClientLogger.instance.error(
        message,
        route: 'player',
        detail:
            'item=${widget.itemId} session=$_sessionId preset=$_preset codec=$_codec url=$_url',
      );
      if (_isBenignPlaybackError(message)) {
        _retryAfterBenignError(message);
        return;
      }
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
      _loadAudioTracks();
      _loadPlaylist();
      _resetHideTimer();
    });
  }

  /// 进播放器那一刻的朝向，只记一次。
  ///
  /// 退出全屏 / 退出播放器要还原成它（见 `player_screen_stub.dart`）：
  /// 竖着进来就锁回竖屏，横着进来（TV / 平板横放）就放开朝向。
  /// `initState` 里不能读 MediaQuery，所以放在这里。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _entryPortrait ??= MediaQuery.orientationOf(context) == Orientation.portrait;
  }

  bool get _wantPortraitOnExit => _entryPortrait ?? true;

  /// 拉源文件的音轨清单。
  ///
  /// 转码流的 `_player.state.tracks.audio` 永远只有一条（就是转出来的那条），
  /// 菜单里拿它列音轨，用户看到的只是「音轨 1 / 2 / 3」，分不出哪条是国语、
  /// 哪条是英语。语言 / 音轨名只有源文件的容器里有，所以单独问一次服务端。
  Future<void> _loadAudioTracks() async {
    final id = widget.itemId;
    if (id == null || id.isEmpty) return;
    try {
      final res = await ApiSession.instance.client.videoAudioTracks(id: id);
      if (!mounted || res.items.isEmpty) return;
      setState(() => _audioTracks = res.items);
    } catch (_) {
      // 探不到就退回「音轨 N」的旧样式，不影响播放
    }
  }

  /// 组装播放列表。
  ///
  /// 以前这里直接拉「最新 50 部影片」，跟正在播的片子毫无关系。现在按两条路取：
  ///   - `series` 非空（电视剧）→ 同一系列的全部季 / 集，服务端已按季号集号排好；
  ///   - 否则 → 同目录下共用同一前缀的分卷文件（`abd-121-cd1` 配 `cd2`/`cd3`，
  ///     或 `abd-121-1` 配 `-2`），命名规则见 `core/play_related.dart`。
  /// 列表里没有当前片、或只剩当前片一条，就保持按钮隐藏。
  Future<void> _loadPlaylist() async {
    // 合集 / 自定义队列：调用方已经把整队列传进来了，按它走。
    // 合集里的片名之间没有任何命名关系，再按系列 / 分卷去探测只会拉进无关片子。
    final preset = widget.playlist;
    if (preset != null && preset.isNotEmpty) {
      _setPlaylist(preset, isSeries: widget.playlistIsSeries);
      return;
    }
    final id = widget.itemId;
    if (id == null || id.isEmpty) return;
    try {
      final client = ApiSession.instance.client;
      final cur = await client.videoItem(id: id);
      final series = (cur.series ?? '').trim();
      if (series.isNotEmpty) {
        final res = await client.videoSeriesItems(
          name: series,
          libraryId: cur.libraryId,
          limit: 500,
        );
        _setPlaylist(res.items, isSeries: true);
        return;
      }
      final dir = relatedDir(cur.path);
      final prefix = relatedPrefix(relatedBasename(cur.path));
      if (dir.isEmpty || prefix == null) return;
      // 目录筛选走 folderPath 更精确；SMB 绝对路径过不了来源根校验时，
      // 退回关键词搜索，再用「同目录 + 同前缀」在客户端钉一遍。
      VideoListResponse res;
      try {
        // `libraryId` 必须带：服务端要用库的来源根校验 folderPath，
        // 不带时 roots 为空 → 403。`mediaType=video` 是为了别把混合库里的
        // 同名剧照（image）一起捞进来。
        res = await client.videoList(
          libraryId: cur.libraryId,
          mediaType: 'video',
          folderPath: dir,
          folderMode: 'exact',
          limit: 200,
        );
      } catch (_) {
        res = await client.videoList(
          libraryId: cur.libraryId,
          mediaType: 'video',
          q: prefix,
          limit: 200,
        );
      }
      final picked = res.items
          .where(
            (it) =>
                relatedDir(it.path).toLowerCase() == dir.toLowerCase() &&
                relatedMatches(prefix, relatedBasename(it.path)),
          )
          .toList()
        ..sort((a, b) => compareRelatedNames(
              relatedBasename(a.path),
              relatedBasename(b.path),
            ));
      _setPlaylist(picked, isSeries: false);
    } catch (_) {
      // 探不到就不显示播放列表按钮，不影响播放
    }
  }

  void _setPlaylist(List<VideoItem> items, {required bool isSeries}) {
    if (items.length < 2 || !items.any((e) => e.id == widget.itemId)) return;
    if (!mounted) return;
    setState(() {
      _playlist = items;
      _playlistIsSeries = isSeries;
    });
  }

  void _loadUiPrefs() {
    final store = SettingsStore.instance;
    final rate = double.tryParse(store.getString('player.speed') ?? '');
    if (rate != null && rate > 0) _rate = rate;
    final vol = double.tryParse(store.getString('player.volume') ?? '');
    if (vol != null && vol >= 0 && vol <= 100) _volume = vol;
    _volumeVN.value = _volume;
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
    _seekHintTimer?.cancel();
    for (final sub in _logSubs) {
      sub.cancel();
    }
    _volumeVN.dispose();
    // 退出播放器（可能是**在全屏里按返回**，而不是先点退出全屏）必须把屏幕
    // 朝向还回去：全屏时按视频比例锁了 landscape，只还原 SystemUiMode 的话
    // 人已经回到列表页、手机还横着 —— 用户反馈「退出影片以后一直是横屏」。
    unawaited(exitPlayerFullscreen(portrait: _wantPortraitOnExit));
    AudioFocus.instance.release(_player);
    _player.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------ 播放源

  Future<void> _openUrl(
    String u, {
    Duration? seekTo,
    int retries = 0,
    bool resetBenignRetries = true,
  }) async {
    _url = u;
    final openSw = Stopwatch()..start();
    ClientLogger.instance.info(
      'open 开始',
      route: 'player.open/${_sessionId ?? 'direct'}',
      detail: u,
    );
    try {
      // 视频也带声音：开播前先让音乐 / 播客 / 音色试听让路
      await AudioFocus.instance.request(_player, () async => _player.pause());
      await _player.open(Media(u));
      ClientLogger.instance.info(
        'open 完成 ${openSw.elapsedMilliseconds}ms',
        route: 'player.open/${_sessionId ?? 'direct'}',
      );
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
      // 良性错误重试链里不能清零，否则「报错→重开→成功清零→又报错」无限循环，
      // 永远走不到 _benignRetries >= 2，黑屏且不显示任何错误。
      if (resetBenignRetries) _benignRetries = 0;
      if (mounted) setState(() => _error = null);
      // 直连保底：libmpv 解不了的容器/编码（典型 MKV + HEVC 10bit / DV）不会报错，
      // 而是「有声音、画面停在首帧」。8 秒还拿不到视频尺寸就自动切回转码。
      if (!_isTranscode) unawaited(_guardDirectPlayback());
    } catch (e) {
      ClientLogger.instance.warn(
        'open 失败 ${openSw.elapsedMilliseconds}ms: $e',
        route: 'player.open/${_sessionId ?? 'direct'}',
        detail: u,
      );
      // 边转边播的第一次打开会「打不开」：播放器拉 index.m3u8 时首片可能还没落盘
      // （服务端最多等 15s，超时就先给空 EVENT 列表），内核当场就报错退出。
      // 转码本身没失败，过一两秒分片就有了 —— 直接弹「播放失败」太冤。
      // 《匹诺曹》这种 4K DV 片首片要 5s 上下（HDR→SDR + 4K 解码初始化），
      // 正是最容易踩到这条的片源。重试 3 次（+6s）能给足首片时间。
      if (retries > 0 && _isTranscode && mounted) {
        await Future<void>.delayed(const Duration(milliseconds: 2000));
        if (!mounted) return;
        return _openUrl(u, seekTo: seekTo, retries: retries - 1);
      }
      if (mounted) setState(() => _error = e.toString());
      _renewIfTokenExpired(e.toString());
    }
  }

  /// 「能自愈的错误」：不是真的播不了，重开一次（或等一两秒）就好。
  bool _isBenignPlaybackError(String message) {
    final m = message.toLowerCase();
    if (m.contains('interrupted by a call to pause') ||
        m.contains('interrupted by a new load request') ||
        (m.contains('play()') && m.contains('interrupt')) ||
        m.contains('aborterror')) {
      return true;
    }
    // mpv / libavformat 的传输层日志：`tcp: ffurl read returned 0`、`http: ... eof`
    // 这类是连接被对端正常关闭（分片结束、keep-alive 超时、转码会话切段），
    // 数据其实还在管道里、播放器会自己续上 —— 但以前会糊一层错误页，用户以为播不了。
    // 归到良性里走「静默重试 2 次」，真播不动时仍然会把错误显示出来。
    if ((m.contains('tcp:') || m.contains('ffurl') || m.contains('http:')) &&
        (m.contains('read returned') ||
            m.contains('eof') ||
            m.contains('connection reset') ||
            m.contains('end of file'))) {
      return true;
    }
    // 转码流刚建会话那几秒，首片可能还没落盘：mpv / hls.js 会报
    // 「打不开」「认不出格式」「没有可播的流」—— 一两秒后同一个地址就能播。
    // 直链报这些就是真坏了（文件没了 / 403），不能装作没事。
    if (!_isTranscode) return false;
    return m.contains('failed to open') ||
        m.contains('failed to recognize') ||
        m.contains('no video or audio streams') ||
        m.contains('timed out') ||
        m.contains('404');
  }

  /// 良性中断 → 静默重开当前地址；重试四次仍没播起来才把错误显示出来。
  void _retryAfterBenignError(String message) {
    if (_benignRetries >= 4) {
      setState(() => _error = message);
      return;
    }
    _benignRetries += 1;
    final target = _url;
    if (target.isEmpty) return;
    Future<void>.delayed(const Duration(milliseconds: 900), () {
      if (!mounted || _player.state.playing) return;
      _openUrl(target, resetBenignRetries: false);
    });
  }

  /// 直连播不出画面时的保底：自动切回转码并说明原因。
  ///
  /// 「原画」按用户要求是绝对不转码，但 libmpv 并不什么都能解 —— 实测 MKV +
  /// HEVC 10bit / 杜比视界的片源直连时音频正常出、`state.width` 一直是 0，
  /// 画面就停在首帧。这种情况不能静默让人对着封面干等，也不能偷偷转码
  /// （用户明确要原片），所以：明确提示 + 切成一个转码档位。
  Future<void> _guardDirectPlayback() async {
    await Future<void>.delayed(const Duration(seconds: 8));
    if (!mounted || _isTranscode || _error != null) return;
    if ((_player.state.width ?? 0) > 0) return; // 有画面，直连正常
    final fallback = clampPresetForSource(
      defaultPlayPreset,
      _srcHeight,
      codec: _codec,
    );
    final messenger = ScaffoldMessenger.maybeOf(context);
    await _switchQuality(fallback, codec: _codec);
    if (messenger != null && mounted) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            tr('player.codecFallback', {
              'want': playQualityPresetOf('original')?.label ?? 'Original',
              'actual': playQualityPresetOf(fallback)?.label ?? fallback,
            }),
          ),
        ),
      );
    }
  }

  /// 拿到的某个 preset/codec 的 HLS 地址。
  ///
  /// 服务端用 EVENT 播放列表边转边播：第一个分片落盘时 index.m3u8 就可读，
  /// 所以这里创建完会话立刻返回地址起播，**不再轮询到 done**（全片转码一次
  /// 实测 254s 起，4K/AV1 更久，等完再把流丢给播放器就是长时间黑屏）。
  /// 已转完的同参会话由服务端 `dupe` 直接复用，不在客户端缓存地址。
  ///
  /// [startMs] > 0 = 从片源该位置起转（跳到还没转出来的位置时用）。产物播放列表的
  /// 时间轴 0 就是它，所以 `_startMs` 跟着更新，界面再加偏移。
  Future<String> _ensureTranscode(
    String preset,
    String codec, {
    int startMs = 0,
    /// 覆盖「提前量（分钟）」：跳转到未转位置时用小段，首片更快落地。
    int? leadOverride,
  }) async {
    final id = widget.itemId!;
    // 请求的编码在本机解不出来时回落 H.264（桌面端一律解得出来，浏览器由
    // `MediaSource.isTypeSupported` 说了算 —— 真 Chrome 上 AV1 / HEVC 都是支持的）。
    final outCodec = codecPlayable(codec) ? codec : 'h264';
    final sw = Stopwatch()..start();
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
        // 0 = 整片一次转完；>0 时服务端按段转，播放位置靠近末尾才续下一段
        leadMinutes: leadOverride ?? PlayPreferences.leadMinutes,
        // 0 = 从片头转。服务端会按片源时长夹取，越界不会建出空会话。
        startMs: startMs > 0 ? startMs : null,
      ),
    );
    final u = created.url.startsWith('http')
        ? created.url
        : '${ApiSession.instance.baseUrl}${created.url}';
    // 记下会话：媒体信息面板要拿它查「转码中 / 完成」和实际编码
    _sessionId = created.id;
    ClientLogger.instance.info(
      '会话已创建 ${sw.elapsedMilliseconds}ms preset=$preset codec=$outCodec',
      route: 'player.session/${created.id}',
      detail: u,
    );
    _jobStatus = null;
    _transcodedMs = 0;
    // 记下这一轮的提前量：决定 `_loadedEnd` 能不能信 libmpv 报的 duration。
    // 建会话的响应里没有 leadMs，先用客户端请求值推算，下一次轮询会用
    // 服务端回显的 leadMs 校正（见 _watchSession）。
    _leadMs = (leadOverride ?? PlayPreferences.leadMinutes) * 60000;
    // 起转偏移以服务端回显为准（它可能夹取过），播放器时间轴 0 = 这个位置
    _startMs = created.startedMs ?? startMs;
    // 实际编码换会话后必须清空，否则换了档还显示上一轮的结果
    _actualCodec = null;
    // 后台只盯失败：转码挂了要明确说出来，别让用户对着无限缓冲猜。
    _watchSession(created.id);
    // 首片落盘之前不要把地址交给播放器（见 _waitForFirstSegment）
    await _waitForFirstSegment(created.id);
    return u;
  }

  /// 新建会话后等首片落盘，再把播放地址交给播放器。
  ///
  /// 静态 VOD 列表是秒回的（按整片时长预列全部片名），但此刻 ffmpeg 可能连
  /// `init.mp4` 都还没写出来。直接 `player.open` 的话 libmpv 拿不到 fMP4
  /// 初始化段，约 7 秒就报 `Failed to recognize file format` —— 之后分片
  /// 陆续产出（日志里 43 个全 200）也救不回来，因为播放已经 fatal 了。
  /// 跳转时尤其容易踩：每次都是全新会话。复用旧会话时 transcodedMs 立刻 > 0，
  /// 这里零延迟返回，不影响秒开。
  Future<void> _waitForFirstSegment(String id) async {
    final sw = Stopwatch()..start();
    var polls = 0;
    var last = '';
    void log(String why) {
      ClientLogger.instance.info(
        '首片等待 $why ${sw.elapsedMilliseconds}ms polls=$polls $last',
        route: 'player.waitFirstSegment/$id',
      );
    }
    for (var i = 0; i < 40; i += 1) {
      if (!mounted) return;
      try {
        final job = await ApiSession.instance.client.playerSessionGet(id: id, pos: 0);
        polls += 1;
        // transcodedMs 是**片源绝对位置** = startedMs + 已转出时长。
        // 跳转会话的 startedMs 本身就有几十万毫秒，直接判断 > 0 会立刻放行，
        // 等于没等首片 —— 必须减掉起点。
        final started = job.startedMs ?? 0;
        final done = (job.transcodedMs ?? 0) - started;
        final st = '${job.status}';
        last = 'status=$st transcoded=${job.transcodedMs} started=$started done=$done segments=${job.segments}';
        if (done > 0) {
          log('ready');
          return;
        }
        if (st == 'failed' || st == 'canceled' || st == 'done') {
          log('terminal');
          return;
        }
      } catch (e) {
        last = 'err=$e';
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    log('timeout');
  }

  /// 后台盯会话状态：失败要明确说出来，成功就静默结束。
  ///
  /// 顺手把「转码中 / 完成」和**实际编码**写进 State：媒体信息面板直接读这两个
  /// 字段。用户选的 AV1 可能已经被服务端降级成 H.264（编码器起不来 / 硬编不支持），
  /// 面板必须显示真的那个，否则就是「我设了 AV1，为什么跑的是 264」。
  ///
  /// 分段续转下这个轮询还兼着两件事：把当前播放位置上报给服务端（它据此决定
  /// 要不要接着转下一段），以及拿回「已转出时长」画进度条刻度。所以**不能
  /// 只轮询 10 分钟就停**，也不能一看到 paused 就收手。
  Future<void> _watchSession(String id) async {
    // 必须在碰 context 之前判 mounted：这个方法是 `_ensureTranscode` 在
    // `await playerSessionCreate` **之后**调起来的，用户点完播放就退出时
    // State 已经 deactivate，`ScaffoldMessenger.maybeOf(context)` 会直接抛
    // 「Null check operator used on a null value」（实测 player_page.dart 崩溃）。
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    for (;;) {
      await Future<void>.delayed(const Duration(seconds: 3));
      // 换档 / 换片后旧会话的轮询要立刻停手，否则会把新会话的字段覆盖成旧值
      if (!mounted || _sessionId != id) return;
      try {
        // 上报的是**片源绝对位置**：服务端据此判断要不要续转下一段，
        // 起转偏移必须算进去，否则每次跳转后都会误判「离末尾还很远」。
        final pos = _absPosition(_player.state.position).inMilliseconds;
        final job = await ApiSession.instance.client.playerSessionGet(
          id: id,
          pos: pos > 0 ? pos.toDouble() : 0,
        );
        if (!mounted || _sessionId != id) return;
        final st = '${job.status}';
        final codec = job.codec ?? '';
        final transcoded = job.transcodedMs ?? 0;
        // 会话可能是详情页传进来的（没走过 _ensureTranscode），lead 在这里补齐，
        // 否则 _loadedEnd 会退回「信 player.duration」那条错路
        _leadMs = job.leadMs ?? _leadMs;
        // 分段会话会一直 paused 着轮询，值没变就别每 3 秒重排整页
        if (_jobStatus != st ||
            _transcodedMs != transcoded ||
            (codec.isNotEmpty && _actualCodec != codec)) {
          setState(() {
            _jobStatus = st;
            _transcodedMs = transcoded;
            if (codec.isNotEmpty) _actualCodec = codec;
          });
        }
        if (st == 'done' || st == 'canceled') return;
        if (st == 'failed') {
          ClientLogger.instance.error(
            '转码会话失败：${job.error ?? 'transcode failed'}',
            route: 'player.session',
            detail:
                'session=$id preset=$_preset codec=$_codec item=${widget.itemId}',
          );
          if (messenger != null) {
            NasSnack.showOn(
              messenger,
              '${tr('player.playFailed')}: ${job.error ?? 'transcode failed'}',
              error: true,
            );
          }
          return;
        }
        // paused：这一段转完了，等播放位置靠近再续，继续轮询
      } catch (_) {
        // 单次请求失败不能收手：分段续转靠持续轮询唤醒，断一次就停会
        // 让播放卡在「已转出」的末尾
        continue;
      }
    }
  }

  Future<void> _prepareCompatible() async {
    setState(() => _preparing = true);
    try {
      // 偏好设成「原画」且桌面端能解时直接放原片：零转码、可随意 seek、
      // 起播是毫秒级。以前这里无条件建转码会话，把「原画」偏好架空了。
      final toDirect =
          _preset == 'original' && widget.compat != null && (!kIsWeb || !_needTranscode);
      // 档位按片源高度收敛：偏好 1080P 但片源只有 720P 时，按 720P 转，
      // 不做放大转码（放大只会更大更糊，还多占 GPU）。菜单同样只列 ≤720P 的档。
      final effective =
          toDirect ? 'original' : clampPresetForSource(_preset, _srcHeight, codec: _codec);
      final u = toDirect ? _directUrl : await _ensureTranscode(effective, _codec);
      if (!mounted) return;
      setState(() {
        _preparing = false;
        _isTranscode = !toDirect;
        _preset = effective;
      });
      // retries: 首片还没落盘时内核会「打不开」，不是转码失败，给五次重试
      await _openUrl(u, retries: toDirect ? 0 : 5);
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
    // 桌面端（libmpv）能解 HEVC / AV1 / 10bit / DV，不该被服务端那套「按浏览器
    // 最保守能力」的判定绑住。以前这里要求 !_needTranscode，而 HEVC 一律被判
    // 需要转码 → 「原画」永远回落到转码，4K DV 每段起播要等 10s+。
    // Web 端保持原判定（Chromium 确实解不了 MKV/HEVC）。
    final toDirect =
        preset == 'original' && widget.compat != null && (!kIsWeb || !_needTranscode);
    if (!toDirect && widget.itemId == null) return;
    // 必须转码时「原画」没法真原样播，实际跑默认档；界面也跟着显示实际档位，
    // 不要出现「显示原画、跑的是 1080p」。同样按片源高度收敛。
    final effective = preset == 'original' && !toDirect
        ? clampPresetForSource(defaultPlayPreset, _srcHeight, codec: targetCodec)
        : preset;
    final pos = _absPosition(_player.state.position);
    setState(() => _switching = true);
    try {
      // 服务端建新会话会取消这部片还在排队 / 正在转的旧会话，
      // 所以换档不会让上一档的转码继续占 CPU。
      final u = toDirect
          ? _directUrl
          : await _ensureTranscode(
              effective,
              targetCodec,
              // 换档从当前位置接着播：新会话直接从这儿起转，不用再 seek
              startMs: pos.inMilliseconds,
            );
      // 回直链：时间轴是片源时间轴，起转偏移必须清零，否则位置会凭空多一截
      if (toDirect) _startMs = 0;
      // 换档也是新建会话，同样可能撞上「首片还没落盘」，给三次重试
      // （服务端已经会等到 25s，这里再兜几次是给 SMB 片源 + 4K 的余量）。
      // 转码会话的时间轴 0 = pos（见 _ensureTranscode 的 startMs），不能再 seekTo。
      await _openUrl(u, seekTo: toDirect ? pos : null, retries: toDirect ? 0 : 3);
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

  /// 字幕菜单里「搜索字幕」那一项的占位值（不可能与真实字幕名 / 偏好值撞上）
  static const _subtitleSearchSentinel = '\u0000search';

  /// 字幕正文搜索：在已加载的 cue 里找关键字，点结果直接跳到那句台词。
  ///
  /// 为什么有用：一部两小时的片子想找某句台词 / 某个场景，只能靠拖进度条瞎撞。
  /// 既有实现 的「字幕搜索」就是干这个的。Cue 在 `_applySubtitle` 里已经
  /// 解析进内存（自绘字幕要用），这里只是过滤 + seek，不额外请求服务端。
  Future<void> _showSubtitleSearch() async {
    if (_cues.isEmpty) {
      NasSnack.show(
        context,
        tr(_activeSub == null ? 'player.subtitleSearchNoSub' : 'player.subtitleSearchEmpty'),
      );
      return;
    }
    final ctrl = TextEditingController();
    final hitCount = ValueNotifier<int>(0);
    List<VideoSubtitleCue> matches = const [];
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: const Color(0xFF1B1B1B),
        builder: (ctx) => Padding(
          // 键盘弹起来别把列表顶出屏幕
          padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
          child: SizedBox(
            height: MediaQuery.sizeOf(ctx).height * 0.62,
            child: StatefulBuilder(
              builder: (ctx, setLocal) {
                void search(String raw) {
                  final q = raw.trim().toLowerCase();
                  if (q.isEmpty) {
                    setLocal(() {
                      matches = const [];
                      hitCount.value = 0;
                    });
                    return;
                  }
                  final out = <VideoSubtitleCue>[];
                  for (final cue in _cues) {
                    if (cue.text.toLowerCase().contains(q)) {
                      out.add(cue);
                      // 上千条命中的时候没必要全渲染，取前 200 条够翻
                      if (out.length >= 200) break;
                    }
                  }
                  setLocal(() {
                    matches = out;
                    hitCount.value = out.length;
                  });
                }

                return Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                      child: TextField(
                        controller: ctrl,
                        autofocus: true,
                        onChanged: search,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          hintText: tr('player.subtitleSearchHint'),
                          hintStyle: const TextStyle(color: Colors.white38),
                          prefixIcon:
                              const Icon(Icons.search, color: Colors.white54, size: 20),
                          isDense: true,
                        ),
                      ),
                    ),
                    Expanded(
                      child: ValueListenableBuilder<int>(
                        valueListenable: hitCount,
                        builder: (_, n, _) {
                          if (ctrl.text.trim().isEmpty) {
                            return Center(
                              child: Text(
                                tr('player.subtitleSearchTip'),
                                style: const TextStyle(color: Colors.white38),
                              ),
                            );
                          }
                          if (n == 0) {
                            return Center(
                              child: Text(
                                tr('player.subtitleSearchNone'),
                                style: const TextStyle(color: Colors.white38),
                              ),
                            );
                          }
                          return ListView.builder(
                            itemCount: matches.length,
                            itemBuilder: (_, i) {
                              final cue = matches[i];
                              return ListTile(
                                dense: true,
                                title: Text(
                                  cue.text,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(color: Colors.white, fontSize: 14),
                                ),
                                leading: Text(
                                  _fmt(Duration(milliseconds: cue.startMs)),
                                  style: const TextStyle(
                                    color: Colors.white54,
                                    fontSize: 12,
                                  ),
                                ),
                                onTap: () {
                                  Navigator.of(ctx).pop();
                                  unawaited(
                                    _seekTo(Duration(milliseconds: cue.startMs)),
                                  );
                                  _poke();
                                },
                              );
                            },
                          );
                        },
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      );
    } finally {
      hitCount.dispose();
      ctrl.dispose();
    }
  }

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

  /// 单击画面：控件开着就**收起**（进入沉浸观看），收起就唤出。
  ///
  /// 以前单击只调用 [_poke]，也就是「永远只会把控件叫出来」，要靠 4 秒定时器
  /// 自动消失 —— 用户点第二下没有任何反应，全屏时也没法手动进沉浸。
  void _toggleControls() {
    // 锁屏时点击不解锁，避免误触（左下角有专门的解锁按钮）
    if (_locked) return;
    if (_controls) {
      _hideTimer?.cancel();
      setState(() => _controls = false);
      return;
    }
    setState(() => _controls = true);
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
    _volumeVN.value = v;
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
      await exitPlayerFullscreen(portrait: _wantPortraitOnExit);
    }
  }

  Future<void> _seekBy(int seconds) async {
    final p = _absPosition(_player.state.position);
    await _seekTo(p + Duration(seconds: seconds));
    _flashSeek(
      seconds > 0
          ? tr('player.seekForward', {'n': '$seconds'})
          : tr('player.seekBack', {'n': '${-seconds}'}),
    );
  }

  // ------------------------------------------------------------ 进度手势
  //
  // 既有实现 那套手势：横向拖动 = 快进快退（松手才真跳），
  // 双击左 / 右两侧 = ±10s，中间双击仍然是播放/暂停。
  // 以前只有底部那条细滑块能拖，手机上一根手指很难抓准；画面区域
  // 那么大一块却只认「单击唤出控件」和「长按 2 倍速」，等于浪费。

  Future<void> _onDoubleTap() async {
    if (_locked) return;
    // 双击 = 进 / 出全屏。以前这里绑的是「左退 10s / 右进 10s / 中间暂停」，
    // 而用户对播放器的默认预期是双击全屏（全屏按钮坏了以后更是唯一的出路）。
    await _toggleImmersive();
    _poke();
  }

  /// 竖向滑动的累计位移：手机上「上滑 / 下滑」切上一条 / 下一条，
  /// 和短剧连播页的手感保持一致。松手才切，滑到一半反悔不算。
  double _vDragDy = 0;

  void _onVerticalDragStart(DragStartDetails d) => _vDragDy = 0;

  void _onVerticalDragUpdate(DragUpdateDetails d) => _vDragDy += d.delta.dy;

  void _onVerticalDragEnd(DragEndDetails d) {
    if (!_hasPlaylist || _locked) return;
    const threshold = 60.0;
    if (_vDragDy <= -threshold) {
      _playAdjacent(1); // 上滑 = 下一条
    } else if (_vDragDy >= threshold) {
      _playAdjacent(-1); // 下滑 = 上一条
    }
    _vDragDy = 0;
  }

  /// 拖动中：只更新预览，不做 seek（每帧都 seek 会把转码会话拖垮）
  void _onSeekDragStart(DragStartDetails d) {
    if (_locked) return;
    final total = _timelineDuration(_player.state.duration);
    if (total <= Duration.zero) return;
    _dragStartMs = _absPosition(_player.state.position).inMilliseconds.toDouble();
    _dragDeltaMs = 0;
    setState(() => _dragSeeking = true);
  }

  void _onSeekDragUpdate(DragUpdateDetails d) {
    if (!_dragSeeking) return;
    final w = MediaQuery.sizeOf(context).width;
    final total = _timelineDuration(_player.state.duration).inMilliseconds.toDouble();
    if (w <= 0 || total <= 0) return;
    // 划满一屏 ≈ 整片的 1/4，夹在 1 分钟 ~ 5 分钟之间：
    // 短片不会一动就到片尾，两小时的片子也不用划十几下才走一分钟。
    final span = (total / 4).clamp(60000.0, 300000.0);
    setState(() => _dragDeltaMs += d.delta.dx / w * span);
  }

  Future<void> _onSeekDragEnd(DragEndDetails d) async {
    if (!_dragSeeking) return;
    final start = _dragStartMs ?? 0;
    final total = _timelineDuration(_player.state.duration).inMilliseconds.toDouble();
    final target = (start + _dragDeltaMs).clamp(0.0, total);
    final jumped = (target - start).abs() >= 1000;
    setState(() {
      _dragSeeking = false;
      _dragStartMs = null;
      _dragDeltaMs = 0;
    });
    // 手抖几个像素不跳，否则「轻轻划一下画面」会莫名其妙跳一小段
    if (!jumped) return;
    await _seekTo(Duration(milliseconds: target.round()));
    _poke();
  }

  void _flashSeek(String text) {
    _seekHintTimer?.cancel();
    setState(() => _seekHint = text);
    _seekHintTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _seekHint = null);
    });
  }

  /// 拖动预览：`12:34 / +2:30`
  String get _seekPreviewText {
    final start = _dragStartMs ?? 0;
    final total = _timelineDuration(_player.state.duration).inMilliseconds.toDouble();
    final target = (start + _dragDeltaMs).clamp(0.0, total);
    final sign = _dragDeltaMs < 0 ? '-' : '+';
    final delta = Duration(milliseconds: _dragDeltaMs.abs().round());
    return '${_fmt(Duration(milliseconds: target.round()))}  $sign${_fmt(delta)}';
  }

  /// 跳到片源绝对位置 [target]。
  ///
  /// 分两路：
  ///   - 目标落在「本会话已加载区间」里 → 直接 `player.seek`（减掉起转偏移）；
  ///   - 落在外面（已经加载到的位置之后 / 会话起点之前）→ 另起一个从该位置
  ///     起转的会话。顺序转码是省 CPU 的前提，服务端没法凭空造出 1:30 的分片，
  ///     所以「跳过去」只能是重建一条从 1:30 开始的新会话。
  ///
  /// [allowJump] = false 用于拖动过程（`onChanged` 每帧都来）：那时只处理
  /// 区间内的实时跟随，跳出区间的等松手（`onChangeEnd`）再建会话，
  /// 否则一次拖动会掐掉好几轮 ffmpeg。
  Future<void> _seekTo(Duration target, {bool allowJump = true}) async {
    final total = _timelineDuration(_player.state.duration);
    var t = target;
    if (t < Duration.zero) t = Duration.zero;
    if (total > Duration.zero && t > total) t = total;
    if (!_isTranscode || widget.itemId == null) {
      // 直链 / 没有条目 id（详情页指定的 HLS 地址）没法重建会话，只能按老规矩夹取
      final limit = _seekLimit(_player.state.duration);
      if (_isTranscode && limit > Duration.zero && t > limit) t = limit;
      await _player.seek(t);
      _poke();
      return;
    }
    if (seekNeedsJump(
      target: t,
      start: _startOffset,
      loadedEnd: _loadedEnd,
    )) {
      if (!allowJump) return;
      // 只比已转出末尾多一点点（键盘 ±10s、拖个几十秒）：不重建会话。
      // 新会话要重新起一次 AMF/AV1 ffmpeg，实测首片 ~10s；这里只差几秒，
      // 直接让播放器在 VOD 列表里 seek，服务端分片路由会等并按需续转，
      // 当前画面和已有缓冲都保留。
      final over = t - _loadedEnd;
      if (over > Duration.zero && over <= const Duration(seconds: 30)) {
        await _player.seek(t - _startOffset);
        _poke();
        _nudgeTranscode(t);
        return;
      }
      await _jumpTo(t);
      return;
    }
    await _player.seek(t - _startOffset);
    _poke();
  }

  /// 小幅跳转后立刻上报目标位置，让服务端马上续转，不用等 3s 轮询。
  void _nudgeTranscode(Duration target) {
    final id = _sessionId;
    if (id == null || !_isTranscode) return;
    ApiSession.instance.client
        .playerSessionGet(id: id, pos: target.inMilliseconds.toDouble())
        .ignore();
  }

  /// 跳到还没转出来的位置：另建一条从 [target] 起转的会话。
  Future<void> _jumpTo(Duration target) async {
    if (_jumping) return;
    // 刚跳过来首片还没落盘，这时候再拖一次只是把 ffmpeg 掐掉重来
    if (DateTime.now().difference(_lastJumpAt) < const Duration(seconds: 2)) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    _lastJumpAt = DateTime.now();
    setState(() => _jumping = true);
    try {
      final u = await _ensureTranscode(
        _preset,
        _codec,
        startMs: target.inMilliseconds,
        // 跳转会话也用整片（leadOverride 默认跟随偏好 = 0）：分段会产生
        // DISCONTINUITY，libmpv 每到接缝重置解码器，画面就黑一下。
      );
      // 新播放列表的时间轴 0 就是 target，不能再 seekTo（否则会跳过 target 那一段）
      await _openUrl(u, retries: 3);
      _poke();
    } catch (e) {
      if (messenger != null && mounted) {
        NasSnack.showOn(messenger, tr('player.seekFailed', {'error': '$e'}));
      }
    } finally {
      if (mounted) setState(() => _jumping = false);
    }
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
    // 上 / 下 = 切上一条 / 下一条。只在这种播放器真有队列（合集、同系列、
    // 同目录分卷）时才接管，否则按键直接放过去，别把「方向键」吃掉。
    if (_hasPlaylist && k == LogicalKeyboardKey.arrowUp) {
      _playAdjacent(-1);
      return KeyEventResult.handled;
    }
    if (_hasPlaylist && k == LogicalKeyboardKey.arrowDown) {
      _playAdjacent(1);
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

  /// 本会话时间轴 0 对应的片源位置（通常 0；从中途起转时 = 起转偏移）。
  Duration get _startOffset => Duration(milliseconds: _startMs);

  /// 播放器时间 → 片源绝对时间。
  ///
  /// 播放器在拿不到时长时会吐负数哨兵值，这种一律按「就是起点」处理，
  /// 不然进度条会显示成 -106751991167 小时。
  Duration _absPosition(Duration raw) {
    if (raw <= Duration.zero) return _startOffset;
    final abs = _startOffset + raw;
    // HLS EVENT 列表首片未就绪时，mpv 可能把分片绝对 PTS 当成 time-pos
    // （26 小时量级）。不夹住会让进度条、字幕定位、观看上报一起跑飞。
    final limit = _timelineDuration(_player.state.duration);
    return limit > Duration.zero && abs > limit ? limit : abs;
  }

  /// 已加载（已转出）到的**片源绝对位置**：进度条粗的那一段画到这里。
  ///
  /// 静态 VOD 列表永远按整片时长预列（整片模式 / 分段模式都一样），libmpv 报的
  /// `duration` 恒等于片长 —— 拿它当「已加载末尾」会让 seek 永远判「不用重建
  /// 会话」，于是拖到没转出来的位置也只做原地 seek，卡在不存在的分片上。
  /// 只有会话真的 `done`（整片转完）时才敢信它。
  Duration get _loadedEnd {
    final done = _jobStatus == 'done';
    return Duration(
      milliseconds: loadedEndMs(
        startMs: _startMs,
        playerMs: done ? _player.state.duration.inMilliseconds : 0,
        serverMs: _transcodedMs,
      ),
    );
  }

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
      // 控制栏上**只留一个图标**：原来是「HD 图标 + 1080P 1.4Mbps」，
      // 这串文字宽了近百像素，窄屏上把字幕 / 更多按钮直接挤出可视区
      // （右侧控件是一整条横向滚动，溢出时先牺牲最左边那几个）。
      // 当前档位的完整文案放进 tooltip 与菜单首行，信息一点没少。
      tooltip: '${tr('player.quality')} · $cur',
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
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 8),
        child: Icon(Icons.hd_outlined, size: 20, color: Colors.white),
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
          if (value == _subtitleSearchSentinel) {
            unawaited(_showSubtitleSearch());
          } else if (value == VideoSubtitlePrefs.off) {
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
          // 字幕正文搜索：按关键字找那句台词，点一下就跳到那儿
          const PopupMenuDivider(),
          PopupMenuItem<String>(
            value: _subtitleSearchSentinel,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.search, size: 18),
                const SizedBox(width: 8),
                Text(tr('player.subtitleSearch')),
              ],
            ),
          ),
        ],
      );

  /// 一条音轨的菜单文案：`1 · 上海领声国语 · AC3 5.1`。
  /// 规则和语言表见 `core/audio_track_label.dart`（纯函数，有单测）。
  String _audioTrackLabel(VideoAudioTrack t, int ordinal) => audioTrackLabel(
        ordinal: ordinal,
        language: t.language,
        title: t.title,
        codec: t.codec,
        channelLayout: t.channelLayout,
        channels: t.channels,
      );

  Widget _audioButton() {
    final tracks = _player.state.tracks.audio;
    // 源文件音轨优先：转码流的 tracks.audio 只有一条，看不出内容
    final source = _audioTracks;
    return PopupMenuButton<int>(
      tooltip: tr('player.audioTrack'),
      color: const Color(0xFF222222),
      icon: const Icon(Icons.audiotrack_outlined, color: Colors.white, size: 20),
      onSelected: (i) async {
        if (source.isEmpty) {
          if (i >= 0 && i < tracks.length) {
            await _player.setAudioTrack(tracks[i]);
          }
          _poke();
          return;
        }
        if (i == _audioIndex) {
          _poke();
          return;
        }
        // 转码流只有一条音轨：切源里的第 N 条要重建会话，并从当前位置接着播
        // （位置直接当成新会话的起转点，时间轴 0 = 这里）
        final pos = _absPosition(_player.state.position);
        _audioIndex = i;
        final u = await _ensureTranscode(
          _preset,
          _codec,
          startMs: pos.inMilliseconds,
        );
        await _openUrl(u);
        _poke();
      },
      itemBuilder: (_) => [
        if (source.isNotEmpty)
          for (final t in source)
            PopupMenuItem<int>(
              value: t.index,
              child: _checked(_audioTrackLabel(t, t.index), _audioIndex == t.index),
            )
        else ...[
          for (var i = 0; i < tracks.length; i++)
            PopupMenuItem<int>(
              value: i,
              child: Text(
                tracks[i].title ?? tracks[i].language ?? '${i + 1}',
                overflow: TextOverflow.ellipsis,
              ),
            ),
          if (_isTranscode && widget.itemId != null)
            for (var i = 1; i <= 3; i++)
              PopupMenuItem<int>(
                value: tracks.length + i,
                child: Text('${tr('player.audioTrack')} ${i + 1}'),
              ),
        ],
        if (source.isEmpty && tracks.isEmpty)
          PopupMenuItem<int>(
            enabled: false,
            child: Text(tr('player.noAudioTracks')),
          ),
      ],
    );
  }

  /// 音量：**浮在音量按钮正上方的小窗**，竖着的滑块，往上推是满音量。
  ///
  /// 以前弹的是 AlertDialog：一个改音量的动作占用整块屏幕、还要点「返回」关掉，
  /// 播放时很打断。现在跟音轨 / 倍速一样是浮层，点外面就收。
  void _showVolume() {
    final anchor = _volumeAnchor.currentContext?.findRenderObject() as RenderBox?;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (anchor == null || overlay == null) return;
    const w = 76.0;
    const h = 224.0;
    final origin = anchor.localToGlobal(Offset.zero, ancestor: overlay);
    var left = origin.dx + anchor.size.width / 2 - w / 2;
    var top = origin.dy - h - 10;
    // 贴边时别把浮窗推出屏幕
    if (left < 8) left = 8;
    if (left + w > overlay.size.width - 8) left = overlay.size.width - w - 8;
    if (top < 8) top = 8;
    showMenu<void>(
      context: context,
      color: const Color(0xFF1E1E1E),
      elevation: 12,
      position: RelativeRect.fromLTRB(
        left,
        top,
        overlay.size.width - left - w,
        overlay.size.height - top - h,
      ),
      items: [
        PopupMenuItem<void>(
          // 不可选中：点滑块时不希望菜单先关掉
          enabled: false,
          padding: EdgeInsets.zero,
          height: h,
          child: SizedBox(
            width: w,
            height: h,
            child: _VolumePanel(
              value: _volume,
              onChanged: (v) {
                _volume = v;
                _volumeVN.value = v;
                _player.setVolume(v);
              },
              onCommit: _saveUiPrefs,
            ),
          ),
        ),
      ],
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

  /// 源编码的可读名：库里存的是 ffprobe 原值（hevc / h264 / av1 ...）。
  /// 10-bit / DV 是这次转码的主要动因，跟着源编码一起标出来。
  String _sourceCodecLabel(dynamic raw) {
    final s = raw == null ? '' : '$raw'.toLowerCase();
    final base = s.contains('hevc') || s.contains('h265')
        ? 'H.265 / HEVC'
        : s.contains('avc') || s.contains('h264')
            ? 'H.264 / AVC'
            : s.contains('av1')
                ? 'AV1'
                : s.contains('vp9')
                    ? 'VP9'
                    : s.isEmpty
                        ? '—'
                        : '$raw';
    final tags = <String>[];
    if (_reasons.contains('dolbyVision')) {
      tags.add('DV');
    } else if (_reasons.contains('10bit') || _reasons.contains('hdr10')) {
      tags.add('10bit');
    }
    return tags.isEmpty ? base : '$base · ${tags.join(' · ')}';
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
            // 转码时把「源编码 → 实际输出编码」写在同一行，别只给分辨率/码率。
            // 编码回落（如 DV 片源 AV1 → H.264）也会在这里直接看到原因。
            _infoRow(
              tr('player.videoCodec'),
              _isTranscode
                  ? tr('player.rateTo', {
                      'from': _sourceCodecLabel(c['videoCodec']),
                      'to': _outputCodecText,
                    })
                  : v(c['videoCodec']) ?? '—',
            ),
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

  /// 弹播放列表：内容是 `_loadPlaylist()` 预取好的同系列 / 同目录分卷，
  /// 正在播放的那一条高亮 + 打勾，点它不做事（别把自己重启一遍）。
  Future<void> _showPlaylist() async {
    final items = _playlist;
    if (items.isEmpty || !mounted) return;
    final scheme = Theme.of(context).colorScheme;
    // 长剧集列表要把当前集滚进视野，否则「选中」的那条在屏幕外看不见。
    final currentIndex = items.indexWhere((e) => e.id == widget.itemId);
    final controller = ScrollController(
      initialScrollOffset: currentIndex > 2 ? (currentIndex - 2) * 64.0 : 0.0,
    );
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1B1B1B),
      isScrollControlled: true,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(NasTokens.spaceLg),
              child: Text(
                tr('player.playlist'),
                style: const TextStyle(color: Colors.white, fontSize: 16),
              ),
            ),
            Flexible(
              child: ListView.builder(
                controller: controller,
                shrinkWrap: true,
                itemCount: items.length,
                itemBuilder: (_, i) {
                  final it = items[i];
                  final current = it.id == widget.itemId;
                  return ListTile(
                    selected: current,
                    leading: Icon(
                      current ? Icons.play_arrow : Icons.movie_outlined,
                      color: current ? scheme.primary : Colors.white54,
                      size: 20,
                    ),
                    title: Text(
                      it.title,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: current ? scheme.primary : Colors.white,
                      ),
                    ),
                    subtitle: Text(
                      _playlistSubtitle(it),
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 11,
                      ),
                    ),
                    trailing: current
                        ? Icon(Icons.check, size: 18, color: scheme.primary)
                        : null,
                    onTap: current ? null : () => _playOther(it),
                  );
                },
              ),
            ),
            const SizedBox(height: NasTokens.spaceMd),
          ],
        ),
      ),
    );
    controller.dispose();
  }

  String _playlistSubtitle(VideoItem it) {
    if (_playlistIsSeries) {
      final s = it.season;
      final e = it.episode;
      if (s != null && e != null) return 'S$s · E$e';
      if (e != null) return 'E$e';
    }
    return relatedBasename(it.path);
  }

  /// 上一集 / 下一集：只在真的有播放列表时才有这两个按钮。
  void _playAdjacent(int delta) {
    final items = _playlist;
    final i = items.indexWhere((e) => e.id == widget.itemId);
    if (i < 0) return;
    final j = i + delta;
    if (j < 0 || j >= items.length) return;
    _playOther(items[j], popSheet: false);
  }

  /// `popSheet`：从播放列表弹窗里点时要先关弹窗；从控制栏「上一集」直接切时
  /// 不能 pop，否则会把播放器页面本身关掉。
  Future<void> _playOther(VideoItem it, {bool popSheet = true}) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final res = await ApiSession.instance.client.videoStreamUrl(id: it.id);
      final u = res.url.startsWith('http')
          ? res.url
          : '${ApiSession.instance.baseUrl}${res.url}';
      if (!mounted) return;
      if (popSheet) Navigator.of(context).pop();
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => PlayerPage(
            url: u,
            title: it.title,
            itemId: it.id,
            compat: res.compat,
            sourceBytes: it.size,
            durationMs: it.durationMs,
            // 切下一条是 pushReplacement，不带队列的话新播放器会重新去探测：
            // 合集内切一条就整队列丢失，「下一个」再也按不动。
            playlist: _playlist,
            playlistIsSeries: _playlistIsSeries,
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
    final speed = _speedButton();
    final quality = _qualityButton();
    final subtitle = _subtitleButton();
    final audio = _audioButton();
    // 包一层 KeyedSubtree：音量浮窗要贴着这个按钮弹出来（见 _showVolume）
    final volume = KeyedSubtree(
      key: _volumeAnchor,
      child: ValueListenableBuilder<double>(
        valueListenable: _volumeVN,
        builder: (_, vol, _) => _btn(
          vol <= 0
              ? Icons.volume_off
              : vol < 50
                  ? Icons.volume_down
                  : Icons.volume_up,
          tr('player.volume'),
          _showVolume,
        ),
      ),
    );
    // 没有同系列 / 同目录分卷时，这个按钮直接不出现，后面的按钮自然往左靠。
    final playlist = _hasPlaylist
        ? _btn(Icons.playlist_play, tr('player.playlist'), _showPlaylist)
        : null;
    final info = _btn(Icons.info_outline, tr('player.info'), _showInfo);
    final settings =
        _btn(Icons.settings_outlined, tr('player.settings'), _showSettings);
    final fullscreen = _btn(
      _immersive ? Icons.fullscreen_exit : Icons.fullscreen,
      _immersive ? tr('player.fullscreenExit') : tr('player.fullscreen'),
      _toggleImmersive,
      active: _immersive,
    );
    final lock = wide
        ? null
        : _btn(Icons.lock_outline, tr('player.lock'), () {
            setState(() => _locked = true);
          });

    if (wide) {
      return [
        speed,
        quality,
        subtitle,
        audio,
        volume,
        ?playlist,
        info,
        settings,
        fullscreen,
        ?lock,
      ];
    }

    // 窄屏（手机竖屏）：**倍速 / 画质 / 更多 / 全屏**。
    //
    // 2026-11-08 用户要求：全屏 / 退出全屏是竖屏下最常用的操作，
    // 必须常驻在最右边，不能藏在「更多」里（每次都要多点两下）；字幕反而收进去。
    // 音量不放进「更多」：浮窗是贴着音量按钮定位的（`_volumeAnchor`），
    // 按钮不在树上浮窗就弹不出来，手机上用系统音量键即可。
    return [
      speed,
      quality,
      _btn(Icons.more_horiz, tr('common.more'), () {
        _showMore([
          subtitle,
          audio,
          ?playlist,
          info,
          settings,
          ?lock,
        ]);
      }),
      fullscreen,
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
            // 播放器时间轴 → 片源时间（从中途起转时要加偏移），时间与滑块都按它来
            final p = _absPosition(pos.data ?? Duration.zero);
            final d = _timelineDuration(dur.data ?? Duration.zero);
            final max = d.inMilliseconds;
            final cur = p.inMilliseconds.clamp(0, max > 0 ? max : 0);
            // 「已加载」画到哪儿：直链 = 整片（等于没有第二段），转码 = 已转出位置。
            // 转码时就给 Slider 的 secondaryTrackValue，轨道形状自己画粗的那一段。
            final loadedMs = _loadedEnd.inMilliseconds;
            final loaded = !_isTranscode || max <= 0
                ? null
                : loadedMs.clamp(cur, max).toDouble();
            return Row(
              children: [
                // 与 Slider 同源：必须用夹取后的 cur，否则 position 异常时
                // 左边显示 26:28:05、滑块却被 clamp 到满格。
                Text(_fmt(Duration(milliseconds: cur)),
                    style: const TextStyle(color: Colors.white70, fontSize: 12)),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 6,
                      ),
                      trackHeight: _LoadedTrackShape.baseHeight,
                      trackShape: const _LoadedTrackShape(),
                      // 已加载段：比底轨粗一倍，一眼能看出「能跳到哪儿」
                      inactiveTrackColor: const Color(0x3DFFFFFF),
                      secondaryActiveTrackColor: const Color(0x8AFFFFFF),
                    ),
                    child: Slider(
                      value: cur.toDouble(),
                      max: max > 0 ? max.toDouble() : 1.0,
                      secondaryTrackValue: loaded,
                      // 拖动时只跟随已加载区间；松手才决定要不要为「还没转出来的位置」
                      // 另起会话（`_seekTo` 的 allowJump）
                      onChanged: max > 0
                          ? (v) => _seekTo(
                                Duration(milliseconds: v.round()),
                                allowJump: false,
                              )
                          : null,
                      onChangeEnd: max > 0
                          ? (v) => _seekTo(Duration(milliseconds: v.round()))
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
              // 有播放列表才给「上一集 / 下一集」；没有时这两个位置直接消失，
              // 控制栏不会因为少了按钮而留空。
              if (wide && _hasPlaylist) ...[
                _btn(Icons.skip_previous, tr('player.prev'),
                    () => _playAdjacent(-1)),
                _btn(Icons.skip_next, tr('player.next'),
                    () => _playAdjacent(1)),
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
              // 字幕时间是片源时间，会话从中途起转时要加偏移才和画面对得上
              _absPosition(snap.data ?? Duration.zero).inMilliseconds,
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
    if (_switching || _jumping) {
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
                Text(tr(_jumping ? 'player.seekingTarget' : 'player.switching'),
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

  /// 错误页上的恢复入口：重新打开当前地址。
  Future<void> _retryPlay() async {
    if (_url.isEmpty) return;
    setState(() => _error = null);
    await _openUrl(_url, retries: 3);
  }

  /// 换到 H.264 重新建会话。DV / 10-bit 片源在 AV1(fMP4) 下跨段会解不出分片，
  /// H.264 走 mpegts 最稳，用户不必退出播放页就能自救。
  Future<void> _retryWithH264() async {
    if (widget.itemId == null) return;
    setState(() => _error = null);
    await _switchQuality(_preset, codec: 'h264');
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
              // 播放失败后错误层会盖住控制栏，用户点不到画质菜单 —— 这就是
              // 「切换分辨率 / 编码方式不生效」的实际表现。这里把恢复入口直接
              // 放到错误页上：重试当前地址，或一键换到最稳的 H.264 重新建会话。
              Wrap(
                alignment: WrapAlignment.center,
                spacing: NasTokens.spaceSm,
                children: [
                  if (_isTranscode && _codec != 'h264')
                    OutlinedButton(
                      onPressed: _retryWithH264,
                      child: Text(tr('player.retryWithH264')),
                    ),
                  OutlinedButton(
                    onPressed: _retryPlay,
                    child: Text(tr('player.retry')),
                  ),
                  OutlinedButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    child: Text(tr('common.back')),
                  ),
                ],
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
                  // 单击 = 切换控件显隐（也是进 / 出沉浸的唯一手势）
                  onTap: _toggleControls,
                  // 双击 = 全屏（见 _onDoubleTap）
                  onDoubleTap: _onDoubleTap,
                  // 横向拖动整块画面 = 快进快退（松手才真跳，见 _onSeekDragEnd）
                  onHorizontalDragStart: _onSeekDragStart,
                  onHorizontalDragUpdate: _onSeekDragUpdate,
                  onHorizontalDragEnd: _onSeekDragEnd,
                  // 竖向拖动 = 切上一条 / 下一条（仅在有队列时生效，否则松手即忽略）
                  onVerticalDragStart: _onVerticalDragStart,
                  onVerticalDragUpdate: _onVerticalDragUpdate,
                  onVerticalDragEnd: _onVerticalDragEnd,
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
                // 顶栏（含左上角返回）必须跟着控件一起出现：以前全屏时
                // `!_immersive` 会把它藏掉，手机 app 全屏以后**没有任何返回入口**，
                // 用户只能杀进程。现在点一下画面就出来，再点一下连它一起收起（沉浸）。
                _topBar(wide),
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
              // 拖动进度时在画面正中显示目标时间；双击快进给一个 900ms 的短提示。
              // 两者不同时出现（拖动中不会触发双击）。
              if (_dragSeeking || _seekHint != null)
                Positioned.fill(
                  child: IgnorePointer(
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xCC000000),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          _dragSeeking ? _seekPreviewText : (_seekHint ?? ''),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.w600,
                          ),
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

/// 音量浮窗的内容：竖着的滑块 + 百分比 + 静音开关。
///
/// 竖向靠 `RotatedBox(quarterTurns: 3)` 把横向 Slider 转 270°，这样
/// 「往上 = 变大」是自然的；反过来用 `quarterTurns: 1` 会变成往下拖才变大。
class _VolumePanel extends StatefulWidget {
  const _VolumePanel({
    required this.value,
    required this.onChanged,
    required this.onCommit,
  });

  final double value;
  final ValueChanged<double> onChanged;
  final VoidCallback onCommit;

  @override
  State<_VolumePanel> createState() => _VolumePanelState();
}

class _VolumePanelState extends State<_VolumePanel> {
  late double _v = widget.value;
  late double _lastNonZero = widget.value > 0 ? widget.value : 100;

  void _set(double v) {
    final clamped = v.clamp(0.0, 100.0).toDouble();
    setState(() => _v = clamped);
    if (clamped > 0) _lastNonZero = clamped;
    widget.onChanged(clamped);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '${_v.round()}%',
          style: const TextStyle(color: Colors.white, fontSize: 12),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: RotatedBox(
            quarterTurns: 3,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 4,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              ),
              child: Slider(
                value: _v,
                min: 0,
                max: 100,
                onChanged: _set,
                onChangeEnd: (_) => widget.onCommit(),
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        IconButton(
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          icon: Icon(
            _v <= 0 ? Icons.volume_off : Icons.volume_up,
            size: 18,
            color: Colors.white70,
          ),
          // 点一下在「静音 / 上次的音量」之间切换
          onPressed: () {
            _set(_v > 0 ? 0 : _lastNonZero);
            widget.onCommit();
          },
        ),
      ],
    );
  }
}

/// 进度条轨道：底轨细、已加载（已转出）段粗一倍、已播段最显眼。
///
/// 为什么不用默认轨道 + 单独画一条竖刻度：转码时要表达的是「0 ~ 这里已经能跳」，
/// 一段连续的粗线比一根 2px 竖线更容易看清；超出它的部分随转码推进自己变粗。
/// `secondaryTrackValue` 由 [Slider] 换算成 `secondaryOffset` 传进来，
/// 这里只负责按它画——拖动 / 点击的命中判定仍然由 Slider 自己算，不用另写手势。
class _LoadedTrackShape extends SliderTrackShape with BaseSliderTrackShape {
  const _LoadedTrackShape();

  /// 底轨高度（SliderTheme.trackHeight 用；太粗会盖住画面）
  static const double baseHeight = 4;
  static const double _loadedHeight = 8;
  static const double _playedHeight = 8;

  @override
  bool get isRounded => true;

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isEnabled = false,
    bool isDiscrete = false,
    required TextDirection textDirection,
  }) {
    final rect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    if (rect.isEmpty) return;
    final canvas = context.canvas;
    final centerY = rect.center.dy;

    // 底轨：整条，细
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(rect.center.dx, centerY),
          width: rect.width,
          height: baseHeight,
        ),
        const Radius.circular(baseHeight / 2),
      ),
      Paint()..color = sliderTheme.inactiveTrackColor ?? const Color(0x3DFFFFFF),
    );

    void segment(double fromDx, double toDx, double height, Color color) {
      final left = fromDx <= toDx ? fromDx : toDx;
      final w = (toDx - fromDx).abs();
      if (w <= 0) return;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(left, centerY - height / 2, w, height),
          Radius.circular(height / 2),
        ),
        Paint()..color = color,
      );
    }

    // 已加载（已转出）：从起点到 secondaryOffset
    if (secondaryOffset != null) {
      segment(
        rect.left,
        secondaryOffset.dx.clamp(rect.left, rect.right),
        _loadedHeight,
        sliderTheme.secondaryActiveTrackColor ?? const Color(0x8AFFFFFF),
      );
    }

    // 已播：起点到滑块
    segment(
      rect.left,
      thumbCenter.dx.clamp(rect.left, rect.right),
      _playedHeight,
      sliderTheme.activeTrackColor ?? Colors.white,
    );
  }
}
