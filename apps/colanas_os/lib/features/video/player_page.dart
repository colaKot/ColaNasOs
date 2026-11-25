import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart'
    show kIsWeb, kReleaseMode, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/app_settings.dart';
import '../../core/android_notification_permission.dart';
import '../../core/audio_focus.dart';
import '../../core/audio_track_label.dart';
import '../../core/client_log.dart';
import '../../core/codec_support.dart';
import '../../core/display_caps.dart';
import '../../core/latest_seek_queue.dart';
import '../../core/play_preferences.dart';
import '../../core/play_quality.dart';
import '../../core/play_quality_scope.dart';
import '../../core/play_related.dart';
import '../../core/play_stall.dart';
import '../../core/play_timeline.dart';
import '../../core/session.dart';
import '../../core/settings_store.dart';
import '../../core/video_render.dart';
import '../../core/video_subtitle_prefs.dart';
import 'player_screen.dart';
import 'tv_player_controls.dart';
import 'video_card.dart';
import 'video_item_actions.dart';
import 'tv_media3_player.dart';

String _redactedUrlForLog(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null) return '<unparseable-url>';
  if (!uri.hasAuthority) return '<relative-url>';
  return uri
      .replace(userInfo: '', path: '', query: '', fragment: '')
      .toString();
}

bool _isExplicitDecoderOpenFailure(String message) {
  final m = message.toLowerCase();
  return m.contains('failed to recognize file format') ||
      m.contains('no video or audio streams') ||
      m.contains('no video tracks') ||
      m.contains('no decoder found') ||
      m.contains('no suitable decoder') ||
      m.contains('decoder not found') ||
      m.contains('decoder initialization') ||
      m.contains('decoder init') ||
      m.contains('decoding_failed') ||
      m.contains('error_code_decoding') ||
      m.contains('decoder_video_renderer') ||
      m.contains('format_supported=no') ||
      m.contains('unsupported format') ||
      m.contains('unsupported codec') ||
      m.contains('unknown codec') ||
      m.contains('failed to initialize video decoder') ||
      m.contains('error while decoding') ||
      // MKV 里 DV 配置只有 dvcC、没有 hvcC 时，Media3 解析器会抛这类异常；
      // 部分非标准封装还会在轨道校验阶段直接抛 IllegalStateException
      // （ERROR_CODE_FAILED_RUNTIME_CHECK: Unexpected runtime error），
      // 同样是「本机解不了」，必须落到转码兜底，而不是直接弹「播放失败」。
      m.contains('illegalargumentexception') ||
      m.contains('illegalstateexception') ||
      m.contains('error_code_failed_runtime_check');
}

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
    this.startAt,
    this.onPosition,
    this.localSubtitles = const <String>[],
    this.mixedLibrary = false,
    this.previewItem,
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

  /// 首次打开后跳到这个位置（本地播放续播用）。
  /// 只对直连生效：转码流的 0 点是分段起转点，不能拿源片位置直接 seek。
  final Duration? startAt;

  /// 退出时回传最后的播放位置。本地播放靠它把进度写进本地索引 ——
  /// 播放器自己不落库，是因为在线播放的进度归服务端管。
  final void Function(Duration position)? onPosition;

  /// 本地外挂字幕的绝对路径（离线下载时抓下来的 WebVTT）。
  /// 在线播放走 `/video/subtitle` 接口，这里只服务「文件就在本机」的场景。
  final List<String> localSubtitles;

  /// 从图片 / 视频混合库进入：这类库的播放页不放快退 / 快进按钮，
  /// 改为在右侧常驻「播放列表 + 删除当前影片」。
  final bool mixedLibrary;

  /// 换集目标条目（只在上/下一条切换时传）。
  ///
  /// 有了它，新播放页一出来就先铺这一条自己的抽帧，等真正解出第一帧再撤掉 ——
  /// 换集过程不会先露黑底、也不会先闪一下路由转场动画。
  final VideoItem? previewItem;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage>
    with SingleTickerProviderStateMixin {
  late final Player _player;
  late final VideoController _controller;
  late final TvMedia3PlayerController _tvMedia3Player;
  TvMedia3State _lastTvMedia3State = const TvMedia3State();
  bool _nativeTvActive = false;

  /// 原生 SurfaceView 已经挂进窗口。只有它为 true 才敢把 Flutter 画面做成透明：
  /// 否则窗口短暂透明，手机桌面可能从缝里闪出来。
  bool _nativeSurfaceReady = false;
  bool _nativeFallbackAttempted = false;

  /// 隧道模式失败后退回「非隧道」重开过没有（每个播放页只试一次）。
  bool _tunnelOffRetried = false;
  int _nativeDecoderLoggedGeneration = -1;
  int _nativeFirstFrameLoggedGeneration = -1;

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

  /// 当前播放策略：设备不支持所选输出编码时回到原码。
  String _codec = codecPlayable(PlayPreferences.codec)
      ? PlayPreferences.codec
      : 'original';
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

  /// 准备页上的「试试原画」按钮什么时候才出现。
  ///
  /// 转码首片正常 1~3 秒就绪，4K + 色调映射也就 8 秒。一进播放页就把
  /// 「解不了？试试原画」摆在加载动画下面，用户会以为播放器已经判定解不掉
  /// （2026-11-17 用户反馈「没必要，起码等加载 1、2 分钟实在不行再出现」）。
  static const _tryOriginalDelay = Duration(seconds: 90);
  Timer? _tryOriginalTimer;
  bool _canTryOriginal = false;

  /// 准备页已经等了多久（秒）。≥8 秒才在界面上提示「可能排队」。
  int _prepareSeconds = 0;
  bool _switching = false;
  bool _boosting = false;
  bool _controls = true;
  bool _locked = false;

  /// 换集时铺着的「下一条抽帧」还在不在。
  ///
  /// 只有 [PlayerPage.previewItem] 非空（上下切集进来）时才为 true；
  /// 真正解出第一帧 / 出错 / 超时后就撤掉，露出下面的视频画面。
  late bool _showOpeningFrame = widget.previewItem != null;
  Timer? _openingFrameGuard;

  /// 撤掉换集占位图（首帧已出 / 出错 / 兜底超时）。
  void _dropOpeningFrame() {
    _openingFrameGuard?.cancel();
    _openingFrameGuard = null;
    if (mounted && _showOpeningFrame) {
      setState(() => _showOpeningFrame = false);
    } else {
      _showOpeningFrame = false;
    }
  }

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

  /// 本机 libmpv 的渲染能力 + 已生效的色调映射算法。
  ///
  /// 只在原生端有值；Web 端是空对象（解码交给浏览器）。
  VideoRenderCaps _caps = const VideoRenderCaps();

  /// 显示端 HDR 能力（Android TV 走原生通道，其余平台为 unknown）。
  DisplayCaps _display = DisplayCaps.unknown;

  /// 渲染参数必须在下发 `open()` 之前设好，否则 HDR 首帧就会按默认淡出。
  /// 用 Future 串起来，`_openUrl` 里 await 一次即可，不需要额外状态位。
  late final Future<void> _renderReady;

  /// 顶部一次性提示（色调映射回退 / 编码回落）。全屏下也可见，6 秒自动消失。
  String? _notice;
  Timer? _noticeTimer;

  /// 当前是不是 TV 运行形态（遥控器键位 / TV 控制层分支）。
  ///
  /// 用设置位而不是 `TvScope.of(context)`：`initState` / 定时器里不能查
  /// InheritedWidget，而 TV 模式本来就是全局开关，两者取值一致。
  bool get _tvMode => AppSettings.instance.tvMode.value;

  /// Android 上「原生播放器直通」是否可用。
  ///
  /// HDR / 杜比视界片源交给 Media3 + 裸 SurfaceView：DV RPU 由系统解码器处理，
  /// 能真输出杜比视界；libmpv 那条链路不解析 DV RPU，Profile 5 直连必紫。
  /// 用户开了「HDR 色调映射」就表示他要服务端转码，这里主动让路。
  ///
  /// 手机 / 平板 / 电视统一走原生 Media3 + 裸 SurfaceView；画面不再经过
  /// Flutter 纹理，HDR / 杜比视界元数据能直达显示端。
  bool get _androidNativeHdrEligible =>
      !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.android &&
      _srcHdr.isHdr &&
      !PlayPreferences.toneMap;

  /// Android 上视频一律交给原生 Media3（含 SDR / 转码 HLS）。
  /// 其它平台（桌面 / Web）仍用 media_kit。
  bool get _shouldUseNativeTvPlayer =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Duration get _playbackPosition =>
      _nativeTvActive ? _tvMedia3Player.state.position : _player.state.position;
  Duration get _playbackDuration =>
      _nativeTvActive ? _tvMedia3Player.state.duration : _player.state.duration;
  Duration get _playbackBuffer =>
      _nativeTvActive ? _tvMedia3Player.state.buffer : _player.state.buffer;
  bool get _playbackPlaying =>
      _nativeTvActive ? _tvMedia3Player.state.isPlaying : _player.state.playing;
  bool get _playbackBuffering => _nativeTvActive
      ? _tvMedia3Player.state.isBuffering
      : _player.state.buffering;
  bool get _playbackCompleted => _nativeTvActive
      ? _tvMedia3Player.state.isCompleted
      : _player.state.completed;
  int get _playbackWidth => _nativeTvActive
      ? _tvMedia3Player.state.videoWidth
      : (_player.state.width ?? 0);
  int get _playbackHeight => _nativeTvActive
      ? _tvMedia3Player.state.videoHeight
      : (_player.state.height ?? 0);
  String get _rendererSummary {
    if (!_nativeTvActive) return _caps.summary;
    final decoder = _tvMedia3Player.state.videoDecoder;
    return decoder.isEmpty ? 'Media3' : 'Media3 · $decoder';
  }

  /// 片源 HDR 是否走了「原生 Surface 直出」。
  ///
  /// 只有 Media3 原生通道（安卓电视）才算激活：手机上 libmpv 渲染进 Flutter
  /// 纹理，HDR 元数据到不了屏幕；转码（非视频 copy）也已经是 SDR。
  bool get _hdrDirectActive =>
      _nativeTvActive &&
      _srcHdr.isHdr &&
      (!_isTranscode || _isVideoCopySession);

  /// 播放信息面板里的「已激活 / 未激活 + 原因」。
  String get _directStatusText {
    if (!_srcHdr.isHdr) return '—';
    if (_hdrDirectActive) return tr('player.active');
    if (PlayPreferences.toneMap) return tr('player.inactiveToneMap');
    if (_isTranscode) return tr('player.inactiveTranscode');
    return tr('player.inactiveNativeOff');
  }

  Stream<Duration> get _positionStream => _nativeTvActive
      ? _tvMedia3Player.positionStream
      : _player.stream.position;
  Stream<Duration> get _durationStream => _nativeTvActive
      ? _tvMedia3Player.durationStream
      : _player.stream.duration;
  Stream<bool> get _playingStream =>
      _nativeTvActive ? _tvMedia3Player.playingStream : _player.stream.playing;

  Future<void> _playbackPlay() =>
      _nativeTvActive ? _tvMedia3Player.play() : _player.play();
  Future<void> _playbackPause() =>
      _nativeTvActive ? _tvMedia3Player.pause() : _player.pause();
  Future<void> _playbackSeek(Duration position) => _nativeTvActive
      ? _tvMedia3Player.seekTo(position)
      : _player.seek(position);
  Future<void> _playbackSetRate(double rate) =>
      _nativeTvActive ? _tvMedia3Player.setRate(rate) : _player.setRate(rate);
  Future<void> _playbackSetVolume(double volume) => _nativeTvActive
      ? _tvMedia3Player.setVolume(volume)
      : _player.setVolume(volume);

  // —— TV 控制层焦点（索引式，不依赖 Flutter 焦点遍历）
  /// 0 = 进度条，1 = 按钮行
  int _tvRow = 1;
  int _tvIndex = 0;

  /// TV 的 `PopScope(canPop:)` 一次性放行标志：真正要退出播放时才置 true，
  /// 否则返回键会被「先收控制层」的逻辑永远拦住。
  bool _allowPop = false;

  /// TV 选项小窗（字幕 / 音轨 / 倍速 / 画质 / 信息）是否开着。
  /// 返回键按「小窗 → 操作栏 → 退出播放页」三层处理，见 [_tvBack]。
  bool _tvPanelOpen = false;

  /// 按钮行的横向滚动锚点（索引变化时滚到可见）

  /// 已转出的总时长（毫秒）：进度条上「已加载」那一段画到这里。
  /// **片源绝对位置**（含下面的起转偏移）。0 = 还没转出来 / 没开会话。
  int _transcodedMs = 0;

  /// 当前会话的「提前量」（毫秒）。分段会话 > 0（2026-11-16 起不再有整片会话）；
  /// 老会话可能是 0，代码仍按「整片」兼容。
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
  bool _seeking = false;

  late final LatestSeekQueue _seekQueue = LatestSeekQueue(
    onError: (error, stackTrace) {
      ClientLogger.instance.warn(
        '播放器 seek 命令失败：${error.runtimeType}',
        route: 'player.seek/${_sessionId ?? 'direct'}',
        detail: 'target=${_lastSeekTarget.inMilliseconds}ms',
      );
    },
  );

  static const _seekCommandTimeout = Duration(seconds: 8);

  /// 用户「想让它播」的意图：true = 应该在播（含正在缓冲），false = 用户自己按了暂停。
  ///
  /// 为什么需要它：media_kit 的 Web 实现里 `open()` 是同步的两步 ——
  /// `element.pause()` 紧跟 `element.play()`，两个 Promise 在同一个事件循环里
  /// 竞态，Chrome 经常把 play() 判成 `interrupted by a call to pause` 直接拒绝。
  /// media_kit 只把这个拒绝丢进 error 流，而客户端在刚 open 的 3 秒内把这类错误
  /// 当「自己换流造成的」直接忽略 —— 于是画面停在暂停，等用户手点。
  /// 有了这个标志就能在 open / 换档 / 跳转后主动补播，同时不抢用户的暂停。
  bool _wantPlay = true;

  /// [_resumeIfIdle] 的去抖时间戳：buffering 一开一关会连续发事件，
  /// 每次关都 play() 会和新一次缓冲打架。
  DateTime? _lastResumeAt;

  /// 最近一次 seek / 重新 open 的时间。
  ///
  /// 浏览器换 src / seek 时会主动中断上一个 `play()`，抛
  /// 「The play() request was interrupted because the media was removed...」。
  /// 这是**我们自己换流造成的**，不是播放失败；以前它被当成良性错误去
  /// `_openUrl` 重开，重开又中断新的 play() → 无限闪屏、跳转永远落不了地。
  DateTime _lastSeekAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastOpenAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 第几次 `_seekTo`。连续按 → / 连续拖只让最后一次落地。
  ///
  /// 有了「等转码追上」（[_awaitProduced]，最多 8 秒）之后必须加这一道：
  /// 前一次 seek 可能还在等片，用户已经又按了两次，等回来不判代际就会
  /// 拿旧目标去 seek，把最后一次覆盖掉。
  int _seekGen = 0;

  /// 跳转进行中又有新目标：只保留最后一个，等当前这次完成后再跳。
  Duration? _pendingJump;
  int? _pendingJumpGen;
  int _jumpRunGen = 0;

  /// 播放停滞看门狗：**页面级常驻**，整个播放页只有一个，任何路径都不许 cancel
  /// （除了 dispose）。
  ///
  /// 以前是「每次 seek 挂一个 Timer、换流就 cancel、用代际号作废旧表」的写法，
  /// 于是出现了三次**同一形状**的事故（`795ee81b` 冻 6 分钟 / `8550c2c2` 冻 96 秒 /
  /// `c16e2aeb` 静默 116 秒）：每多一个 `cancel()` 就多一个能让看门狗死掉的地方，
  /// 而 `playing` 流不会重发同一个值 —— 死了就永远没人再挂表，之后冻多久都
  /// 一条日志都没有。现在只在 initState 起一次、dispose 收一次；seek / 换流
  /// 只做判定重置（[_armStallWatch]），不动定时器本身。
  Timer? _stallTicker;

  /// 看门狗盯的目标（片源绝对），只用于日志。
  Duration? _stallTarget;

  /// 最近一次「跳过这一拍」的原因与记录时间。跳过的原因必须能在日志里看见，
  /// 否则又回到「静默冻死、没有证据」的老路上（[stallSkipQuiet] 里的几种
  /// 是用户自己造成的，不刷日志）。
  String? _stallSkipWhy;
  DateTime _stallSkipLoggedAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 用户按暂停 / 已播完 / 首帧准备：这些「画面不动」是预期内的。
  static const Set<String> stallSkipQuiet = {'用户暂停', '已播完', '首帧准备'};

  /// `_jumping` 置 true 的时刻。跳转若卡在 [_ensureTranscode] / open 上不返回，
  /// `_jumping` 会永远是 true，看门狗每拍都被跳过 —— 那也是卡住，得有硬超时。
  DateTime? _jumpingSince;

  /// 停滞判定的水位计（判据：**历史最大位置**在多少秒内没涨过）。
  /// 换成纯 Dart 的 [PlayStallDetector] 是为了能单独写单测 —— 这段逻辑
  /// 2026-11-17 出过一次「看门狗被 seek 回显骗过、整场冻死」的事故。
  final PlayStallDetector _stall = PlayStallDetector();

  /// 看门狗每次「重建会话」的时间戳（见 [_armStallWatch] 末尾的防抖）。
  final List<DateTime> _stallRebuiltAt = [];

  /// 连按 → / ← 的合并计时器（260ms 内的连按只落一次，见 [_seekBy]）。
  Timer? _seekByTimer;
  Duration _seekByFrom = Duration.zero;
  Duration _seekByTarget = Duration.zero;

  /// 遥控器「长按左右键 → 拖动进度」的状态（用户 2026-11-24 要求：
  /// 按住越久拖得越快，松开才提交 seek）。
  int _tvHoldDir = 0; // -1 左 / 1 右 / 0 无
  Timer? _tvHoldDelay; // 按下 420ms 还没松手 → 升级成拖动
  Timer? _tvHoldTick; // 拖动中的增量节拍（100ms）
  DateTime? _tvHoldStartedAt;
  Duration _tvHoldFrom = Duration.zero; // 拖动起点（片源绝对）
  Duration _tvHoldTarget = Duration.zero; // 当前预览目标
  bool _tvHoldActive = false;

  static const int _tvHoldDelayMs = 420;
  static const int _tvHoldTickMs = 100;

  /// 新建跳转会话后、新流真正 open 之前，`_startMs` 已经是新值，而播放器
  /// 还停在**上一条流**上（首片要等好几秒）。这段时间不能拿 position 去算
  /// 绝对位置 —— 两者一加就是翻倍（2026-11-17：目标 338040 = 149020 + 189020）。
  /// 非空表示「新会话已建好但还没轮到它」，值为新会话起点。
  Duration? _pendingStartMs;

  /// 最近一次 `_seekTo` 的目标（片源绝对）。[_pendingStartMs] 非空时拿它当
  /// 快进 / 快退的基准 —— 此时 position 属于旧流，不可信。
  Duration _lastSeekTarget = Duration.zero;
  DateTime? _seekRecoveryStartedAt;
  Duration? _seekRecoveryTarget;

  /// 正在「等转码追上」的目标（片源绝对）。非空时右上角显示
  /// 「正在转码到 xx:xx」—— 等待期间画面会停在已转出末尾不动，
  /// 没有这个提示用户只会觉得卡死了（2026-11-17 反馈）。
  Duration? _waitingTarget;

  /// 设置 / 清除「正在等转码」提示（只在变化时 setState，避免抖）。
  void _markWaitingTarget(Duration? t) {
    if (_waitingTarget == t) return;
    if (!mounted) {
      _waitingTarget = t;
      return;
    }
    setState(() => _waitingTarget = t);
  }

  /// 收尾时只清当前 seek 的目标；旧请求的 finally 不能清掉新请求的提示。
  void _clearWaitingTarget(Duration t, {required int seekGeneration}) {
    if (seekGeneration != _seekGen || _waitingTarget != t) return;
    _markWaitingTarget(null);
  }

  void _beginSeekRecovery(Duration target) {
    _seekRecoveryStartedAt = DateTime.now();
    _seekRecoveryTarget = target;
  }

  void _logSeekRecoveryIfReady() {
    final startedAt = _seekRecoveryStartedAt;
    final target = _seekRecoveryTarget;
    if (startedAt == null || target == null || !_wantPlay) return;
    final position = _absPosition(_playbackPosition);
    if (!_playbackCompleted &&
        position < target + const Duration(milliseconds: 250)) {
      return;
    }
    ClientLogger.instance.info(
      'seek恢复 ${DateTime.now().difference(startedAt).inMilliseconds}ms '
      'target=${target.inMilliseconds}ms position=${position.inMilliseconds}ms',
      route: 'player.seek/${_sessionId ?? 'direct'}',
    );
    _seekRecoveryStartedAt = null;
    _seekRecoveryTarget = null;
  }

  /// 第几次 `open()`。同一个 open 只允许「首片没到就补开」一次 ——
  /// 没有这个计数的话，失败→重开→再失败会把画面刷成闪烁（早期线上问题）。
  int _openGen = 0;
  int _retriedOpenGen = -1;

  /// 「这台机器直连解不动」的落盘清单（`codec@height`，逗号分隔）。
  ///
  /// 手机端 4K AV1 直连实测：8 秒里播放位置只走了 66ms，画面是黑的。
  /// 用户一旦把默认档存成「原画」，就是**每次进播放页都黑一遍再切**、提示反复弹。
  /// 这里只将 Android TV 上「缓冲充足但无视频帧 / 解码停滞」判定为解码失败并自动回退。
  /// 其他设备或网络异常显示错误与可选转码入口，不以码率/分辨率自动改变策略。
  static const _directBlockKey = 'player.directBlock';

  /// 直连清单一次性清空的标记（见 [_clearLegacyDirectBlocks]）。
  static const _directBlockResetKey = 'player.directBlock.resetMedia3';

  /// 服务端回传的**实际**编码（降级后以它为准）；为空表示还没出片。
  String? _actualCodec;
  bool? _actualToneMap;
  bool? _sessionAudioNormalizeEffective;
  bool? _decodedVideoFrame;

  /// 「服务端把编码降级了」这条提示只弹一次，别每 3 秒轮询都刷一遍。
  bool _codecNoticeShown = false;
  bool _originalFallbackAttempted = false;

  /// 上次刷新隐藏定时器的时间，用来给 `onHover` 做节流。
  DateTime _lastPoke = DateTime.fromMillisecondsSinceEpoch(0);

  /// 「play() 被 pause() 打断」这类良性错误的静默重试次数。
  /// 浏览器换 src 时必然先 pause 旧的 play()，产生的 DOMException 长得像错误，
  /// 但播放器随后会继续 —— 直接弹「播放失败」是误报（SMB 转码起播时高发）。
  int _benignRetries = 0;

  /// 本机 libmpv 的音频滤镜链起不来（安卓 libmpv 报警
  /// `Audio filter initialized failed!`）：置真之后这一场播放不再挂
  /// `af` / `audio-channels`，保证片子能播，只是没有响度归一与降混。
  /// 只在同一个播放页内有效，下次进播放器会重新试一次。
  bool _audioFilterDowngraded = false;

  /// Media3 报过「没有可用的音频解码器」（典型：EAC3 / DTS-HD 在部分安卓机上
  /// 确实没有解码器）。置真后改走「视频 copy + 音频 AAC」的会话，
  /// 画面不动，只换音轨。只试一次，避免来回切会话。
  bool _nativeAudioFallbackAttempted = false;

  /// 非空时 Media3 用「视频走原片 + 音频走这条流」的合并播放。
  ///
  /// 场景：手机没有 E-AC3 / DTS-HD 解码器，但视频本身能硬解（杜比视界由本机
  /// DV 解码器直通）。以前是把整片转封装成 fMP4，结果 ffmpeg 传不出 DV 的
  /// `dvcC` 配置，画面全黑。现在视频不动，只把音频换成服务端的 AAC。
  String? _mergedAudioUrl;

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
      ((widget.compat?['reasons'] as List?) ?? const [])
          .map((e) => '$e')
          .toList();

  /// 片源高度：显式参数优先，其次 stream-url 的 compat，最后当未知（0）。
  int get _srcHeight {
    final h = widget.sourceHeight ?? (widget.compat?['height'] as int?);
    return h == null || h <= 0 ? 0 : h;
  }

  /// 直连能力的指纹：`编码@高度`。拿不到编码 / 高度时返回空串（不参与记忆）。
  String get _directKey {
    final codec = '${widget.compat?['videoCodec'] ?? ''}'.toLowerCase().trim();
    if (codec.isEmpty || _srcHeight <= 0) return '';
    return '$codec@$_srcHeight';
  }

  /// 同样特征的片源上次是不是「直连解不动」（见 [_directBlockKey]）。
  bool get _directBlocked {
    final key = _directKey;
    if (key.isEmpty) return false;
    final raw = SettingsStore.instance.getString(_directBlockKey) ?? '';
    return raw.split(',').contains(key);
  }

  /// 一次性清空「直连解不动」清单。
  ///
  /// 那些记录是 libmpv 判出来的（它不解析 DV RPU，DV / 10bit HEVC 直连必黑，
  /// 于是写进 `hevc@1608` 这类指纹）。安卓现在统一走 Media3 + 系统解码器，
  /// 失败会明确回调，不认这份旧账 —— 但用户在旧版本里已经攒下的记录不会自己消失，
  /// 表现就是「这部 DV 片永远强制转码」。这里清一次并打上标记。
  Future<void> _clearLegacyDirectBlocks() async {
    final store = SettingsStore.instance;
    if (store.getString(_directBlockResetKey) == '1') return;
    if ((store.getString(_directBlockKey) ?? '').isNotEmpty) {
      await store.setString(_directBlockKey, '');
      ClientLogger.instance.info(
        '清空旧的直连失败记录（libmpv 时代）',
        route: 'player.migrate',
      );
    }
    await store.setString(_directBlockResetKey, '1');
  }

  /// 记住 / 忘掉「这台机器直连解不动这个特征」。
  Future<void> _markDirectBlocked(bool blocked) async {
    final key = _directKey;
    if (key.isEmpty) return;
    final raw = SettingsStore.instance.getString(_directBlockKey) ?? '';
    final keys = raw.split(',').where((e) => e.isNotEmpty).toList();
    if (blocked == keys.contains(key)) return;
    if (blocked) {
      keys.add(key);
    } else {
      keys.remove(key);
    }
    // 只留最近 12 条：常见组合就那几个，别把设置项养肥
    final kept = keys.length > 12 ? keys.sublist(keys.length - 12) : keys;
    await SettingsStore.instance.setString(_directBlockKey, kept.join(','));
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
    //
    // TV 第一次进来默认「原画」：电视本来就该放原片，转码是降级；
    // 用户一旦在「我的 → 默认码率」里存过值，就按存的那档走。
    final requestedPreset =
        widget.initialPreset ??
        (PlayPreferences.codec == 'original'
            ? 'original'
            : PlayPreferences.savedPreset ?? PlayPreferences.preset);
    final preferred = requestedPreset == 'original' && _codec != 'original'
        ? PlayPreferences.preset
        : requestedPreset;
    _preset = clampPresetForSource(preferred, _srcHeight, codec: _codec);
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
    _tvMedia3Player = TvMedia3PlayerController();
    _logSubs.add(_tvMedia3Player.states.listen(_onTvMedia3State));
    // Android 13+ 没有 POST_NOTIFICATIONS 就看不到状态栏的媒体卡。
    // 音乐 / 播客链路早就申请了，视频这条以前漏了 —— 用户反馈「播电影状态栏没有卡片」。
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      unawaited(ensureAndroidNotificationPermission());
      // 安卓早已全量交给原生 Media3（系统解码器），但早期 libmpv 链路学到的
      // 「直连解不动」记录还留在设置里，会把 HDR / 杜比视界片永久锁进转码档。
      unawaited(_clearLegacyDirectBlocks());
    }
    // 停滞看门狗**在这里起一次**，之后整页生命周期内不再取消（除 dispose）。
    // 以前是每个 seek / 每次 open 各挂一个、还互相 cancel，于是留下了三次
    // 「画面冻住了但日志里一条告警都没有」的事故。常驻之后，任何一条路径都
    // 只能重置判定基准（[_armStallWatch]），不能让它消失。
    _armStallWatch();
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
        // 电视上原片直连必须走系统硬解：4K HEVC / DV / HDR10+ 交给 MediaCodec。
        // `auto-safe` 在部分盒子上会自己降级成软解或 mediacodec-copy，
        // 结果是「有画面但几秒一卡」，还把 HDR 元数据在拷贝里丢掉。
        final hwdec = defaultTargetPlatform == TargetPlatform.android && _tvMode
            ? 'mediacodec'
            : 'auto-safe';
        // ignore: avoid_dynamic_calls
        (_player.platform as dynamic).setProperty('hwdec', hwdec);
      } catch (_) {
        // 拿不到就算了，退回软解
      }
    }
    // 色调映射参数（hdr-compute-peak / tone-mapping / dither）必须赶在 open 之前：
    // media_kit 初始化时把 hdr-compute-peak 显式设成了 no，不覆盖就会「HDR 直连发灰」。
    _renderReady = _setupRender();
    _controller = VideoController(_player);
    _logSubs.add(
      _player.stream.playing.listen((playing) {
        if (_nativeTvActive) return;
        // TV 的播放/暂停按钮图标要跟着变（索引式控制层不是 StreamBuilder）
        if (mounted && _tvMode) setState(() {});
        // 暂停期间画面不动是用户自己的意愿，看门狗会跳过判定（[stallSkipQuiet]）；
        // 恢复播放要把判定基准挪到当前位置重新计数，否则「暂停一下再播」之后
        // 会把暂停那段累进停滞计数里。
        if (playing) _armStallWatch();
        // 播放器自己停了、而用户并没有按过暂停（[_wantPlay] 仍为 true）：
        // 典型就是拖进度条触发换源后浏览器把这次播放丢了。补一次，别让人手点。
        // 用户点暂停时 `_togglePlay` 会先把 _wantPlay 置 false，所以不会抢。
        if (!playing &&
            mounted &&
            _wantPlay &&
            !_jumping &&
            !_switching &&
            !_playbackCompleted) {
          unawaited(_resumeIfIdle('playing 掉了'));
        }
        ClientLogger.instance.info(
          'playing=$playing',
          route: 'player.state/${_sessionId ?? 'direct'}',
        );
      }),
    );
    _logSubs.add(
      _player.stream.buffering.listen((buffering) {
        if (_nativeTvActive) return;
        ClientLogger.instance.info(
          'buffering=$buffering',
          route: 'player.state/${_sessionId ?? 'direct'}',
        );
        // 「缓冲几秒、数据够了却不自己播」正是用户报的现象：换源 / seek 会把
        // 浏览器那次 play() 打断，media_kit 只把它塞进 error 流，没人再补。
        // 缓冲结束后如果仍然没在播、而用户意图是播（[_wantPlay]），补一次。
        if (!buffering &&
            mounted &&
            _wantPlay &&
            !_playbackPlaying &&
            !_playbackCompleted) {
          unawaited(_resumeIfIdle('缓冲结束'));
        }
      }),
    );
    _logSubs.add(
      _player.stream.completed.listen((done) {
        if (_nativeTvActive) return;
        if (done) {
          ClientLogger.instance.info(
            '播放结束 transcodedMs=$_transcodedMs',
            route: 'player.state/${_sessionId ?? 'direct'}',
          );
        }
      }),
    );
    _loadUiPrefs();

    _player.stream.error.listen((message) {
      if (_nativeTvActive) return;
      if (!mounted) return;
      // 播放失败必须进服务端日志：装上就用的人看不到控制台，界面只显示一行
      // 「播放失败」，光靠它没法判断是解码器、令牌还是转码的问题。
      ClientLogger.instance.error(
        message,
        route: 'player',
        detail:
            'item=${widget.itemId} session=$_sessionId preset=$_preset '
            'codec=$_codec url=${_redactedUrlForLog(_url)}',
      );
      // 「play() 被新 load / 移除元素打断」是浏览器换 src 的正常副作用，
      // 不是播放失败：既不重开（会再次打断新的 play()），也不显示错误页。
      // 以前它走良性重试，4 次后把错误页摆上来 → 与视频交替出现，就是一直闪。
      if (_isPlayInterrupted(message)) {
        // 但这次中断把「本来要播」的请求也吞掉了：换源 / seek 之后浏览器
        // 不会自己再 play，画面就停在暂停等手点。补一次（用户按过暂停才不补）。
        unawaited(_resumeIfIdle('play 被打断'));
        return;
      }
      if (_isBenignPlaybackError(message)) {
        _retryAfterBenignError(message);
        return;
      }
      // 音频滤镜挂不上是「可选效果」失败，不是片子放不了：
      // 关掉滤镜重开，别把人挡在「播放失败」页外面。
      if (_isAudioFilterError(message)) {
        _downgradeAudioFilter(message);
        return;
      }
      setState(() => _error = message);
      _renewIfTokenExpired(message);
    });

    // 换集占位图：
    // - 安卓原生 Media3 链路由 [_onTvMedia3State] 的首帧回调撤图；
    // - 桌面 / Web 的 media_kit 纹理链路在这里等第一帧解出来（videoParams）。
    // 12 秒还没出帧就兜底撤掉，绝不能让一张图把画面永久盖住。
    if (widget.previewItem != null) {
      _openingFrameGuard = Timer(const Duration(seconds: 12), _dropOpeningFrame);
      _logSubs.add(
        _player.stream.videoParams.listen((p) {
          if (_nativeTvActive) return;
          if ((p.dw ?? p.w ?? 0) > 0) _dropOpeningFrame();
        }),
      );
    }

    // initState 里不能取 ScaffoldMessenger 这类 InheritedWidget：
    // dependOnInheritedWidgetOfExactType 要求 initState 已经走完，否则
    // _prepareCompatible 的第一行就会抛「called before initState() completed」，
    // 连带转码会话与 open() 全都不执行（黑屏）。统一推到首帧之后再启动。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 请求转码的原因：源格式不适合直连，或所选策略是 H.265 / AV1。
      // 原码策略保持直连优先；编码策略不能因为用户尚未保存过偏好就被忽略。
      //
      // 注意 initialPreset != null 时调用方已经建好会话（详情页「转码」对话框），
      // 那个地址本身就是目标档位，必须直接 open，不能再自己建一遍会话。
      final wantsTranscode =
          widget.initialPreset == null && _codec != 'original';
      if ((_needTranscode || wantsTranscode) && widget.itemId != null) {
        // 以前这里会把「原画」直接改写成 1080P 3M —— 于是用户明明选了原画，
        // 播放器却自己降档（「过了一会儿变成 1080p 3m」的主因之一）。
        // 现在不再改写：直连不直连由 _prepareCompatible 按「本机能不能正确显示」
        // 判定，必须转码时也只退到「保住片源分辨率」的档位。
        _prepareCompatible();
      } else {
        // 本地续播：startAt 只在直连路径生效（转码流的 0 点是起转点，不能直接 seek）
        _openUrl(
          _url,
          seekTo: widget.startAt,
        ).then((_) => _attachLocalSubtitles());
      }
      _loadSubtitles();
      _loadAudioTracks();
      _loadPlaylist();
      _resetHideTimer();
    });
  }

  /// 挂上本地外挂字幕。
  ///
  /// 只挂第一条（通常就是主字幕）：libmpv 会把 setSubtitleTrack 指定的文件加进
  /// 轨道列表，播放器的字幕菜单里照样能切回内嵌轨 / 关字幕。
  /// 失败不提示 —— 字幕挂了不影响看片。
  Future<void> _attachLocalSubtitles() async {
    if (widget.localSubtitles.isEmpty) return;
    try {
      final first = widget.localSubtitles.first;
      // Windows 是反斜杠、Android 是正斜杠：两边都要切
      final name = first.split(RegExp(r'[\\/]')).last;
      await _player.setSubtitleTrack(SubtitleTrack.uri(first, title: name));
    } catch (_) {
      // 文件被删 / 格式不认：静默跳过
    }
  }

  /// 进播放器那一刻的朝向，只记一次。
  ///
  /// 退出全屏 / 退出播放器要还原成它（见 `player_screen_stub.dart`）：
  /// 竖着进来就锁回竖屏，横着进来（TV / 平板横放）就放开朝向。
  /// `initState` 里不能读 MediaQuery，所以放在这里。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _entryPortrait ??=
        MediaQuery.orientationOf(context) == Orientation.portrait;
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
      final picked =
          res.items
              .where(
                (it) =>
                    relatedDir(it.path).toLowerCase() == dir.toLowerCase() &&
                    relatedMatches(prefix, relatedBasename(it.path)),
              )
              .toList()
            ..sort(
              (a, b) => compareRelatedNames(
                relatedBasename(a.path),
                relatedBasename(b.path),
              ),
            );
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

  void _onTvMedia3State(TvMedia3State state) {
    final previous = _lastTvMedia3State;
    _lastTvMedia3State = state;
    if (state.videoWidth > 0 && state.videoHeight > 0) {
      _decodedVideoFrame = true;
    }
    if (_nativeTvActive &&
        state.videoDecoder.isNotEmpty &&
        state.videoDecoder != previous.videoDecoder &&
        _nativeDecoderLoggedGeneration != _openGen) {
      _nativeDecoderLoggedGeneration = _openGen;
      ClientLogger.instance.info(
        'Media3 首帧/解码器就绪 decoder=${state.videoDecoder} '
        'size=${state.videoWidth}x${state.videoHeight} '
        'view=${state.viewWidth}x${state.viewHeight} '
        'surface=${state.surfaceWidth}x${state.surfaceHeight}',
        route: 'player.decode/${_sessionId ?? 'direct'}',
      );
      // 只有电视需要：核对 Media3 真正看到的轨道 MIME 与设备 DV 解码器能力
      if (_tvMode) unawaited(_logNativeCodecDiagnostics());
    }
    if (_nativeTvActive &&
        state.firstFrameMs != null &&
        previous.firstFrameMs == null &&
        _nativeFirstFrameLoggedGeneration != _openGen) {
      _nativeFirstFrameLoggedGeneration = _openGen;
      ClientLogger.instance.info(
        'Media3 首帧 ${state.firstFrameMs}ms decoder=${state.videoDecoder}',
        route: 'player.decode/${_sessionId ?? 'direct'}',
      );
    }
    // 第一帧已经上屏：把换集时铺着的抽帧撤掉，让视频从占位图同一个位置接着播
    if (state.firstFrameMs != null && _showOpeningFrame) _dropOpeningFrame();
    final error = state.error;
    if (_nativeTvActive && error != null && error.isNotEmpty) {
      unawaited(_handleTvMedia3Error(error));
    }
    // 音频没有解码器（手机上的 E-AC3 / DTS-HD）：画面继续走原片，
    // 另外向服务端要一条 AAC 音频流合并进来。整片转封装会丢杜比配置，
    // 所以只换音轨、视频不动。
    if (_nativeTvActive &&
        state.audioUnsupported &&
        !_nativeAudioFallbackAttempted) {
      unawaited(_startAudioMerge());
    }
    if (_nativeTvActive &&
        error == null &&
        state.isPlaying != previous.isPlaying &&
        !state.isPlaying &&
        !state.isBuffering &&
        _wantPlay &&
        !_jumping &&
        !_switching &&
        !state.isCompleted) {
      unawaited(_resumeIfIdle('Media3 播放状态停止'));
    }
    if (_nativeTvActive &&
        error == null &&
        previous.isBuffering &&
        !state.isBuffering &&
        _wantPlay &&
        !state.isPlaying &&
        !state.isCompleted) {
      unawaited(_resumeIfIdle('Media3 缓冲结束'));
    }
    if (mounted &&
        (state.isPlaying != previous.isPlaying ||
            state.isBuffering != previous.isBuffering ||
            state.isCompleted != previous.isCompleted ||
            state.videoWidth != previous.videoWidth ||
            state.videoHeight != previous.videoHeight ||
            state.videoDecoder != previous.videoDecoder ||
            state.firstFrameMs != previous.firstFrameMs)) {
      setState(() {});
    }
  }

  /// 把原生侧解析到的轨道 MIME 与解码器能力写进客户端日志（仅排障用）。
  Future<void> _logNativeCodecDiagnostics() async {
    final diag = await TvMedia3PlayerController.codecDiagnostics();
    if (diag.isEmpty) return;
    ClientLogger.instance.info(
      'Media3 解码器诊断',
      route: 'player.decode/${_sessionId ?? 'direct'}',
      detail: diag,
    );
  }

  Future<void> _handleTvMedia3Error(String message) async {
    ClientLogger.instance.error(
      'Media3 播放失败：$message',
      route: 'player',
      detail:
          'item=${widget.itemId} session=$_sessionId preset=$_preset '
          'codec=$_codec url=${_redactedUrlForLog(_url)}',
    );
    // 音频没有解码器：视频照原样 copy，只把音频换成 AAC。
    // 绝不能走 `_transcodeFallback` —— 那会把 4K 杜比视界整片重压成 1440p，
    // 为了一个音轨把画质和起播时间全赔进去（实测：转码任务直接排不上队、
    // 首片等 8 秒后被取消，用户看到的就是「转码也播不出来」）。
    final audioOnly = message.toLowerCase().contains(
      'no suitable decoder for audio',
    );
    if (_nativeTvActive &&
        audioOnly &&
        widget.itemId != null &&
        !_nativeAudioFallbackAttempted) {
      _nativeAudioFallbackAttempted = true;
      _showNotice(
        tr('player.audioFallback'),
        log: 'Media3 音频无解码器：$message → 视频 copy + 音频 AAC',
      );
      try {
        if (mounted) setState(() => _preparing = true);
        // 只让服务端转音频（视频原件不动）：返回的 HLS 里视频是 copy，
        // 我们只取它的音频轨，视频轨在 Media3 侧被禁用。
        // `audioOnly`：别让服务端顺手把 4K DV 也 tonemap 一遍，这条流只取音频。
        final audioStream = await _ensureTranscode(
          'original',
          defaultTranscodeCodec(),
          audioOnly: true,
        );
        if (!mounted) return;
        final resumeAt = _playbackPosition;
        setState(() {
          _error = null;
          _isTranscode = true;
          _preset = 'original';
          _codec = 'original';
          _mergedAudioUrl = audioStream;
          _preparing = false;
        });
        // 视频仍用原片直链：杜比视界的 dvcC 配置完整，交给本机 DV 解码器
        await _openUrl(
          _directUrl,
          seekTo: resumeAt > Duration.zero ? resumeAt : null,
          retries: 3,
        );
      } catch (e) {
        if (mounted) setState(() => _preparing = false);
        ClientLogger.instance.warn('音频分离失败：$e', route: 'player.audio');
      }
      return;
    }
    // 电视上的「隧道模式」先关掉再试一次：部分电视芯片（尤其杜比视界）不支持
    // tunneled playback，Media3 打开就报 no suitable decoder / decoder init，
    // 而同一路原片关掉隧道后能正常出帧。不先试这一步，表现就是
    // 「这片在手机上原片直出，在电视上被直接丢去转码」。
    if (_nativeTvActive &&
        _tvMode &&
        !_tunnelOffRetried &&
        !message.toLowerCase().contains('illegalargumentexception') &&
        !message.toLowerCase().contains('illegalstateexception') &&
        !_isTranscode &&
        widget.itemId != null &&
        _isExplicitDecoderOpenFailure(message)) {
      _tunnelOffRetried = true;
      ClientLogger.instance.warn(
        'Media3 隧道模式失败 → 关隧道重开原片：$message',
        route: 'player',
      );
      _showNotice(tr('player.tunnelOffRetry'), log: '关隧道重试原片');
      final resumeAt = _playbackPosition;
      await _openUrl(
        _url,
        seekTo: resumeAt > Duration.zero ? resumeAt : null,
        retries: 0,
      );
      return;
    }
    // 直连解不了就退到「视频 copy + 音频转 AAC」的转码会话。
    // 手机 / 平板现在也走 Media3，所以不再限定 TV 模式 —— 否则手机会直接
    // 弹「播放失败」，而电视上同一个片源却能自动回落。
    if (_nativeTvActive &&
        !_isTranscode &&
        widget.itemId != null &&
        !_nativeFallbackAttempted &&
        _isExplicitDecoderOpenFailure(message)) {
      _nativeFallbackAttempted = true;
      final codec = _codec == 'original' ? defaultTranscodeCodec() : _codec;
      final preset = _transcodeFallback(codec: codec);
      await _switchQuality(preset, codec: codec, persist: false, notify: false);
      if (mounted) {
        _showNotice(
          tr('player.directFailed', {
            'actual': playQualityPresetOf(preset)?.labelFor(codec) ?? preset,
          }),
          log: 'Media3 明确解码失败：$message → $preset/$codec',
        );
      }
      return;
    }
    if (mounted) setState(() => _error = message);
    _renewIfTokenExpired(message);
  }

  /// 音频没有解码器时：建一条「视频原样 copy + 音频 AAC」的会话，
  /// 只把这条流的音频合并到原片视频上播放。
  ///
  /// 不能整片转封装后再播 —— ffmpeg 传不出杜比的 dvcC 配置（实测三种 tag
  /// 都不写），画面会黑；而重编码又要为一条音轨赔掉整片画质。
  Future<void> _startAudioMerge() async {
    if (_nativeAudioFallbackAttempted || widget.itemId == null) return;
    _nativeAudioFallbackAttempted = true;
    _showNotice(
      tr('player.audioFallback'),
      log: 'Media3 音频无解码器 → 视频原片 + 音频 AAC 合并播放',
    );
    try {
      if (mounted) setState(() => _preparing = true);
      final audioStream = await _ensureTranscode(
        'original',
        defaultTranscodeCodec(),
        audioOnly: true,
      );
      if (!mounted) return;
      final resumeAt = _playbackPosition;
      setState(() {
        _error = null;
        _isTranscode = true;
        _preset = 'original';
        _codec = 'original';
        _mergedAudioUrl = audioStream;
        _preparing = false;
      });
      // 视频仍用原片直链（杜比配置完整），音频由 _mergedAudioUrl 提供
      await _openUrl(
        _directUrl,
        seekTo: resumeAt > Duration.zero ? resumeAt : null,
        retries: 3,
      );
    } catch (e) {
      if (mounted) setState(() => _preparing = false);
      ClientLogger.instance.warn('音频分离失败：$e', route: 'player.audio');
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _seekHintTimer?.cancel();
    _noticeTimer?.cancel();
    _stallTicker?.cancel();
    _seekByTimer?.cancel();
    _tvHoldDelay?.cancel();
    _tvHoldTick?.cancel();
    _tryOriginalTimer?.cancel();
    _openingFrameGuard?.cancel();
    // 离开播放页：根背景层恢复，原生视频层在下面同步摘掉。
    // 换集是「新页面先建、旧页面后销毁」，旧页面此时已经不是原生层的所有者，
    // 再置 false 会把新页面刚露出来的视频盖成纯黑（用户看到的就是空白页）。
    if (_tvMedia3Player.isActiveInstance) {
      nativeVideoLayerActive.value = false;
    }
    for (final sub in _logSubs) {
      sub.cancel();
    }
    _volumeVN.dispose();
    _swipeAnim.dispose();
    _swipeOffset.dispose();
    // 退出播放器（可能是**在全屏里按返回**，而不是先点退出全屏）必须把屏幕
    // 朝向还回去：全屏时按视频比例锁了 landscape，只还原 SystemUiMode 的话
    // 人已经回到列表页、手机还横着 —— 用户反馈「退出影片以后一直是横屏」。
    unawaited(exitPlayerFullscreen(portrait: _wantPortraitOnExit));
    // 先把位置交出去再销毁播放器：本地播放要用它写进度
    try {
      widget.onPosition?.call(_playbackPosition);
    } catch (_) {
      // 播放器已经不可用（初始化失败）：没有位置可报
    }
    AudioFocus.instance.release(_player);
    AudioFocus.instance.release(_tvMedia3Player);
    unawaited(_tvMedia3Player.dispose());
    _player.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------ 播放源

  Future<void> _openUrl(
    String u, {
    Duration? seekTo,
    int retries = 0,
    bool resetBenignRetries = true,
    bool? autoPlay,
  }) async {
    await _renderReady;
    if (!mounted) return;
    // 旧页面已被新播放页接管：它自己的重试 / 兜底不能再抢共用的原生会话，
    // 否则两个页面交替 open，新页面永远起不来（黑屏）。
    if (!_tvMedia3Player.isActiveInstance) return;
    final openGen = ++_openGen;
    _url = u;
    final useNativeTv = _shouldUseNativeTvPlayer;
    // 排障用：一条日志看清这次到底走哪条链路、为什么 —— 「电视上这片被强制转码」
    // 时，看 preset / codec / directBlocked / srcH 就知道是偏好档、旧记录还是
    // 颜色判定把它拦下来的，不用再猜。
    ClientLogger.instance.info(
      '策略 media3=$useNativeTv tv=$_tvMode preset=$_preset codec=$_codec '
      'hdr=${_srcHdr.reason} srcH=$_srcHeight directBlocked=$_directBlocked '
      'tunneled=$_tvTunneled '
      'toneMapPref=${PlayPreferences.toneMap} displayHdr=${_display.maxHdr.reason}',
      route: 'player.strategy',
    );
    if (useNativeTv != _nativeTvActive) {
      setState(() {
        _nativeTvActive = useNativeTv;
        _nativeSurfaceReady = false;
      });
      // 切走原生链路时根背景立刻恢复；切到原生则等原生视图真正挂上再让路
      if (!useNativeTv) nativeVideoLayerActive.value = false;
      if (useNativeTv) {
        await _player.stop();
      } else {
        await _tvMedia3Player.stop();
      }
    }
    if (!mounted || openGen != _openGen) return;
    _nativeFallbackAttempted = false;
    _seekQueue.invalidate();
    _lastOpenAt = DateTime.now();
    // 音频处理：直连时套本地滤镜，转码流清空（服务端已处理过）。
    _applyDirectAudio();
    // 直连走的是网络 Range 读原片，码率可能到 60~80Mbps。libmpv 默认 demuxer
    // 缓存只有几十 MB，高码率片源一开播就把缓存抽干 → 反复 buffering、
    // 被看门狗判成「链路跟不上」。这里给直连放开到 256MB 前向 + 60 秒，
    // 转码流不动（分片本身只有几百 KB，加大缓存没有意义）。
    _applyDirectCache();
    // 换了播放源：位置不再连续，判定基准要挪到新流的起点。
    // ⛔ 只重置判定，**不取消看门狗** —— 以前这里 cancel，换流期间一旦出岔子
    // 看门狗就永久缺席（`c16e2aeb` 116 秒静默就是这么来的）。
    _stall.reset(Duration.zero);
    _decodedVideoFrame = null;
    final openSw = Stopwatch()..start();
    // 要不要在打开后自动播：默认沿用用户意图（跳转 / 首播 = 想播，暂停中换档 = 不想播）
    final want = autoPlay ?? _wantPlay;
    if (want) _wantPlay = true;
    ClientLogger.instance.info(
      'open 开始',
      route: 'player.open/${_sessionId ?? 'direct'}',
      detail: _redactedUrlForLog(u),
    );
    try {
      // 视频也带声音：开播前先让音乐 / 播客 / 音色试听让路
      await AudioFocus.instance.request(
        useNativeTv ? _tvMedia3Player : _player,
        useNativeTv ? _tvMedia3Player.pause : _player.pause,
      );
      if (!mounted || openGen != _openGen) return;
      // `play: want` 显式给意图：media_kit 的默认值是 true，换档时如果用户
      // 本来是暂停状态（在挑画质），默认值会莫名其妙自己播起来。
      if (useNativeTv) {
        // 音视频分离时 `u` 仍是原片直链（只有音频走 HLS），不能按 HLS 声明，
        // 否则 Media3 会把 MKV/MP4 当 m3u8 解析直接失败。
        // 反过来，只要 URL 本身就是播放列表（`.m3u8`），就必须按 HLS 声明，
        // 否则 Media3 走 ProgressiveMediaSource，报“没有解复用器能读”。
        final isHlsUrl = Uri.tryParse(u)?.path.toLowerCase().endsWith('.m3u8') ?? false;
        final formatHint = (isHlsUrl || (_isTranscode && _mergedAudioUrl == null))
            ? 'hls'
            : (widget.compat?['container'] as String? ??
                  Uri.tryParse(u)?.path.split('.').last ??
                  '');
        await _tvMedia3Player.open(
          url: u,
          positionMs: seekTo?.inMilliseconds ?? 0,
          play: want,
          formatHint: formatHint,
          // 隧道模式只在电视上开：手机 / 平板打开会黑屏（见 TvMedia3Playback.kt）。
          // 这台电视的隧道模式被判定不受支持后（[_tunnelOffRetried]），
          // 后续重开一律走非隧道，别再撞同一堵墙。杜比视界见 [_tvTunneled]。
          tunneled: _tvTunneled,
          // 音频轨手机解不了时，视频仍走原片、音频单独取服务端 AAC
          audioUrl: _mergedAudioUrl,
          // 通知栏 / 状态栏媒体卡的标题
          title: widget.title,
        );
      } else {
        await _player.open(Media(u), play: want);
      }
      if (!mounted || openGen != _openGen) return;
      // open 返回后播放器手里的位置才属于这条新流，[_absPosition] 可以正常算了
      _pendingStartMs = null;
      ClientLogger.instance.info(
        'open 完成 ${openSw.elapsedMilliseconds}ms',
        route: 'player.open/${_sessionId ?? 'direct'}',
      );
      // 实际用的解码器：`hwdec=auto-safe` 到底选中了硬解还是软解，只有 mpv 自己知道
      if (!useNativeTv) unawaited(_logDecodeInfo());
      // 起播之后立刻挂上停滞看门狗：第一次 open 也可能停在「首片到了但画面不走」，
      // 那时候没有任何 seek 可挂，光靠 seek 看门狗是接不住的。
      if (want) _armStallWatch();
      // 字幕走控制层自绘；关掉内核自带字幕轨，避免内嵌字幕再叠一层。
      // 自绘的 cue 是 State 字段，重开 Media 不需要重新挂载。
      if (!useNativeTv) {
        try {
          await _player.setSubtitleTrack(SubtitleTrack.no());
        } catch (_) {
          /* 部分平台没有字幕轨接口，忽略 */
        }
      }
      await _playbackSetRate(_rate);
      if (!mounted || openGen != _openGen) return;
      await _playbackSetVolume(_volume);
      if (!mounted || openGen != _openGen) return;
      if (useNativeTv) {
        await _tvMedia3Player.setRepeatMode(_nativeRepeatMode(_loop));
        if (!mounted || openGen != _openGen) return;
        await _tvMedia3Player.setShuffle(_shuffle);
      } else {
        await _player.setPlaylistMode(_loop);
        if (!mounted || openGen != _openGen) return;
        await _player.setShuffle(_shuffle);
      }
      if (!mounted || openGen != _openGen) return;
      if (!useNativeTv && seekTo != null && seekTo > Duration.zero) {
        // HLS 首帧就绪前 seek 会被吞掉，等一小拍再跳
        await Future<void>.delayed(const Duration(milliseconds: 350));
        await _queuePlayerSeek(seekTo, _seekGen, showLoading: false);
      }
      if (!mounted || openGen != _openGen) return;
      // 良性错误重试链里不能清零，否则「报错→重开→成功清零→又报错」无限循环，
      // 永远走不到 _benignRetries >= 2，黑屏且不显示任何错误。
      if (resetBenignRetries) _benignRetries = 0;
      if (mounted) setState(() => _error = null);
      // 见 _ensurePlayingAfterOpen：Web 上 open() 内部的 pause→play 竞态会把
      // 这次播放静默吞掉，必须补一轮，否则画面停在暂停等用户手点。
      if (want) unawaited(_ensurePlayingAfterOpen());
      // 直连保底：libmpv 解不了的容器/编码（典型 MKV + HEVC 10bit / DV）不会报错，
      // 而是「有声音、画面停在首帧」。8 秒还拿不到视频尺寸就自动切回转码。
      if (!_isTranscode) unawaited(_guardDirectPlayback(openGen));
    } catch (e) {
      if (!mounted || openGen != _openGen) return;
      ClientLogger.instance.warn(
        'open 失败 ${openSw.elapsedMilliseconds}ms: ${e.runtimeType}',
        route: 'player.open/${_sessionId ?? 'direct'}',
        detail: _redactedUrlForLog(u),
      );
      if (!_isTranscode &&
          _tvMode &&
          widget.itemId != null &&
          !_originalFallbackAttempted &&
          _isExplicitDecoderOpenFailure('$e')) {
        unawaited(_markDirectBlocked(true));
        final fallbackCodec = defaultTranscodeCodec();
        final fallback = _transcodeFallback(codec: fallbackCodec);
        _showNotice(
          tr('player.directFailed', {
            'actual':
                playQualityPresetOf(fallback)?.labelFor(fallbackCodec) ??
                fallback,
          }),
          log: 'TV 原片打开时明确解码失败：${e.runtimeType} → $fallback',
        );
        await _switchQuality(
          fallback,
          codec: fallbackCodec,
          persist: false,
          notify: false,
        );
        return;
      }
      // 边转边播的第一次打开会「打不开」：播放器拉 index.m3u8 时首片可能还没落盘
      // （服务端最多等 15s，超时就先给空 EVENT 列表），内核当场就报错退出。
      // 转码本身没失败，过一两秒分片就有了 —— 直接弹「播放失败」太冤。
      // 《匹诺曹》这种 4K DV 片首片要 5s 上下（HDR→SDR + 4K 解码初始化），
      // 正是最容易踩到这条的片源。重试 3 次（+6s）能给足首片时间。
      if (retries > 0 && _isTranscode && mounted) {
        await Future<void>.delayed(const Duration(milliseconds: 2000));
        if (!mounted) return;
        return _openUrl(
          u,
          seekTo: seekTo,
          retries: retries - 1,
          autoPlay: want,
        );
      }
      // 彻底放弃了这条流：位置又回到「不可信」状态，别让 [_absPosition] 继续
      // 按新会话起点报位置（进度条会显示一个根本没播到的点）。
      _pendingStartMs = null;
      if (mounted) {
        setState(() {
          _error = _originalFallbackAttempted
              ? tr('player.originalAlsoUnsupported')
              : e.toString();
        });
      }
      _renewIfTokenExpired(e.toString());
    }
  }

  /// 打一条「实际用了什么解码」的日志（每次 open 一条）。
  ///
  /// 用户问「手机明明支持 AV1 硬解」时，只有 mpv 自己知道答案：
  /// `hwdec-current` 是 `mediacodec` / `mediacodec-copy` 就是硬解，`no` 就是软解，
  /// 空串表示还没解出第一帧。顺带记下 `video-codec` 与像素格式，
  /// 「4K AV1 直连 8 秒只走 66ms」到底是解不动还是没数据一看便知。
  Future<void> _logDecodeInfo() async {
    if (kIsWeb) return;
    final openGen = _openGen;
    final sessionId = _sessionId;
    final sw = Stopwatch()..start();
    for (var i = 0; i < 8; i += 1) {
      await Future<void>.delayed(const Duration(milliseconds: 700));
      if (!mounted || openGen != _openGen) return;
      try {
        // ignore: avoid_dynamic_calls
        final p = _player.platform as dynamic;
        // ignore: avoid_dynamic_calls
        final codec = '${await p.getProperty('video-codec')}';
        if (!mounted || openGen != _openGen) return;
        // 还没解出第一帧时 video-codec 是 "no"
        if (codec.isEmpty || codec == 'no') continue;
        _decodedVideoFrame = true;
        // ignore: avoid_dynamic_calls
        final hwdec = '${await p.getProperty('hwdec-current')}';
        // ignore: avoid_dynamic_calls
        final pix = '${await p.getProperty('video-params/pixelformat')}';
        if (!mounted || openGen != _openGen) return;
        ClientLogger.instance.info(
          '首帧/解码器就绪 ${sw.elapsedMilliseconds}ms '
          'hwdec=${hwdec.isEmpty ? '?' : hwdec} codec=$codec pixfmt=$pix',
          route: 'player.decode/${sessionId ?? 'direct'}',
        );
        return;
      } catch (e) {
        if (!mounted || openGen != _openGen) return;
        _decodedVideoFrame = null;
        ClientLogger.instance.warn(
          '读取解码器属性失败：${e.runtimeType}',
          route: 'player.decode/${sessionId ?? 'direct'}',
        );
        return;
      }
    }
    if (!mounted || openGen != _openGen) return;
    _decodedVideoFrame = false;
    ClientLogger.instance.warn(
      '首帧未就绪 ${sw.elapsedMilliseconds}ms '
      'width=$_playbackWidth buffering=$_playbackBuffering',
      route: 'player.decode/${sessionId ?? 'direct'}',
    );
  }

  /// open() 之后核对「到底播起来没有」，没播就补 play()。
  ///
  /// Web 端 `open()` 内部是 `element.pause()` 紧跟 `element.play()`，两个 Promise
  /// 在同一个事件循环里竞态：Chrome 常把 play() 判成 `interrupted by a call to
  /// pause` 并拒绝。media_kit 只把这个拒绝塞进 error 流，而客户端在「刚 open /
  /// 刚 seek 的 3 秒内」把这类错误当自己换流造成的静默忽略 —— 结果画面停在暂停，
  /// 用户只能手点。跳转尤其明显：新会话要等 3~8s 首片，用户手势早过期了。
  ///
  /// 只在用户意图是「播」时动手（[_wantPlay]），不会把用户按的暂停顶掉；
  /// 有新的跳转 / 换档在进行时直接让位，免得和新的 open 抢同一个元素。
  Future<void> _ensurePlayingAfterOpen() async {
    for (var i = 0; i < 5; i += 1) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (!mounted) return;
      // 这里必须 continue 不能 return：这个方法是在 `_openUrl` 内部启动的，
      // 那一刻 `_jumping` 还是 true（`_jumpTo` 要等 open 返回才清标志）。
      // 以前直接 return，等于每次跳转都白白放弃补播 —— 拖完停在暂停的根因之一。
      if (_jumping || _switching) continue;
      if (!_wantPlay) return;
      if (_playbackPlaying || _playbackCompleted) return;
      // 正在拉流（buffering）说明这次播放请求已经被接受，插一脚只会打断它
      if (_playbackBuffering) continue;
      final pos = _playbackPosition;
      await _playbackPlay();
      ClientLogger.instance.info(
        '补播 play() #${i + 1} pos=${pos.inMilliseconds}ms',
        route: 'player.resume/${_sessionId ?? 'direct'}',
      );
    }
  }

  /// 用户点了播放 / 暂停（控制条、空格、遥控器、手势都走这里）。
  ///
  /// 统一入口只为记下「用户到底想不想播」：[_ensurePlayingAfterOpen] 靠它
  /// 决定要不要补播 —— 用户主动按的暂停必须尊重，浏览器自己丢掉的那次播放才补。
  void _togglePlay() {
    // buffering 时 `playing` 是 false，但用户此刻按的显然是「暂停」
    final nowPlaying = _playbackPlaying || _playbackBuffering;
    _wantPlay = !nowPlaying;
    if (_nativeTvActive) {
      unawaited(nowPlaying ? _playbackPause() : _playbackPlay());
    } else {
      _player.playOrPause();
    }
  }

  /// 缓冲刚结束 / 换流之后，播放器没在播就补一次 play（800ms 内只补一次）。
  ///
  /// 用户的原话是「加载了几秒可以播了，就要继续播呀」—— 数据够了但没人按
  /// play，画面就停在那儿。这里把「补播」收成一个入口，日志统一打
  /// `player.resume/...`，真出问题能直接从日志看出补了几次。
  Future<void> _resumeIfIdle(String why) async {
    final now = DateTime.now();
    final last = _lastResumeAt;
    if (last != null &&
        now.difference(last) < const Duration(milliseconds: 800)) {
      return;
    }
    if (!mounted || _jumping || _switching || !_wantPlay) return;
    // 还没装过播放地址（首帧之前的初始 playing=false）时没得补
    if (_url.isEmpty) return;
    if (_playbackPlaying || _playbackBuffering || _playbackCompleted) return;
    _lastResumeAt = now;
    final pos = _playbackPosition;
    await _playbackPlay();
    ClientLogger.instance.info(
      '补播 play() [$why] pos=${pos.inMilliseconds}ms',
      route: 'player.resume/${_sessionId ?? 'direct'}',
    );
  }

  /// 浏览器换 src / seek 时主动中断上一个 `play()` 的 DOMException。
  ///
  /// 典型文案：
  /// - The play() request was interrupted by a new load request.
  /// - The play() request was interrupted because the media was removed from the document.
  ///
  /// 这是我们自己换流造成的，播放器随后会继续，不能当错误处理。
  bool _isPlayInterrupted(String message) {
    final m = message.toLowerCase();
    return m.contains('media was removed from the document') ||
        m.contains('interrupted by a new load request') ||
        (m.contains('play()') && m.contains('interrupt'));
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
    final young = _playbackPosition <= const Duration(seconds: 2);
    final fatalOpen =
        message.toLowerCase().contains('failed to open') ||
        message.toLowerCase().contains('failed to recognize') ||
        message.toLowerCase().contains('404');
    // 「一次都还没播起来」就报「打不开」：这是首片还没落盘的 404（AV1 首片
    // 8~10s，比固定 10s 的等待预算还长的时候就会撞上）。这种情况**必须**补开
    // 一次，否则播放器整场 fatal 黑屏 —— 用户看到的就是「跳完进度条一直黑着」。
    // 但同一个 open 只补一次、总共最多补两次，避免失败→重开→再失败把画面刷成闪烁。
    if (young &&
        fatalOpen &&
        !_jumping &&
        !_switching &&
        _benignRetries < 2 &&
        _retriedOpenGen != _openGen) {
      _retriedOpenGen = _openGen;
      _benignRetries += 1;
      final target = _url;
      if (target.isEmpty) return;
      ClientLogger.instance.warn(
        '首片未就绪就 open 失败（$message）→ 补开一次',
        route: 'player.retry/${_sessionId ?? 'direct'}',
      );
      Future<void>.delayed(const Duration(milliseconds: 1500), () {
        if (!mounted || _playbackPlaying) return;
        _openUrl(target, resetBenignRetries: false);
      });
      return;
    }
    // 跳转 / 换档 / 刚 open 或刚 seek 的 3 秒内，浏览器必然抛
    // 「play() interrupted / media removed」——这是我们换流导致的，不能再
    // `_openUrl` 重开：重开又会中断新的 play()，表现就是画面一直闪、位置不动。
    if (_jumping ||
        _switching ||
        DateTime.now().difference(_lastSeekAt) < const Duration(seconds: 3) ||
        DateTime.now().difference(_lastOpenAt) < const Duration(seconds: 3)) {
      return;
    }
    if (_benignRetries >= 4) {
      setState(() => _error = message);
      return;
    }
    _benignRetries += 1;
    final target = _url;
    if (target.isEmpty) return;
    // 重开必须带上当前位置：转码流是 EVENT 播放列表（末尾没有 ENDLIST，语义是
    // 「从头播的直播」），裸重开就是从第一片重来 —— 用户看到的是「播几秒自己
    // 回到开头」。open 返回后播 seekTo 才能落回原位置。
    final resumeAt = _playbackPosition;
    Future<void>.delayed(const Duration(milliseconds: 900), () {
      if (!mounted || _playbackPlaying) return;
      _openUrl(
        target,
        seekTo: resumeAt > const Duration(seconds: 2) ? resumeAt : null,
        resetBenignRetries: false,
      );
    });
  }

  /// 直连播不出画面时的保底：自动切回转码并说明原因。
  ///
  /// 「原画」按用户要求是绝对不转码，但 libmpv 并不什么都能解 —— 实测 MKV +
  /// HEVC 10bit / 杜比视界的片源直连时音频正常出、`state.width` 一直是 0，
  /// 画面就停在首帧。这种情况不能静默让人对着封面干等，也不能偷偷转码
  /// （用户明确要原片），所以：明确提示 + 切成一个转码档位。
  Future<void> _guardDirectPlayback(int openGeneration) async {
    final startPos = _playbackPosition;
    // 2026-11-16：从「先睡满 8 秒再看一眼」改成 1 秒一拍地看。
    // 手机端 4K AV1 直连实测 8 秒只走了 66ms —— 用户就是「干黑 8 秒才看到提示」。
    // 判据要把「没出视频帧 / 解码停滞」与「网络没喂够」分开：
    //   缓冲 ≥2s 且解码未推进 → 解码跟不上；已知无视频帧则最多等 7s 初始化宽限；
    //   连缓冲都没有 → 是网速，多给几拍（最多 10 秒），不记成设备解码失败。
    var reason = '';
    var w = 0;
    var advanced = Duration.zero;
    var elapsed = Duration.zero;
    for (var i = 0; i < 10; i += 1) {
      await Future<void>.delayed(const Duration(seconds: 1));
      if (!mounted ||
          openGeneration != _openGen ||
          _isTranscode ||
          _error != null ||
          // 已被新播放页接管：旧页面不能再把共享会话切走
          !_tvMedia3Player.isActiveInstance) {
        return;
      }
      elapsed = Duration(seconds: i + 1);
      w = _playbackWidth;
      advanced = _playbackPosition - startPos;
      final videoFrameReady = _decodedVideoFrame ?? w > 0;
      // 只看 width 不够：libmpv 对某些 HEVC 10bit / DV 片源能报出视频尺寸，
      // 但画面帧出不来（用户看到的就是「有声音、画面停住」）。
      // 也不能只看「位置往前走了」：外网喂不饱 4K 原片时，8 秒能走 2.5 秒，
      // 旧判据把它当「直连正常」，用户那边就是「播几秒停十几秒」。
      // 所以要求位置**跟得上时间轴**（≥55% 实时速度）才算真的能播。
      final keptUp = advanced.inMilliseconds >= elapsed.inMilliseconds * 0.55;
      if (videoFrameReady && keptUp && advanced > const Duration(seconds: 2)) {
        ClientLogger.instance.info(
          '直连正常 width=$w advanced=${advanced.inMilliseconds}ms 用时${i + 1}s',
          route: 'player.directGuard',
        );
        // 这次能直连：把历史失败记录清掉（换了网络 / 换了片源特征都可能变好）
        if (_directBlocked) unawaited(_markDirectBlocked(false));
        return;
      }
      final ahead = kIsWeb ? Duration.zero : _playbackBuffer;
      final issue = classifyDirectPlaybackIssue(
        width: w,
        videoFrameReady: videoFrameReady,
        buffered: ahead,
        advanced: advanced,
        sample: i,
        isWeb: kIsWeb,
      );
      if (issue != null) {
        reason = switch (issue) {
          DirectPlaybackIssue.noVideoFrame =>
            '首帧未出现 buffered=${ahead.inMilliseconds}ms',
          DirectPlaybackIssue.decodeStalled =>
            '解码跟不上 buffered=${ahead.inMilliseconds}ms',
          DirectPlaybackIssue.noData => '链路没数据',
        };
        break;
      }
    }
    if (!mounted ||
        openGeneration != _openGen ||
        _isTranscode ||
        _error != null ||
        !_tvMedia3Player.isActiveInstance) {
      return;
    }
    w = _playbackWidth;
    advanced = _playbackPosition - startPos;
    final videoFrameReady = _decodedVideoFrame ?? w > 0;
    if (videoFrameReady &&
        advanced > const Duration(seconds: 2) &&
        advanced.inMilliseconds >= elapsed.inMilliseconds * 0.55) {
      return;
    }
    if (reason.isEmpty) {
      // 有数据、也在走，但走得太慢：外网 / 无线喂不饱片源码率。
      // 这种情况不记进「这台机器解不动」（换网络就好了），但必须切转码档。
      reason = advanced > const Duration(seconds: 2)
          ? '链路跟不上 ${advanced.inMilliseconds}ms/${elapsed.inMilliseconds}ms'
          : '超时';
    }
    ClientLogger.instance.info(
      '直连检测 width=$w advanced=${advanced.inMilliseconds}ms '
      'buffered=${(kIsWeb ? Duration.zero : _playbackBuffer).inMilliseconds}ms '
      'playing=$_playbackPlaying buffering=$_playbackBuffering '
      '$reason',
      route: 'player.directGuard',
    );
    if (_originalFallbackAttempted) {
      if (mounted) {
        setState(() => _error = tr('player.originalAlsoUnsupported'));
      }
      return;
    }
    final confirmedDecodeFailure =
        reason.startsWith('解码跟不上') || reason.startsWith('首帧未出现');
    // 手机 / 桌面（以及「链路跟不上」这种非解码原因）：不降分辨率。
    // 用户选了原片就说明他就在局域网里，要的是画面原样 —— 这里只把
    // 「容器 / 音频不兼容」交给原片封装会话（视频 copy、音频 AAC），
    // 画质一个字都不动，也不需要 GPU 编码。以前这里直接摆错误页，
    // 用户只能对着「原片播放失败」自己找画质菜单。
    if ((!_tvMode || !confirmedDecodeFailure) &&
        widget.itemId != null &&
        !_originalFallbackAttempted) {
      _originalFallbackAttempted = true;
      try {
        ClientLogger.instance.info(
          '直连失败（$reason），改走原片封装（视频 copy + 音频 AAC）',
          route: 'player.directGuard',
        );
        // 首片要现切，别让用户对着黑屏猜：把转圈的「准备中」摆出来。
        if (mounted) setState(() => _preparing = true);
        final u = await _ensureTranscode('original', defaultTranscodeCodec());
        if (!mounted) return;
        setState(() {
          _error = null;
          _isTranscode = true;
          _preset = 'original';
          _codec = 'original';
          // 原片封装会话里已经带上了 AAC 音轨：之前为了「音频分离」挂的外挂流
          // 必须丢掉，否则 formatHint 会按原容器（mkv/mp4）声明，Media3 把这段
          // m3u8 当普通文件解析，直接报 PARSING_CONTAINER_UNSUPPORTED
          _mergedAudioUrl = null;
        });
        await _openUrl(u, retries: 5);
        if (mounted) setState(() => _preparing = false);
        return;
      } catch (e) {
        if (mounted) setState(() => _preparing = false);
        ClientLogger.instance.warn('原片封装也起不来：$e', route: 'player.directGuard');
      }
    }
    if (!_tvMode || !confirmedDecodeFailure) {
      if (mounted) {
        setState(() => _error = tr('player.originalPlaybackFailed'));
      }
      return;
    }
    // 兜底档：桌面端保分辨率（4K 直连失败不该跳成 1080P），手机 / Web / TV
    // 退到用户偏好档 —— 手机上 4K 7M 在移动网络里就是「一直缓冲 + 软解跟不上」。
    final fallbackCodec = _codec == 'original'
        ? defaultTranscodeCodec()
        : _codec;
    final fallback = _transcodeFallback(codec: fallbackCodec);
    // 只有「数据在手、无视频帧 / 解码不动」才记成设备解码失败，下次免试；
    // 网慢导致的卡顿不记（换个网络它就能直连）。
    //
    // 原生 Media3 不记：杜比视界的解码器初始化本来就慢（4K DV 实测 1s 起），
    // 用这套「7 秒没画面就判死」的启发式去否定系统解码器，代价是整个
    // `hevc@1608` 特征以后永远转码。Media3 自己有明确错误回调（见
    // [_handleTvMedia3Error]），只在它真报错时才降档。
    if (confirmedDecodeFailure && !_shouldUseNativeTvPlayer) {
      unawaited(_markDirectBlocked(true));
    }
    // persist: false —— 这是自动兜底，不能写进用户偏好。存下来的结果就是
    // 「下次一进播放页直接从 4K 7M 起步」，用户再也调不回来。
    // notify: false —— 提示由本方法统一发一条「原画直连没有画面，已切到 X」，
    // 否则 3~8 秒内会连弹两条（「原画直连切编码」+「直连没有画面」）。
    await _switchQuality(
      fallback,
      codec: fallbackCodec,
      persist: false,
      notify: false,
    );
    if (!mounted) return;
    _showNotice(
      tr('player.directFailed', {
        'actual':
            playQualityPresetOf(fallback)?.labelFor(fallbackCodec) ?? fallback,
      }),
      log:
          '直连无画面：width=$w advanced=${advanced.inMilliseconds}ms '
          '${reason.isEmpty ? '' : '($reason) '}→ $fallback',
    );
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
    bool audioOnly = false,
  }) async {
    final id = widget.itemId!;
    if (codec == 'original' || !codecPlayable(codec)) {
      throw StateError('播放设备不支持转码输出编码：$codec');
    }
    final outCodec = codec;
    final sw = Stopwatch()..start();
    final created = await ApiSession.instance.client.playerSessionCreate(
      body: PlayerSessionCreateBody(
        id: id,
        preset: preset,
        codec: outCodec,
        audioIndex: _audioIndex,
        // toneMap 是客户端显式策略；服务端只对 HDR/DV/HLG 片源执行映射。
        //
        // 杜比视界是个例外：只要走到转码，就说明这条链路显示不了 DV
        // （手机 libmpv 不解析 RPU，纹理通道又丢元数据），那转出来必须真的
        // 映射成 SDR —— 否则等于白转一遍，颜色还是错的。
        //
        // `audioOnly` 例外：这条会话只取音频（视频仍播原片直链），
        // 让服务端去 tonemap 等于白白重压一遍 4K DV，一点用都没有。
        toneMap: audioOnly
            ? false
            : (PlayPreferences.toneMap || _srcHdr == HdrLevel.dolbyVision),
        audioNormalize: PlayPreferences.audioNormalizeOverride,
        audioDownmix: PlayPreferences.audioDownmix ? true : null,
        // 服务端一律按段转（默认 3 分钟），播放位置靠近末尾才续下一段。
        // 0 / 负数会被服务端归到默认值，客户端不再有「整片一次转完」这条路径。
        leadMinutes: PlayPreferences.leadMinutes,
        // 0 = 从片头转。服务端会按片源时长夹取，越界不会建出空会话。
        startMs: startMs > 0 ? startMs : null,
      ),
    );
    final u = created.url.startsWith('http')
        ? created.url
        : '${ApiSession.instance.baseUrl}${created.url}';
    // 记下会话：媒体信息面板要拿它查「转码中 / 完成」和实际编码
    _sessionId = created.id;
    _sessionAudioNormalizeEffective = null;
    ClientLogger.instance.info(
      '会话已创建 ${sw.elapsedMilliseconds}ms preset=$preset codec=$outCodec',
      route: 'player.session/${created.id}',
      detail: _redactedUrlForLog(u),
    );
    _jobStatus = null;
    _transcodedMs = 0;
    // 记下这一轮的提前量：决定 `_loadedEnd` 能不能信 libmpv 报的 duration。
    // 建会话的响应里没有 leadMs，先用客户端请求值推算，下一次轮询会用
    // 服务端回显的 leadMs 校正（见 _watchSession）。
    _leadMs = PlayPreferences.leadMinutes * 60000;
    // 起转偏移以服务端回显为准（它可能夹取过），播放器时间轴 0 = 这个位置
    _startMs = created.startedMs ?? startMs;
    // 新流还没 open：从这一刻到 `_openUrl` 的 `player.open` 返回之前，播放器
    // 位置属于**上一条流**，不能再加 `_startMs`（会翻倍）。见 [_absPosition]。
    _pendingStartMs = _startOffset;
    // 实际编码换会话后必须清空，否则换了档还显示上一轮的结果
    _actualCodec = null;
    _actualToneMap = null;
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
    // 与服务端首片看门狗对齐：硬件编码失败后会尝试软件链路，HDR 片源可能需要更久。
    // 不要在首片尚未生成时把空播放列表交给播放器，否则后续分片超时会使整条流失效。
    const budgetMs = 90000;
    var polls = 0;
    var last = '';
    void log(String why) {
      ClientLogger.instance.info(
        '首片等待 $why ${sw.elapsedMilliseconds}ms polls=$polls $last',
        route: 'player.waitFirstSegment/$id',
      );
    }

    while (sw.elapsedMilliseconds < budgetMs) {
      if (!mounted) return;
      try {
        final job = await ApiSession.instance.client.playerSessionGet(
          id: id,
          pos: 0,
        );
        if (mounted &&
            _sessionId == id &&
            _sessionAudioNormalizeEffective != job.audioNormalizeEffective) {
          setState(() {
            _sessionAudioNormalizeEffective = job.audioNormalizeEffective;
          });
        }
        polls += 1;
        // transcodedMs 是**片源绝对位置** = startedMs + 已转出时长。
        // 跳转会话的 startedMs 本身就有几十万毫秒，直接判断 > 0 会立刻放行，
        // 等于没等首片 —— 必须减掉起点。
        final started = job.startedMs ?? 0;
        final done = (job.transcodedMs ?? 0) - started;
        final st = '${job.status}';
        last =
            'status=$st transcoded=${job.transcodedMs} started=$started done=$done segments=${job.segments}';
        if (done > 0) {
          log('ready');
          return;
        }
        if (st == 'failed' || st == 'canceled' || st == 'done') {
          log('terminal');
          throw StateError(
            'session $id $st${job.error == null ? '' : ': ${job.error}'}',
          );
        }
      } catch (e) {
        if (e is StateError) rethrow;
        last = 'err=$e';
      }
      // 2s 分片下首片来得快，500ms 轮询会平白多等半拍
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    log('timeout');
    throw TimeoutException(
      'first segment timeout (session=$id, ${budgetMs}ms)',
      const Duration(milliseconds: budgetMs),
    );
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
        final pos = _absPosition(_playbackPosition).inMilliseconds;
        final job = await ApiSession.instance.client.playerSessionGet(
          id: id,
          pos: pos > 0 ? pos.toDouble() : 0,
        );
        if (!mounted || _sessionId != id) return;
        final st = '${job.status}';
        final codec = job.codec ?? '';
        final transcoded = job.transcodedMs ?? 0;
        final normalizeChanged =
            _sessionAudioNormalizeEffective != job.audioNormalizeEffective;
        // 会话可能是详情页传进来的（没走过 _ensureTranscode），lead 在这里补齐，
        // 否则 _loadedEnd 会退回「信 player.duration」那条错路
        _leadMs = job.leadMs ?? _leadMs;
        // 分段会话会一直 paused 着轮询，值没变就别每 3 秒重排整页
        if (_jobStatus != st ||
            _transcodedMs != transcoded ||
            (codec.isNotEmpty && _actualCodec != codec) ||
            _actualToneMap != job.hdrToSdr ||
            normalizeChanged) {
          setState(() {
            _jobStatus = st;
            _transcodedMs = transcoded;
            if (codec.isNotEmpty) _actualCodec = codec;
            _actualToneMap = job.hdrToSdr;
            _sessionAudioNormalizeEffective = job.audioNormalizeEffective;
          });
        }
        // 服务端不能按请求编码输出时，按策略改试原片，而不是把内部 H.264 降级
        // 包装成成功播放。
        if (_preset != 'original' &&
            codec.isNotEmpty &&
            codec != _codec &&
            !_codecNoticeShown) {
          _codecNoticeShown = true;
          if (_codec == 'h265' || _codec == 'av1') {
            final requested = playCodecOf(_codec)?.label ?? _codec;
            _showNotice(
              _originalFallbackBlockedByColor
                  ? tr('player.codecFallbackBlocked')
                  : tr('player.codecFallbackOriginal', {'want': requested}),
              log: '服务端编码不匹配：请求 $_codec，实际 $codec（session=$id）',
            );
            await _fallbackToOriginal(_codec);
            return;
          } else {
            _showNotice(
              tr('player.codecFallback', {
                'want': playCodecOf(_codec)?.label ?? _codec,
                'actual': playCodecOf(codec)?.label ?? codec,
              }),
              log: '服务端编码降级：请求 $_codec，实际 $codec（session=$id）',
            );
          }
        }
        if (st == 'done' || st == 'canceled') return;
        if (st == 'failed') {
          if ((_codec == 'h265' || _codec == 'av1') &&
              !_originalFallbackAttempted) {
            _codecNoticeShown = true;
            _showNotice(
              _originalFallbackBlockedByColor
                  ? tr('player.codecFallbackBlocked')
                  : tr('player.codecFallbackOriginal', {
                      'want': playCodecOf(_codec)?.label ?? _codec,
                    }),
              log:
                  '转码会话失败，尝试原码直连：${job.error ?? 'transcode failed'} '
                  '(session=$id)',
            );
            await _fallbackToOriginal(_codec);
            return;
          }
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

  // ------------------------------------------------------------ 渲染 / 色调映射

  /// 写 libmpv 属性。Web 没有 NativePlayer、桌面构建也不一定认某个属性，
  /// 一律「设了就算」，不能因为一个可选滤镜把播放卡死。
  void _setMpvProp(String key, String value) {
    if (kIsWeb) return;
    try {
      // ignore: avoid_dynamic_calls
      (_player.platform as dynamic).setProperty(key, value);
    } catch (_) {
      // 不支持就算了
    }
  }

  /// 响度归一用的音频滤镜链。
  ///
  /// libmpv 的 `af` 直接吃 ffmpeg 滤镜名（`dynaudnorm=f=250:g=15`）。
  /// `lavfi=[...]` 是 ffmpeg **命令行**的写法 —— 安卓的 libmpv 构建会报
  /// `Audio filter initialized failed!`，整片直接进失败页（真机日志佐证：
  /// `preset=original session=null`，直连一开播就死在音频滤镜初始化上）。
  static const String _normalizeFilter = 'dynaudnorm=f=250:g=15';

  /// 这台设备的 libmpv 有没有 lavfi 音频滤镜。
  ///
  /// 安卓的 libmpv 构建不带 lavfi：挂 `af=dynaudnorm...` 会直接报
  /// 「Option af: dynaudnorm doesn't exist.」，开播瞬间闪一屏错误（2026-11-22
  /// 真机日志）。响度归一只在桌面 / iOS 生效；安卓端跳过，降混不受影响。
  static bool get _lavfiAudioFilters =>
      !kIsWeb && defaultTargetPlatform != TargetPlatform.android;

  /// 直连时音频处理在播放器本地做（libmpv 自带滤镜链）；
  /// 转码流的音频已由服务端处理好，必须清掉滤镜，避免双重处理。
  void _applyDirectAudio() {
    if (kIsWeb) return;
    // 转码会话的音频已经是「最终形态」：再套一层 dynaudnorm 就是压两次，
    // 音量起伏被抹平得过头，用户听到的是「一直在喘气」。
    final local = !_isTranscode;
    final normalize =
        local &&
        _lavfiAudioFilters &&
        !_audioFilterDowngraded &&
        PlayPreferences.audioNormalizeEnabled(
          widget.compat?['audioNormalize'] == true,
        );
    _setMpvProp('af', normalize ? _normalizeFilter : '');
    _setMpvProp(
      'audio-channels',
      local && !_audioFilterDowngraded && PlayPreferences.audioDownmix
          ? 'stereo'
          : 'auto',
    );
  }

  /// 音频滤镜起不来，不该让整片播不了。
  ///
  /// 清掉 `af`、声道恢复自动，再原地（带播放位置）重开一次；这一轮的
  /// [`_applyDirectAudio`] 会看到降级标志直接不挂滤镜。
  /// 只降级一次：关掉滤镜仍然失败，说明是别的原因，交给正常失败页。
  void _downgradeAudioFilter(String message) {
    if (_audioFilterDowngraded) {
      setState(() => _error = message);
      return;
    }
    _audioFilterDowngraded = true;
    _setMpvProp('af', '');
    _setMpvProp('audio-channels', 'auto');
    ClientLogger.instance.warn(
      '音频滤镜不可用（${message.trim()}）→ 关掉响度归一 / 降混重开',
      route: 'player.audio/${_sessionId ?? 'direct'}',
    );
    final target = _url;
    if (target.isEmpty) {
      setState(() => _error = message);
      return;
    }
    final pos = _playbackPosition;
    unawaited(_openUrl(target, seekTo: pos > Duration.zero ? pos : null));
  }

  /// libavfilter 初始化失败（安卓 libmpv 缺滤镜 / 语法不认）。
  static bool _isAudioFilterError(String message) {
    final m = message.toLowerCase();
    return m.contains('audio filter') ||
        // 「Option af: dynaudnorm doesn't exist.」这类缺滤镜的报错
        m.contains('option af') ||
        (m.contains('filter') && m.contains('initializ'));
  }

  bool get _audioProcessingRequested =>
      PlayPreferences.audioNormalizeEnabled(
        widget.compat?['audioNormalize'] == true,
      ) ||
      PlayPreferences.audioDownmix;

  /// 直连时的 demuxer 缓存。转码流不动：分片本身只有几百 KB，
  /// 原来的默认值就够，贸然改反而影响 seek 行为。
  void _applyDirectCache() {
    if (kIsWeb || _isTranscode) return;
    _setMpvProp('cache', 'yes');
    _setMpvProp('cache-secs', '60');
    _setMpvProp('demuxer-max-bytes', '256MiB');
    _setMpvProp('demuxer-max-back-bytes', '64MiB');
    // 高码率片源的起播不能等太久：一帧 4K HEVC 就有几百 KB，
    // 默认的「攒够一批再播」在小水管上是灾难，局域网里则纯属拖延。
    _setMpvProp('cache-pause-initial', 'no');
  }

  /// 音频处理是不是只能由服务端 HLS 会话完成。
  ///
  /// 只有浏览器没有本地滤镜链，响度归一 / 降混只能进转码会话（视频 copy +
  /// 音频 AAC）。libmpv 端（安卓手机 / 安卓 TV / 桌面）自己就能套
  /// `af=dynaudnorm` 与 `audio-channels`，用户既然选了「原片」，就不该因为
  /// 一个音频开关把整部片拖去转封装 —— 那正是「手机上选原片却播不了」的成因：
  /// 会话里视频是 copy、音频转 AAC，落进 original 的 EVENT 列表，
  /// 首片要等、列表还要边播边长。
  bool get _audioProcessingNeedsRemote => _audioProcessingRequested && kIsWeb;

  /// 原生 Media3 上的「混为立体声」只能由服务端做：这条链路没有 lavfi 滤镜，
  /// `audio-channels=stereo` 是 libmpv 的私有属性，Media3 不认。
  bool get _nativeDownmixNeedsRemote =>
      _shouldUseNativeTvPlayer && PlayPreferences.audioDownmix;

  bool get _isVideoCopySession => _isTranscode && _preset == 'original';

  bool get _isCopyAudioSession =>
      _isVideoCopySession &&
      (_audioProcessingRequested || _sessionAudioNormalizeEffective == true);

  bool get _originalFallbackBlockedByColor =>
      (PlayPreferences.toneMap && _srcHdr.isHdr) || _colorBlocksDirect;

  String get _copySessionLabel => tr(
    _isCopyAudioSession
        ? 'player.sourceAudioProcessed'
        : 'player.sourceAudioOriginal',
  );

  /// 探测 libmpv 能力并下发色调映射参数；同时读一次显示端 HDR 能力。
  ///
  /// 失败一律吞掉：拿不到能力就按「未知」处理，不能让播放因为它卡住。
  Future<void> _setupRender() async {
    final caps = await VideoRenderCaps.setup(_player);
    final display = await readDisplayCaps().catchError(
      (_) => DisplayCaps.unknown,
    );
    if (!kIsWeb &&
        defaultTargetPlatform == TargetPlatform.android &&
        _srcHdr == HdrLevel.dolbyVision) {
      final supportsDolbyVision =
          await TvMedia3PlayerController.supportsDolbyVision();
      ClientLogger.instance.info(
        'Media3 Dolby Vision decoder=$supportsDolbyVision',
        route: 'player.render',
      );
    }
    if (!mounted) return;
    ClientLogger.instance.info(
      'render=${caps.renderer} ${caps.summary} displayHdr=${display.maxHdr.reason}',
      route: 'player.render',
    );
    setState(() {
      _caps = caps;
      _display = display;
    });
  }

  /// 片源最高 HDR 等级（dolbyVision > hdr10plus > hdr10 > hlg > none）。
  HdrLevel get _srcHdr => HdrLevel.fromReasons(_reasons);

  /// 电视端是否启用隧道模式。
  ///
  /// 杜比视界必须关隧道：MTK 电视开隧道时 Media3 只会选中
  /// `c2.mtk.hevc.decoder`，拿不到 DV 解码器，输出的是 HDR10 基础层，
  /// 电视端不会切杜比。HDR10 / HDR10+ / HLG 仍走隧道以降低 4K 掉帧。
  bool get _tvTunneled =>
      _tvMode && !_tunnelOffRetried && _srcHdr != HdrLevel.dolbyVision;

  /// 直连能不能保证**颜色是对的**。
  ///
  /// - Android TV：用户允许原片时交给 Media3 / 系统 Surface，由实际解码结果决定
  ///   是否回退；显示能力枚举可能漏报 Dolby Vision。
  /// - 其他 Android 端：显示能力明确低于片源时回落兼容播放。
  /// - 桌面 / Web：libmpv 的 vo=libmpv 没有 libplacebo / DV RPU 解析，
  ///   DV 直连是紫 / 荧光绿，维持旧行为走服务端 HDR→SDR；HDR10/HLG 可直连。
  bool get _colorBlocksDirect {
    if (widget.compat == null) return false;
    final src = _srcHdr;
    if (!src.isHdr) return false;
    final tv = _tvMode || (kIsWeb && AppSettings.instance.tvMode.value);
    // 用户在播放设置里关掉电视原片直连时，按兼容播放链路处理。
    if (tv && !PlayPreferences.tvDirectOriginal) return true;
    // 电视在「HDR + 未开色调映射」时走 Media3 + SurfaceView 直通，
    // DV RPU 由系统解码器处理 —— 这条链路能真输出杜比。
    if (_androidNativeHdrEligible) return false;
    // 剩下的都是 libmpv 链路（手机 / 平板 / 桌面 / Web / 开了色调映射的 Android）：
    // 它不解析 DV RPU，Profile 5 的 IPTPQc2 会被当普通 YUV 解 —— 必紫。
    // 注意别拿 `DisplayCaps` 放行：它读的是 Android `HdrCapabilities`，
    // 说的是「屏幕能显示什么」，不代表这条播放链路能输出。
    if (src == HdrLevel.dolbyVision) return true;
    if (!kIsWeb && _display.trustworthy) return !_display.supports(src);
    if (tv) return false;
    return false;
  }

  /// 「原码」没法直连时退到哪一档。
  ///
  /// 桌面端保片源分辨率；TV 按默认 4K 档回退，手机按默认 1080P 档回退。
  ///
  /// [colorOnly] = 只因颜色原因（HDR / 杜比视界映射）不能直连：这时只换色彩
  /// 空间，**绝不顺手把分辨率也降下来** —— 用户明确否决过「自动降分辨率」，
  /// 4K 杜比视界片被拦成 1080P 是比紫色更糟的体验。
  String _transcodeFallback({String? codec, bool colorOnly = false}) {
    final c = codec ?? _codec;
    if (colorOnly) return fallbackPresetPreservingHeight(_srcHeight, codec: c);
    // 手机 / 平板（安卓、iOS）：网络和解码都比桌面脆。实测 4K 源退到「保分辨率」
    // 的 4K 7M，在移动网络里就是一直缓冲，而且 4K HEVC / AV1 软解根本跟不上
    // —— 用户看到的是「进度条加载完了还在卡、看几秒停一下，等一分钟再几秒」。
    // 所以这里按**用户偏好档**回落（没存过才用默认档），绝不主动抬码率。
    final handheld =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);
    if (kIsWeb || _tvMode || handheld) {
      final pref = PlayPreferences.savedPreset;
      final base = (pref == null || pref == 'original')
          ? PlayPreferences.defaultPresetForPlatform
          : pref;
      return clampPresetForSource(base, _srcHeight, codec: c);
    }
    return fallbackPresetPreservingHeight(_srcHeight, codec: c);
  }

  /// 顶部提示条：全屏下也能看见，6 秒后自动消失。
  ///
  /// 以前「原画 → 1080P」只弹一个 SnackBar：全屏时被系统栏挡住、4 秒就没了，
  /// 用户只看到「画质自己变了」。现在改成播放器内提示，并把原因写进服务端日志。
  void _showNotice(String text, {String? log}) {
    if (log != null) {
      ClientLogger.instance.warn(log, route: 'player.notice');
    }
    _noticeTimer?.cancel();
    if (!mounted) return;
    setState(() => _notice = text);
    _noticeTimer = Timer(const Duration(seconds: 6), () {
      if (mounted) setState(() => _notice = null);
    });
  }

  Future<void> _prepareCompatible() async {
    setState(() => _preparing = true);
    _armTryOriginal();
    // 显示能力探测（TV 走原生通道）要和渲染参数一起就绪，HDR 判定才不是猜的
    await _renderReady;
    if (!mounted) return;
    // 提到 try 外：直通起不来时要在 catch 里知道「刚才走的是不是直通」，
    // 才能自动降一档再试，而不是弹一个错误页了事。
    bool toDirect = false;
    bool copyAudio = false;
    String effective = _preset;
    final wantOriginal = _codec == 'original';
    final transcodeCodec = _codec == 'original'
        ? defaultTranscodeCodec()
        : _codec;
    try {
      // 直连条件：用户选原码 + 本机能保证颜色正确 + 真有直链可用。
      // Web 端仍然受「浏览器解不了 MKV/HEVC」限制（_needTranscode）。
      final toneMapRequested = PlayPreferences.toneMap && _srcHdr.isHdr;
      final colorBlocked = _colorBlocksDirect || toneMapRequested;
      // 上一次同样特征的片源（编码 + 高度）直连就是「有尺寸、画面不走」：
      // 别再黑一遍再说同样的话，直接进转码档。
      //
      // ⛔ 只对 libmpv 链路生效：这条记忆是 libmpv 的「有尺寸没画面」启发式判出来
      // 的，原生 Media3 走的是系统解码器、失败会明确回调，拿旧记录拦它等于
      // 「这片以前直连黑过一次，以后永远转码」—— HDR / 杜比视界片就是这么被
      // 永久锁进转码档的（日志里那句「直连历史失败（hevc@1608）」）。
      final directBlocked = _shouldUseNativeTvPlayer ? false : _directBlocked;
      final canKeepSourceVideo =
          wantOriginal &&
          !colorBlocked &&
          !directBlocked &&
          widget.compat != null &&
          (!kIsWeb || !_needTranscode);
      copyAudio = canKeepSourceVideo && _audioProcessingNeedsRemote;
      toDirect = canKeepSourceVideo && !copyAudio;
      // 原生 Media3 没有本地滤镜链（libmpv 的 `audio-channels=stereo` 在这里无效）：
      // 勾了「混为立体声」就让服务端只把音频轨降混成 AAC 立体声，视频继续走原片
      // 直链 —— 既保住杜比视界 / HDR 的原片直出，又真的把 5.1 压成两声道。
      //
      // 每次重新决策都先清掉外挂音频：不降混的这次不该沿用上一次的降混流。
      _mergedAudioUrl = null;
      if (canKeepSourceVideo && _nativeDownmixNeedsRemote && !copyAudio) {
        try {
          _mergedAudioUrl = await _ensureTranscode(
            'original',
            transcodeCodec,
            audioOnly: true,
          );
          if (!mounted) return;
        } catch (e) {
          _mergedAudioUrl = null;
          ClientLogger.instance.warn('降混音频会话创建失败：$e', route: 'player.audio');
        }
      }
      // 档位按片源高度收敛：偏好 1080P 但片源只有 720P 时，按 720P 转，
      // 不做放大转码（放大只会更大更糊，还多占 GPU）。菜单同样只列 ≤720P 的档。
      // 「原码但必须转码」时退到「保分辨率」的兜底档。
      effective = toDirect || copyAudio
          ? 'original'
          : (wantOriginal
                ? _transcodeFallback(
                    codec: transcodeCodec,
                    colorOnly: colorBlocked,
                  )
                : clampPresetForSource(
                    _preset,
                    _srcHeight,
                    codec: transcodeCodec,
                  ));
      if (kIsWeb &&
          wantOriginal &&
          !toDirect &&
          !copyAudio &&
          !colorBlocked &&
          !directBlocked) {
        // 浏览器解不了源编码时明确说明实际转码输出。
        _showNotice(
          tr('player.webTranscode', {
            'actual':
                playQualityPresetOf(effective)?.labelFor(transcodeCodec) ??
                effective,
          }),
          log: 'Web 不支持源编码：原画 → $effective',
        );
      }
      if (toneMapRequested && wantOriginal) {
        _showNotice(
          tr('player.toneMapRequiresTranscode'),
          log: '原码选择与色调映射冲突：转码 HDR 片源 $effective',
        );
      } else if (colorBlocked && wantOriginal) {
        _showNotice(
          tr('player.colorFallback', {
            'source': tr('player.reason.${_srcHdr.reason}'),
            'actual':
                playQualityPresetOf(effective)?.labelFor(transcodeCodec) ??
                effective,
          }),
          log:
              '色调映射回退：src=${_srcHdr.reason} direct=false preset=$effective '
              'render=${_caps.renderer} ${_caps.summary}',
        );
      }
      if (directBlocked && wantOriginal) {
        // 上次同样特征直连就黑过：跳过探测并说明为什么没有原码直连。
        _showNotice(
          tr('player.directFailed', {
            'actual':
                playQualityPresetOf(effective)?.labelFor(transcodeCodec) ??
                effective,
          }),
          log: '直连历史失败（$_directKey），直接进转码档 $effective',
        );
      }
      final u = toDirect
          ? _directUrl
          : await _ensureTranscode(effective, transcodeCodec);
      if (!mounted) return;
      setState(() {
        _preparing = false;
        _isTranscode = !toDirect;
        _preset = effective;
        _codec = toDirect || copyAudio ? 'original' : transcodeCodec;
      });
      _disarmTryOriginal();
      // retries: 首片还没落盘时内核会「打不开」，不是转码失败，给五次重试
      await _openUrl(u, retries: toDirect ? 0 : 5);
    } catch (e) {
      if (!mounted) return;
      if (!toDirect &&
          !copyAudio &&
          (transcodeCodec == 'h265' || transcodeCodec == 'av1') &&
          !_originalFallbackAttempted) {
        _showNotice(
          tr('player.codecFallbackOriginal', {
            'want': playCodecOf(transcodeCodec)?.label ?? transcodeCodec,
          }),
          log: '转码会话创建失败，尝试原码直连：${e.runtimeType}',
        );
        await _fallbackToOriginal(transcodeCodec);
        _disarmTryOriginal();
        return;
      }
      // 直通会话起不来（电视浏览器不支持源编码 / fMP4 解不出）：再降一档重编码
      // 起播，别让用户对着「切换失败」自己找画质菜单。
      if (!toDirect && effective == 'original' && _tvMode) {
        final fallback = clampPresetForSource(
          PlayPreferences.defaultPresetForPlatform,
          _srcHeight,
          codec: transcodeCodec,
        );
        try {
          final u = await _ensureTranscode(fallback, transcodeCodec);
          if (!mounted) return;
          setState(() {
            _preparing = false;
            _isTranscode = true;
            _preset = fallback;
            _codec = transcodeCodec;
          });
          _disarmTryOriginal();
          await _openUrl(u, retries: 5);
          return;
        } catch (_) {
          // 降档也失败：继续走下面的错误页，错误信息用最初那次
        }
      }
      // 不能退回直链：走到这里就说明片源直链本来解不了（HEVC / MKV / HDR），
      // 退回直链只会再报一次 DEMUXER_ERROR，把真正的失败原因盖掉。
      setState(() {
        _preparing = false;
        _error = tr('player.switchFailed', {'error': '$e'});
      });
      _disarmTryOriginal();
    }
  }

  /// 准备页的计时：一秒一拍地数，用户能看到它在动；
  /// 到 [_tryOriginalDelay] 还没起来才把「试试原画」放出来。
  ///
  /// 为什么要有秒数：「正在转码，准备起播…」配一个一直在转的圈，用户分不清是
  /// 在干活还是卡死了（Web 端实测首片 1.3~6.6 秒，转码任务排队时会到 30 秒）。
  void _armTryOriginal() {
    _tryOriginalTimer?.cancel();
    _canTryOriginal = false;
    _prepareSeconds = 0;
    _tryOriginalTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted || !_preparing) {
        t.cancel();
        return;
      }
      setState(() => _prepareSeconds += 1);
      if (_prepareSeconds >= _tryOriginalDelay.inSeconds) {
        t.cancel();
        setState(() => _canTryOriginal = true);
      }
    });
  }

  void _disarmTryOriginal() {
    _tryOriginalTimer?.cancel();
    _tryOriginalTimer = null;
    if (_canTryOriginal) setState(() => _canTryOriginal = false);
    if (_prepareSeconds != 0) setState(() => _prepareSeconds = 0);
  }

  Future<void> _switchQuality(
    String preset, {
    String? codec,
    bool persist = true,
    // 自动兜底（原画直连失败）时传 false：提示由调用方发一条更准确的，
    // 免得用户在半分钟内连着看到两条说法不同的提示。
    bool notify = true,
  }) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    // 本机解不出来的输出编码按策略回到原码，不再替用户静默选择 H.264。
    final wantedCodec = codec ?? _codec;
    final targetCodec = codec == null && wantedCodec == 'original'
        ? defaultTranscodeCodec()
        : (codecPlayable(wantedCodec) ? wantedCodec : 'original');
    final prevPreset = _preset;
    final prevCodec = _codec;
    final previousError = _error;
    // 换档 = 换会话：上一次「视频原片 + 音频分离」的组合不能带过来
    _mergedAudioUrl = null;

    final fromDirect = !_isTranscode;
    // 颜色原因（HDR / 杜比视界在这条链路上不能直连）会强制转码：
    // 先算出来，档位选择与提示文案都要用。
    final toneMapRequested = PlayPreferences.toneMap && _srcHdr.isHdr;
    final colorBlocked = _colorBlocksDirect || toneMapRequested;
    final wanted = targetCodec == 'original'
        ? 'original'
        : (preset == 'original' || (fromDirect && codec != null)
              ? _transcodeFallback(codec: targetCodec, colorOnly: colorBlocked)
              : preset);

    // 直链要求：调用方给的是真直链（compat 存在）且片源本身能直链。
    // 详情页「转码」入口拿的是 HLS 地址（compat=null），那里不存在直链可退。
    // 手机 / 桌面（libmpv）能解 HEVC / AV1 / 10bit，但**杜比视界不行**：
    // 它没有 libplacebo / DV RPU 解析，直连出来是紫的。
    // 所以「原画」是否直连要看 _colorBlocksDirect，而不是只看平台。
    // Web 端保持原判定（Chromium 确实解不了 MKV/HEVC）。
    final canKeepSourceVideo =
        targetCodec == 'original' &&
        !colorBlocked &&
        !_directBlocked &&
        widget.compat != null &&
        (!kIsWeb || !_needTranscode);
    final copyAudio = canKeepSourceVideo && _audioProcessingNeedsRemote;
    final toDirect = canKeepSourceVideo && !copyAudio;
    if (!toDirect && widget.itemId == null) return;
    // 必须转码时「原画」没法真原样播：桌面退到保分辨率的档，
    // 界面也跟着显示实际档位，不要出现「显示原画、跑的是 1080p」。
    final effectiveCodec = targetCodec == 'original' && !toDirect && !copyAudio
        ? defaultTranscodeCodec()
        : targetCodec;
    final effective = copyAudio
        ? 'original'
        : wanted == 'original' && !toDirect
        ? _transcodeFallback(codec: effectiveCodec)
        : wanted;
    if (kIsWeb &&
        wanted == 'original' &&
        !toDirect &&
        !copyAudio &&
        !colorBlocked) {
      _showNotice(
        tr('player.webTranscode', {
          'actual':
              playQualityPresetOf(effective)?.labelFor(effectiveCodec) ??
              effective,
        }),
        log: 'Web 不支持源编码：原画 → $effective',
      );
    }
    if (wanted == 'original' && toneMapRequested) {
      _showNotice(
        tr('player.toneMapRequiresTranscode'),
        log: '原码选择与色调映射冲突：转码 HDR 片源 $effective',
      );
    } else if (wanted == 'original' && colorBlocked) {
      _showNotice(
        tr('player.colorFallback', {
          'source': tr('player.reason.${_srcHdr.reason}'),
          'actual':
              playQualityPresetOf(effective)?.labelFor(effectiveCodec) ??
              effective,
        }),
        log: '切清晰度触发色调映射回退：src=${_srcHdr.reason} preset=$effective',
      );
    }
    final pos = _absPosition(_playbackPosition);
    // 换档前记下「当时是不是在播」：暂停中挑画质的人，换完还应该停在暂停，
    // 别因为 open 默认 play=true 自己响起来；在播的人则必须无缝续上。
    final wasPlaying = _playbackPlaying || _playbackBuffering;
    // 先把档位/编码写进界面，再去等服务端首片：新会话要 8~12s 才出片，
    // 码率列表不能等它 —— 以前 `_codec` 要等 open 成功才更新，切完打开菜单
    // 还是旧的 1080P 8M（H.264 码率），看起来像「切了没生效」。
    setState(() {
      _switching = true;
      _preset = effective;
      _codec = toDirect || copyAudio ? 'original' : effectiveCodec;
      _error = null;
    });
    if (fromDirect && codec != null && targetCodec != 'original' && notify) {
      _showNotice(
        tr('player.codecToTranscode', {
          'preset':
              playQualityPresetOf(effective)?.labelFor(effectiveCodec) ??
              effective,
          'codec': playCodecOf(effectiveCodec)?.label ?? effectiveCodec,
        }),
        log: '原码直连切编码：$effectiveCodec → $effective',
      );
    }
    // 新一次换档允许再提示一次编码回落
    _codecNoticeShown = false;
    _originalFallbackAttempted = false;
    try {
      // 服务端建新会话时，旧会话会延后到新会话首片就绪再取消
      // （见 videoPlayer supersedeOlder），切换期间旧画面还能继续放。
      final u = toDirect
          ? _directUrl
          : await _ensureTranscode(
              effective,
              copyAudio ? defaultTranscodeCodec() : effectiveCodec,
              // 换档从当前位置接着播：新会话直接从这儿起转，不用再 seek
              startMs: pos.inMilliseconds,
            );
      // 回直链：时间轴是片源时间轴，起转偏移必须清零，否则位置会凭空多一截
      if (toDirect) _startMs = 0;
      // `_isTranscode` 必须在 open **之前**落位：`_openUrl` 按它决定要不要挂
      // 「直连保底」（`_guardDirectPlayback`）。以前等 open 返回才置位，于是
      // 转码流也白挂了一个直连守卫 —— 它 8 秒后再判一次「没画面」，又切一次档，
      // 用户看到的就是「换档之后画面开始反复闪」。
      if (mounted) setState(() => _isTranscode = !toDirect);
      // 换档也是新建会话，同样可能撞上「首片还没落盘」，给三次重试
      // （服务端已经会等到 25s，这里再兜几次是给 SMB 片源 + 4K 的余量）。
      // 转码会话的时间轴 0 = pos（见 _ensureTranscode 的 startMs），不能再 seekTo。
      await _openUrl(
        u,
        seekTo: toDirect ? pos : null,
        retries: toDirect ? 0 : 3,
        autoPlay: wasPlaying,
      );
      if (!mounted) return;
      setState(() {
        _preset = effective;
        _codec = toDirect || copyAudio ? 'original' : effectiveCodec;
        _isTranscode = !toDirect;
      });
      // 只有用户自己点的档位才写进偏好。自动降级（原画黑屏兜底、编码回落）
      // 也存下来的话，下一次进播放页会直接从 4K 7M 起步 —— 手机上就是
      // 「明明设了 1080P 0.9M，一播又变 4K 7M」。
      if (persist) {
        await PlayPreferences.save(
          preset: preset == 'original' ? effective : preset,
          codec: toDirect || copyAudio ? 'original' : effectiveCodec,
        );
      }
    } catch (e) {
      if (!toDirect &&
          !copyAudio &&
          (effectiveCodec == 'h265' || effectiveCodec == 'av1') &&
          !_originalFallbackAttempted) {
        _showNotice(
          tr('player.codecFallbackOriginal', {
            'want': playCodecOf(effectiveCodec)?.label ?? effectiveCodec,
          }),
          log: '目标编码转码失败，尝试原码直连：${e.runtimeType}',
        );
        await _fallbackToOriginal(effectiveCodec, position: pos);
        return;
      }
      // 切换失败：把界面回滚到切换前的档位/编码，别让菜单显示一个没跑起来的档
      if (mounted) {
        setState(() {
          _preset = prevPreset;
          _codec = prevCodec;
          _error = previousError;
        });
      }
      if (messenger != null) {
        NasSnack.showOn(messenger, tr('player.switchFailed', {'error': '$e'}));
      }
    } finally {
      if (mounted) setState(() => _switching = false);
      // 换档也是在播状态下的换源：open 期间那次 play() 被打断，这里补回来。
      // 原本就是暂停的（wasPlaying=false）不动，尊重用户的选择。
      if (wasPlaying && mounted) unawaited(_resumeIfIdle('换档完成'));
    }
  }

  /// 令牌过期（暂停久了 / 长时间投屏）静默重签 + 从原位置续播。
  /// HLS 分片自带会话令牌，不走这条。
  Future<void> _renewIfTokenExpired(String message) async {
    final id = widget.itemId;
    if (id == null || id.isEmpty || _isTranscode) return;
    if (_renewing || _renewTries >= 3) return;
    if (!RegExp(
      r'40[13]|unauthor|forbidden|expired|token',
      caseSensitive: false,
    ).hasMatch(message)) {
      return;
    }
    _renewing = true;
    _renewTries += 1;
    final pos = _playbackPosition;
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
      final pick = pickSubtitle(
        res.items,
        VideoSubtitlePrefs.instance.preferred,
      );
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

  Future<void> _chooseSubtitle(
    String preferred,
    VideoSubtitleFile? file,
  ) async {
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
    if (lang != null && lang.isNotEmpty && lang.toLowerCase() != 'und') {
      return lang;
    }
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
  /// 「字幕搜索」就是干这个的。Cue 在 `_applySubtitle` 里已经
  /// 解析进内存（自绘字幕要用），这里只是过滤 + seek，不额外请求服务端。
  Future<void> _showSubtitleSearch() async {
    if (_cues.isEmpty) {
      NasSnack.show(
        context,
        tr(
          _activeSub == null
              ? 'player.subtitleSearchNoSub'
              : 'player.subtitleSearchEmpty',
        ),
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
                          prefixIcon: const Icon(
                            Icons.search,
                            color: Colors.white54,
                            size: 20,
                          ),
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
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 14,
                                  ),
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
                                    _seekTo(
                                      Duration(milliseconds: cue.startMs),
                                    ),
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
    // TV 用 6 秒：遥控器挪到想要的按钮要花时间，4 秒经常「刚按到就没了」。
    final seconds = _tvMode ? 6 : 4;
    _hideTimer = Timer(Duration(seconds: seconds), () {
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
    await _playbackSetRate(v);
    await _saveUiPrefs();
    if (mounted) setState(() {});
  }

  Future<void> _setVolume(double v) async {
    _volume = v;
    _volumeVN.value = v;
    await _playbackSetVolume(v);
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
    final w = _playbackWidth;
    final h = _playbackHeight;
    if (next) {
      await enterPlayerFullscreen(videoWidth: w, videoHeight: h);
    } else {
      await exitPlayerFullscreen(portrait: _wantPortraitOnExit);
    }
  }

  /// 快进 / 快退（键盘 →、← 与遥控器那套）。
  ///
  /// 两个坑都在这里，2026-11-17 实测（会话 `505793bd` / `b74d94b1`）：
  ///
  /// 1. **连按必须合并**。一秒里连发 6 次 `player.seek()` 会把 mpv 的 seek 队列
  ///    彻底打乱，最后**一次都没落地**，画面僵在那儿 —— 日志里 12:01:19~21
  ///    连着 6 条「原地 seek」，之后就是「转码没追上 → 重建会话」。
  ///    现在 260ms 内的连按只累加目标，落一次。
  /// 2. **基准位置不能用 `_absPosition(position)` 硬算**。新建跳转会话时
  ///    `_startMs` 已经换成新起点，而播放器还停在旧流上（首片要等 9 秒），
  ///    两者一加就是**翻倍**：日志里 `目标 338040 = 149020 + 189020`，
  ///    用户按 4 次 → 结果跳到 5 分半。基准见 [_seekBaseAbs]。
  void _seekBy(int seconds) {
    final base = _seekBaseAbs;
    final chained = _seekByTimer?.isActive ?? false;
    if (!chained) _seekByFrom = base;
    _seekByTarget =
        (chained ? _seekByTarget : base) + Duration(seconds: seconds);
    final delta = _seekByTarget - _seekByFrom;
    // 提示立刻更新（累计值），别让人连按 4 次只看到最后一个「+30 秒」
    _flashSeek(
      delta < Duration.zero
          ? tr('player.seekBack', {'n': '${-delta.inSeconds}'})
          : tr('player.seekForward', {'n': '${delta.inSeconds}'}),
    );
    _seekByTimer?.cancel();
    _seekByTimer = Timer(const Duration(milliseconds: 260), () {
      // 未加载位置也必须完成跳转；等片超时后会从目标位置新建转码会话。
      if (mounted) unawaited(_seekTo(_seekByTarget));
    });
  }

  // -------------------------------------------------------- 遥控器长按拖动
  //
  // 短按一次左右键 = 立即 ±30s / ±10s（[_seekBy]）；按住超过 420ms 就升级成
  // 「拖动进度条」：每 100ms 累加一次，增量随按住时长指数增长（4x 起步，
  // 约 2.4 秒到 180x），松开时才真正 seek。这样「连按」和「长按拖」互不打扰。

  void _beginTvHold(int dir) {
    _tvHoldDir = dir;
    _tvHoldDelay?.cancel();
    _tvHoldDelay = Timer(const Duration(milliseconds: _tvHoldDelayMs), () {
      if (!mounted || _tvHoldDir != dir) return;
      _tvHoldFrom = _seekBaseAbs;
      _tvHoldTarget = _tvHoldFrom;
      _tvHoldStartedAt = DateTime.now();
      _tvHoldTick?.cancel();
      _tvHoldTick = Timer.periodic(
        const Duration(milliseconds: _tvHoldTickMs),
        (_) => _tickTvHold(),
      );
      setState(() => _tvHoldActive = true);
    });
  }

  void _tickTvHold() {
    final started = _tvHoldStartedAt;
    if (started == null || _tvHoldDir == 0) return;
    final elapsed = DateTime.now().difference(started).inMilliseconds;
    // 非线性加速度：按住越久每秒走过的片长越多。
    final speed = (4 * math.pow(1.9, elapsed / 400)).clamp(4.0, 180.0);
    final stepMs = (speed * _tvHoldTickMs).round() * _tvHoldDir;
    final total = _timelineDuration(_playbackDuration);
    var next = _tvHoldTarget + Duration(milliseconds: stepMs);
    if (next < Duration.zero) next = Duration.zero;
    if (total > Duration.zero && next > total) next = total;
    _tvHoldTarget = next;
    setState(() {
      _dragSeeking = true;
      _dragStartMs = _tvHoldFrom.inMilliseconds.toDouble();
      _dragDeltaMs = (next - _tvHoldFrom).inMilliseconds.toDouble();
    });
  }

  void _commitTvHold() {
    _tvHoldDelay?.cancel();
    _tvHoldDelay = null;
    _tvHoldTick?.cancel();
    _tvHoldTick = null;
    _tvHoldStartedAt = null;
    _tvHoldDir = 0;
    if (!_tvHoldActive) return;
    final target = _tvHoldTarget;
    final from = _tvHoldFrom;
    setState(() {
      _tvHoldActive = false;
      _dragSeeking = false;
      _dragStartMs = null;
      _dragDeltaMs = 0;
    });
    // 几乎没动就别跳，免得「轻碰一下长按」也打断播放。
    if ((target - from).abs() < const Duration(milliseconds: 500)) return;
    unawaited(_seekTo(target));
  }

  /// 快进 / 快退的基准位置（片源绝对）。
  ///
  /// 只有「播放器时间轴确实还属于当前会话」时才能用 position：
  ///   - 正在跳转（[_jumping]）或新会话还没 open（[_pendingStartMs] 非空）→
  ///     position 还是上一条流的；等转码追上未加载目标时也用最近一次目标；
  ///   - 其余情况 → 播放器当前位置，这是最准的。
  Duration get _seekBaseAbs {
    final ms = seekBaseMs(
      playerPosMs: _playbackPosition.inMilliseconds,
      startMs: _startMs,
      lastTargetMs: _lastSeekTarget.inMilliseconds,
      jumping: _jumping,
      streamPending:
          _pendingJump != null ||
          _pendingStartMs != null ||
          _seeking ||
          _waitingTarget != null,
    );
    return Duration(milliseconds: ms < 0 ? 0 : ms);
  }

  // ------------------------------------------------------------ 进度手势
  //
  // 手势：横向拖动 = 快进快退（松手才真跳）；
  // 单击 = 操作栏显隐；双击在手机上是播放 / 暂停，桌面 / Web 仍是全屏。
  // 以前只有底部那条细滑块能拖，手机上一根手指很难抓准；画面区域
  // 那么大一块却只认「单击唤出控件」和「长按 2 倍速」，等于浪费。

  Future<void> _onDoubleTap() async {
    if (_locked) return;
    // 桌面 / Web：双击 = 进 / 出全屏。
    await _toggleImmersive();
    _poke();
  }

  /// 手机端手势：单击唤出 / 收起操作栏，双击播放 / 暂停（不再双击全屏）。
  bool get _phoneGestures =>
      !_tvMode &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  void _onPhoneDoubleTap() {
    if (_locked) return;
    _togglePlay();
    _poke();
  }

  /// 竖向滑动的累计位移：手机上「上滑 / 下滑」切上一条 / 下一条，
  /// 和短剧连播页的手感保持一致。松手才切，滑到一半反悔不算。
  double _vDragDy = 0;

  /// 跟手切集的实时位移：画面上移为负。原生 Surface 的画面要同步平移，
  /// 不然手势只动了控件、视频不动（用户反馈「不是跟我手势切走的」）。
  final ValueNotifier<double> _swipeOffset = ValueNotifier<double>(0);
  late final AnimationController _swipeAnim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 210),
  );
  double _swipeFrom = 0;
  double _swipeTo = 0;
  bool _swipeSwitching = false;
  double _lastNativeOffset = 0;

  int get _playlistIndex =>
      _playlist.indexWhere((e) => e.id == widget.itemId);

  bool _hasAdjacent(int delta) {
    if (!_hasPlaylist) return false;
    final i = _playlistIndex;
    if (i < 0) return false;
    final j = i + delta;
    return j >= 0 && j < _playlist.length;
  }

  VideoItem? _adjacentItem(int delta) {
    if (!_hasAdjacent(delta)) return null;
    return _playlist[_playlistIndex + delta];
  }

  void _applySwipeOffset(double dy) {
    _swipeOffset.value = dy;
    // 安卓视频在原生 SurfaceView 上：按同一段位移平移原生层，画面才跟手
    if (_nativeTvActive && (dy - _lastNativeOffset).abs() >= 0.5) {
      _lastNativeOffset = dy;
      unawaited(_tvMedia3Player.setOffset(dy));
    }
  }

  void _swipeAnimTick() {
    final t = Curves.easeOutCubic.transform(_swipeAnim.value);
    _applySwipeOffset(_swipeFrom + (_swipeTo - _swipeFrom) * t);
  }

  Future<bool> _animateSwipeTo(double to) async {
    _swipeAnim
      ..removeListener(_swipeAnimTick)
      ..addListener(_swipeAnimTick);
    _swipeFrom = _swipeOffset.value;
    _swipeTo = to;
    try {
      await _swipeAnim.forward(from: 0).orCancel;
    } on TickerCanceled {
      return false;
    } finally {
      _swipeAnim.removeListener(_swipeAnimTick);
    }
    if (!mounted) return false;
    return true;
  }

  void _onVerticalDragStart(DragStartDetails d) {
    _vDragDy = 0;
    if (!_hasPlaylist || _locked || _swipeSwitching) return;
    if (_controls) setState(() => _controls = false);
  }

  void _onVerticalDragUpdate(DragUpdateDetails d) {
    _vDragDy += d.delta.dy;
    if (!_hasPlaylist || _locked || _swipeSwitching) return;
    final h = MediaQuery.sizeOf(context).height;
    var dy = _vDragDy;
    // 到头了只给 1/4 的位移（橡皮筋），提示这边没有下一条
    if (dy < 0 && !_hasAdjacent(1)) dy *= 0.25;
    if (dy > 0 && !_hasAdjacent(-1)) dy *= 0.25;
    _applySwipeOffset(dy.clamp(-h, h).toDouble());
  }

  Future<void> _onVerticalDragEnd(DragEndDetails d) async {
    if (!_hasPlaylist || _locked || _swipeSwitching) {
      _vDragDy = 0;
      return;
    }
    final h = MediaQuery.sizeOf(context).height;
    final velocity = d.primaryVelocity ?? 0;
    final dy = _vDragDy;
    _vDragDy = 0;
    final up = dy < 0 || (dy == 0 && velocity < 0);
    final delta = up ? 1 : -1;
    final wantsNext = _hasAdjacent(delta);
    final enough = dy.abs() > h * 0.18 || velocity.abs() > 650;
    if (!wantsNext || !enough) {
      // 没到阈值 / 到头了：回弹
      await _animateSwipeTo(0);
      _applySwipeOffset(0);
      return;
    }
    _swipeSwitching = true;
    // 画面整块滑出屏幕，接着在新页面里继续（新画面从底部就位）
    await _animateSwipeTo(up ? -h : h);
    if (!mounted) return;
    final it = _adjacentItem(delta);
    if (it == null) {
      await _animateSwipeTo(0);
      _applySwipeOffset(0);
      _swipeSwitching = false;
      return;
    }
    try {
      await _playOther(it, popSheet: false);
    } finally {
      // 换页失败时把画面拉回来，别停在半空中
      if (mounted) {
        _swipeOffset.value = 0;
        _applySwipeOffset(0);
        _swipeSwitching = false;
      }
    }
  }

  /// 拖动中：只更新预览，不做 seek（每帧都 seek 会把转码会话拖垮）
  void _onSeekDragStart(DragStartDetails d) {
    if (_locked) return;
    final total = _timelineDuration(_playbackDuration);
    if (total <= Duration.zero) return;
    _dragStartMs = _absPosition(_playbackPosition).inMilliseconds.toDouble();
    _dragDeltaMs = 0;
    setState(() => _dragSeeking = true);
  }

  void _onSeekDragUpdate(DragUpdateDetails d) {
    if (!_dragSeeking) return;
    final w = MediaQuery.sizeOf(context).width;
    final total = _timelineDuration(_playbackDuration).inMilliseconds
        .toDouble();
    if (w <= 0 || total <= 0) return;
    // 划满一屏 ≈ 整片的 1/4，夹在 1 分钟 ~ 5 分钟之间：
    // 短片不会一动就到片尾，两小时的片子也不用划十几下才走一分钟。
    final span = (total / 4).clamp(60000.0, 300000.0);
    setState(() => _dragDeltaMs += d.delta.dx / w * span);
  }

  Future<void> _onSeekDragEnd(DragEndDetails d) async {
    if (!_dragSeeking) return;
    final start = _dragStartMs ?? 0;
    final total = _timelineDuration(_playbackDuration).inMilliseconds
        .toDouble();
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
    final total = _timelineDuration(_playbackDuration).inMilliseconds
        .toDouble();
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
  /// 播放器已缓冲到的**片源绝对位置**（会话时间轴 + 起转偏移）。
  ///
  /// 只信播放器手里的缓冲：服务端的 `transcodedMs` 只说明「转到哪儿了」，
  /// 不代表播放器已经拿到 —— 两者能差好几分钟（见 [_seekTo] 里的注释）。
  ///
  /// `PlayerState.buffer` 两端语义不同：Web 是 `element.buffered.end(最后一段)`
  /// （会话时间轴上的绝对位置），原生 libmpv 是「当前位置之后还有多少秒」。
  Duration _bufferedEndAbs() {
    // 新流还没 open：缓冲还是上一条流的，算出来的绝对位置毫无意义
    if (_pendingStartMs != null) return Duration.zero;
    final pos = _playbackPosition;
    final buf = _playbackBuffer;
    final end = kIsWeb
        ? buf
        : _nativeTvActive
        ? _tvMedia3Player.state.bufferedPosition
        : pos + buf;
    if (end <= Duration.zero) return Duration.zero;
    return end + _startOffset;
  }

  Future<void> _seekTo(Duration target, {bool allowJump = true}) async {
    _lastSeekAt = DateTime.now();
    // 连续按 → / 连续拖：只让最后一次真正落地。中间那次可能在
    // [_awaitProduced] 里等转码（最多 8 秒），等回来时用户早就换了目标 ——
    // 不拦的话就会「跳到最后一次，又被前一次的旧目标盖回去」。
    final gen = ++_seekGen;
    if (_waitingTarget != null) _markWaitingTarget(null);
    if (_seeking) setState(() => _seeking = false);
    final total = _timelineDuration(_playbackDuration);
    var t = target;
    if (t < Duration.zero) t = Duration.zero;
    if (total > Duration.zero && t > total) t = total;
    // 目标先落账：`_jumping`（新会话还没 open）期间播放器位置属于**旧流**，
    // 快进 / 快退只能拿它当基准（见 [_seekBaseAbs]）。
    _lastSeekTarget = t;
    if (!_isTranscode || widget.itemId == null) {
      // 直链 / 没有条目 id（详情页指定的 HLS 地址）没法重建会话，只能按老规矩夹取
      final limit = _seekLimit(_playbackDuration);
      if (_isTranscode && limit > Duration.zero && t > limit) t = limit;
      if (allowJump) _beginSeekRecovery(t);
      try {
        final applied = await _queuePlayerSeek(t, gen, showLoading: allowJump);
        if (!applied) return;
      } catch (e) {
        await _recoverFailedSeek(t, gen, e);
        return;
      }
      if (!mounted || gen != _seekGen) return;
      // TV：遥控器快进 / 长按拖动不能把整条操作栏叫出来（用户 2026-11-24：
      // 一按右键控件就出现，连按和长按拖动都被打断）。桌面 / 手机保持原行为。
      if (!_tvMode || _controls) _poke();
      _armStallWatch(target: t);
      // Web 上 seek 会把当前 play() 打断（"interrupted by a new load request"），
      // 浏览器不会自己续上；想让位置动起来只能显式再 play。仅当用户意图是播。
      if (_wantPlay) unawaited(_ensurePlayingAfterOpen());
      return;
    }
    // 新会话正在建 / 正在 open 时又来一个目标：此时 `_startMs` 已经是**新会话**
    // 的起点，而 `position` / `_transcodedMs` 还是旧流的值 —— 在当前会话上算
    // 「在不在已转区间里」全是错的，直接交给 [_jumpTo] 合并成最后一次。
    if (_jumping || _pendingStartMs != null) {
      await _jumpTo(t);
      return;
    }
    // 进度条上**已经变粗**的那一段（服务端已转出的分片）一律原地 seek。
    //
    // 以前这里用「播放器已缓冲末尾 + 2s」当界限：只要目标超出播放器手里那点
    // 缓冲就去重建会话。播放器通常只缓冲十几秒，等于「几乎每次拖进度条都重建」——
    // H.264 首片 1.8s 还算能忍，AV1 首片 7.8~10.4s（实测），用户看到的就是
    // 「已经加载好的位置也跳不动」。分片就在服务端磁盘上，直接 seek 才是对的。
    final producedEnd = _loadedEnd;
    final bufferedAbs = _bufferedEndAbs();
    // 拖动过程中（allowJump=false，Slider 每帧都回调）只跟随播放器手里的缓冲：
    // 每帧都 poll 一个还没缓冲的分片只会让 mpv 不停中止上一次 seek。
    // 松手（allowJump=true）只要目标落在已转出区间内就原地 seek。
    final reachable = allowJump ? producedEnd : bufferedAbs;
    // 留 2 秒余量：`producedEnd` 是按播放列表算出来的末尾，最后一片可能还在写盘，
    // 或者刚被 supersede 掐掉 —— 那片就交给下面的「等转码追上」分支。
    final margin = const Duration(seconds: 2);
    final inProduced =
        reachable > Duration.zero &&
        t >= _startOffset &&
        t <= reachable - margin;

    // 每一条分支都往播放器日志里落一行：2026-11-17 那次「跳 30 秒卡死」之所以
    // 查了半天，就是因为有一个分支（贴着 producedEnd 的那 2 秒夹缝）什么都不记。
    if (allowJump) {
      ClientLogger.instance.info(
        '${inProduced ? '原地 seek' : 'seek 待内容'} ${t.inMilliseconds}ms '
        '(produced=${producedEnd.inMilliseconds}ms '
        'buffered=${bufferedAbs.inMilliseconds}ms start=${_startMs}ms)',
        route: 'player.seek/${_sessionId ?? 'direct'}',
      );
    }

    Future<void> seekHere() async {
      if (allowJump) _beginSeekRecovery(t);
      try {
        final applied = await _queuePlayerSeek(
          t - _startOffset,
          gen,
          showLoading: allowJump,
        );
        if (!applied) return;
      } catch (e) {
        await _recoverFailedSeek(t, gen, e);
        return;
      }
      if (!mounted || gen != _seekGen) return;
      // TV：遥控器快进 / 长按拖动不能把整条操作栏叫出来（用户 2026-11-24：
      // 一按右键控件就出现，连按和长按拖动都被打断）。桌面 / 手机保持原行为。
      if (!_tvMode || _controls) _poke();
      if (_wantPlay) unawaited(_ensurePlayingAfterOpen());
      // 拖动过程中每帧都会走这里，看门狗只在松手那次（allowJump）挂
      if (allowJump) _armStallWatch(target: t);
    }

    if (inProduced) {
      await seekHere();
      return;
    }
    if (!allowJump) return;
    // 目标落在「已转出末尾」之外，分两种：
    //   - 只多一点点（键盘 ±30s、拖个几十秒，≤30s）→ **先等转码追上**再原地 seek；
    //   - 差得远 → 另建一条从该位置起转的会话（顺序转码没法凭空造出分片）。
    //
    // 为什么「先等」而不是像以前那样立刻「前探 seek」：libmpv 会立刻把 position
    // 报成目标值，然后去要一个还不存在的分片，等不到就 404，整条 HLS 流当场废掉
    // （会话 `795ee81b` 实测：等 3674ms 拿到 seg18 之后就再也没动过）。
    // 用户要的就是「没加载你就转码加载」——等片，别让播放器去要空气。
    final over = t - producedEnd;
    if (over > Duration.zero && over <= const Duration(seconds: 30)) {
      // 预算按「差多远」给：同机转码实测 ~3.5 倍速（2s 一片、约 0.6s 出一片），
      // 差 30 秒大约 9 秒就追上。原来给 14/20 秒太久 —— 那十几秒里画面停在
      // 已转出末尾不动，用户看到的就是「卡住」（2026-11-17 反馈）。
      // 现在：最多等 10 秒，而且**等待期间右上角有「正在转码到 xx:xx」**，
      // 不再是无声冻屏；等不到就按「点了时间条」重建会话。
      final budget = clampWaitBudget(over);
      bool produced;
      if (_seeking) setState(() => _seeking = false);
      _markWaitingTarget(t);
      try {
        produced = await _awaitProduced(t, budget: budget, seekGeneration: gen);
        // 等的这几秒里用户又按了 → 直接作废，别把旧目标盖到新目标上
        if (!mounted || gen != _seekGen) return;
        if (!produced) {
          // 会话可能刚才还是 paused（转完一段停手了）：明确催一次再给 2 秒。
          // `_awaitProduced` 里每拍都在报位置，但服务端要下一个 pump 周期才动。
          _nudgeTranscode(t);
          produced = await _awaitProduced(
            t,
            budget: const Duration(seconds: 2),
            seekGeneration: gen,
          );
          if (!mounted || gen != _seekGen) return;
        }
      } finally {
        _clearWaitingTarget(t, seekGeneration: gen);
      }
      if (produced) {
        ClientLogger.instance.info(
          '等转码追上 ${t.inMilliseconds}ms（over=${over.inMilliseconds}ms）→ 原地 seek',
          route: 'player.seek/${_sessionId ?? 'direct'}',
        );
        await seekHere();
        return;
      }
      ClientLogger.instance.info(
        '等转码追上超时 ${t.inMilliseconds}ms'
        '（over=${over.inMilliseconds}ms produced=${_loadedEnd.inMilliseconds}ms）'
        ' → 从目标位置重建会话',
        route: 'player.seek/${_sessionId ?? 'direct'}',
      );
    }
    if (!mounted || gen != _seekGen) return;
    if (over > Duration.zero) {
      ClientLogger.instance.info(
        '转码没追上 ${t.inMilliseconds}ms（over=${over.inMilliseconds}ms）→ 重建会话',
        route: 'player.seek/${_sessionId ?? 'direct'}',
      );
    } else if (t < _startOffset) {
      // 回退越过会话起点（多半是刚「快进」建过会话）：时间轴没有负数，
      // 只能再建一条从目标起转的会话 —— 这一步要重新等首片，日志里必须留下证据。
      ClientLogger.instance.info(
        '回退越界 ${t.inMilliseconds}ms（start=${_startMs}ms）→ 重建会话',
        route: 'player.seek/${_sessionId ?? 'direct'}',
      );
    }
    await _jumpTo(t);
  }

  Future<bool> _queuePlayerSeek(
    Duration position,
    int gen, {
    required bool showLoading,
  }) async {
    if (showLoading && mounted && !_seeking) {
      setState(() => _seeking = true);
    }
    try {
      return await _seekQueue.enqueue(() async {
        if (!mounted || gen != _seekGen) return;
        await _playbackSeek(position).timeout(_seekCommandTimeout);
      });
    } finally {
      if (showLoading && mounted && gen == _seekGen && _seeking) {
        setState(() => _seeking = false);
      }
    }
  }

  Future<void> _recoverFailedSeek(
    Duration target,
    int gen,
    Object error,
  ) async {
    if (!mounted || gen != _seekGen) return;
    ClientLogger.instance.warn(
      'seek 失败，尝试恢复：${error.runtimeType}',
      route: 'player.seek/${_sessionId ?? 'direct'}',
      detail: 'target=${target.inMilliseconds}ms',
    );
    if (_isTranscode && widget.itemId != null) {
      await _jumpTo(target);
      return;
    }
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger != null && mounted) {
      NasSnack.showOn(messenger, tr('player.seekFailed', {'error': '$error'}));
    }
  }

  /// 播放停滞看门狗：**每秒一拍盯着画面到底有没有往前走**，卡住就自己救回来。
  ///
  /// 用户原话：「如果加载了就自动播，如果没加载你就转码加载就行，为什么现在卡住了？」
  /// 所以这里不许「静默冻住」：任何原因导致的画面不动都必须被接住并自动恢复。
  ///
  /// 判据只有一条 —— **水位**（历史最大 position）在 [PlayStallDetector.limitSeconds] 内
  /// 没涨过 0.7 秒。以前的实现拿「seek 之前的位置」当基准，而 `player.seek()` 是瞬时
  /// 生效的，第一拍就会看到 position 已经跳到目标值（几万毫秒），于是判「在播」直接
  /// 退场。2026-11-17 会话 `795ee81b` 就是这样：09:51:47 前探 seek 之后 position
  /// 钉死在 36562 整整 6 分钟，日志里连一条告警都没有。
  ///
  /// 两级补救，一动一静，都不重建会话就先试便宜的：
  ///   1 级（8 秒）：请服务端从当前位置继续转（[_nudgeTranscode]）+ 重新 seek 一次；
  ///   2 级（再 8 秒）：原地救不回来 → 按当前位置重建会话（[_jumpTo]）。
  ///
  /// [target] 只用于日志（`_jumpTo` 用的位置从播放器实时读，不用它）。
  void _armStallWatch({Duration? target}) {
    if (target != null) _stallTarget = target;
    _stall.reset(_playbackPosition);
    // 常驻：已经在跑就别重建（重建会让判定基准跟着漂）
    if (_stallTicker?.isActive ?? false) return;
    _stallTicker = Timer.periodic(const Duration(seconds: 1), _stallTick);
  }

  /// 这一拍该不该判；返回跳过原因（null = 该判）。
  ///
  /// 「用户自己造成的画面不动」（暂停 / 播完 / 首帧准备）不记日志；
  /// 换档 / 跳转 / 等转码 / 错误页这几种**必须留痕** —— 连续的跳过之后如果
  /// 画面还是不动，日志里得能区分「看门狗在跳过」和「看门狗已经死了」，
  /// 这正是 `c16e2aeb` 那次查不出原因的地方（116 秒零日志）。
  String? _stallSkipWhyNow() {
    // 还没选好源 / 首帧还没出来：没有「在播」这回事，别去催转码
    if (_url.isEmpty) return '首帧准备';
    if (_preparing) return '首帧准备';
    if (_switching) return '换档中';
    if (_jumping) return '跳转中';
    if (_seeking) return '播放器跳转中';
    if (_waitingTarget != null) return '等转码追上';
    if (!_wantPlay) return '用户暂停';
    if (_error != null) return '错误页';
    if (_playbackCompleted) return '已播完';
    return null;
  }

  void _logStallSkip(String why) {
    if (stallSkipQuiet.contains(why)) return;
    final now = DateTime.now();
    // 同一个原因 20 秒内只记一条：换档 / 等片本来就会连续跳过好几拍
    if (_stallSkipWhy == why &&
        now.difference(_stallSkipLoggedAt) < const Duration(seconds: 20)) {
      return;
    }
    _stallSkipWhy = why;
    _stallSkipLoggedAt = now;
    ClientLogger.instance.info(
      '看门狗跳过（$why）',
      route: 'player.stall/${_sessionId ?? 'direct'}',
      detail:
          'pos=${_playbackPosition.inMilliseconds}ms '
          'target=${_stallTarget?.inMilliseconds ?? '-'}ms '
          'produced=${_loadedEnd.inMilliseconds}ms '
          'buffering=$_playbackBuffering',
    );
  }

  /// 一秒一拍。**唯一**允许取消它的地方是 dispose —— 换流、跳转、报错都不许。
  void _stallTick(Timer timer) {
    if (!mounted) {
      timer.cancel();
      return;
    }
    // 跳转可等待服务端的软编首片（看门狗最多 90s）；超过上限只复位 UI，
    // 不要重新建会话，否则旧 ffmpeg 还在跑时会反复抢占并继续卡住。
    final since = _jumpingSince;
    if (_jumping &&
        since != null &&
        DateTime.now().difference(since) > const Duration(seconds: 150)) {
      _jumpRunGen += 1;
      _seekGen += 1;
      _jumpingSince = null;
      _pendingJump = null;
      _pendingJumpGen = null;
      _seekByTimer?.cancel();
      ClientLogger.instance.error(
        '跳转超过 150s 未完成 → 取消旧请求并保留当前流',
        route: 'player.stall/${_sessionId ?? 'direct'}',
        detail:
            'target=${_lastSeekTarget.inMilliseconds}ms '
            'pos=${_playbackPosition.inMilliseconds}ms',
      );
      if (mounted) {
        setState(() => _jumping = false);
        final messenger = ScaffoldMessenger.maybeOf(context);
        if (messenger != null) {
          NasSnack.showOn(messenger, tr('player.seekNotReady'), error: true);
        }
      }
      _stall.reset(_playbackPosition);
      return;
    }
    _logSeekRecoveryIfReady();
    final why = _stallSkipWhyNow();
    if (why != null) {
      _logStallSkip(why);
      // 暂停 / 播完期间画面本来就不动：把基准跟着挪走，
      // 免得恢复播放后第一拍就被算成「这一拍没涨」
      _stall.reset(_playbackPosition);
      return;
    }
    _stallSkipWhy = null;
    final action = _stall.tick(_playbackPosition);
    if (action == PlayStallAction.none) return;
    final at = _absPosition(_playbackPosition);
    final detail =
        'pos=${_playbackPosition.inMilliseconds}ms '
        'at=${at.inMilliseconds}ms '
        'buffered=${_bufferedEndAbs().inMilliseconds}ms '
        'produced=${_loadedEnd.inMilliseconds}ms '
        'buffering=$_playbackBuffering '
        'want=${_stallTarget?.inMilliseconds ?? '-'}ms';
    if (action == PlayStallAction.nudge) {
      ClientLogger.instance.warn(
        '播放停滞 ${_stall.limitSeconds}s 画面不动 → 续转 + 重新 seek（$detail）',
        route: 'player.stall/${_sessionId ?? 'direct'}',
      );
      unawaited(_stallRecover(at));
      return;
    }
    // 二级补救（重建会话）只在这条前提成立时做：**服务端早就把内容转到当前位置
    // 之后了**，也就是「片在磁盘上、播放器却不动」。反过来说，如果转码还落在
    // 后面（外网慢 / 队列排队），重建只会把 ffmpeg 重新起一遍、更慢 ——
    // 那种情况退回一级补救（续转 + 重 seek），等转码追上来。
    if (_loadedEnd < at + const Duration(seconds: 10)) {
      ClientLogger.instance.warn(
        '播放停滞 ${_stall.limitSeconds * 2}s，但转码还在后面 → 继续等（$detail）',
        route: 'player.stall/${_sessionId ?? 'direct'}',
      );
      unawaited(_stallRecover(at));
      return;
    }
    // 防「卡 → 重建 → 又卡」的死循环：那种情况每 16 秒起一次 ffmpeg，
    // 比冻住还糟（CPU 打满、别的会话全排队）。5 分钟内最多重开 5 次，
    // 超了就收手，只留日志 —— 这时候需要的是换画质 / 换编码，不是再重开。
    final now = DateTime.now();
    _stallRebuiltAt.removeWhere(
      (t) => now.difference(t) > const Duration(minutes: 5),
    );
    if (_stallRebuiltAt.length >= 5) {
      ClientLogger.instance.error(
        '反复卡住（5 分钟内已重建 5 次）→ 停止自动重建（$detail）',
        route: 'player.stall/${_sessionId ?? 'direct'}',
      );
      // 收手之后别每拍重复报错：把基准挪到当前位置，等它自己再攒 8 拍
      _stall.reset(_playbackPosition);
      return;
    }
    _stallRebuiltAt.add(now);
    ClientLogger.instance.warn(
      '播放停滞 ${_stall.limitSeconds * 2}s 仍未恢复 → 重建会话 target=${at.inMilliseconds}ms（$detail）',
      route: 'player.stall/${_sessionId ?? 'direct'}',
    );
    _stall.reset(_playbackPosition);
    unawaited(_jumpTo(at));
  }

  /// 1 级补救：让服务端把这个位置往后续转，同时重新 seek 一次。
  ///
  /// 重新 seek 有两个用处：把「上一次 seek 卡住的 pending 状态」清掉；
  /// 顺便让播放器重新拉一次它现在需要的那个分片。
  Future<void> _stallRecover(Duration at) async {
    if (!mounted || !_wantPlay) return;
    _nudgeTranscode(at);
    try {
      final applied = await _seekQueue.enqueue(() async {
        await _playbackSeek(at - _startOffset).timeout(_seekCommandTimeout);
      });
      if (!applied) return;
    } catch (_) {
      /* seek 失败已记录，不影响后续补救 */
    }
    if (!mounted) return;
    // seek 会让 position 立刻回到 at，水位要跟着重置，否则下一拍就误判「涨了」
    _stall.noteStageOne(_playbackPosition);
    if (_wantPlay) unawaited(_ensurePlayingAfterOpen());
  }

  /// 等转码把 [t] 转出来（最多 [budget]），转出来了返回 true。
  ///
  /// 为什么「目标还没转出来」时不要立刻 seek：libmpv 会**立刻把 position 报成目标值**，
  /// 然后去要一个尚不存在的分片。分片路由等 10 秒还等不到就 404，而 mpv 拿到 404
  /// 之后整条 HLS 流就废了 —— 实测会话 `795ee81b`：09:51:47 前探 seek 到 seg18
  /// （produced 只到 seg13），等到 3674ms 才拿到片，从此 position 钉死在 36562，
  /// 后台还继续 prefetch 到 p1 的 seg21，然后彻底不动 6 分钟。
  /// 用户要的就是这个意思：「没加载你就转码加载」——等片，别让播放器去要空气。
  Future<bool> _awaitProduced(
    Duration t, {
    Duration budget = const Duration(seconds: 8),
    required int seekGeneration,
  }) async {
    // 每一处「不等了」都要留一行：2026-11-17 日志里有一次 `over=9020ms` 只等了
    // 25ms 就去重建会话（25ms 连一次请求都不够），却看不出是哪个条件退的场，
    // 只能靠猜。「等片」是这条链上最贵的动作，放弃的理由必须可查。
    void giveUp(String why) {
      ClientLogger.instance.warn(
        '等转码放弃 ${t.inMilliseconds}ms（$why）',
        route: 'player.await/${_sessionId ?? 'direct'}',
      );
    }

    final id = _sessionId;
    if (id == null || !_isTranscode) {
      giveUp('id=$id transcode=$_isTranscode');
      return false;
    }
    final sw = Stopwatch()..start();
    while (sw.elapsed < budget) {
      if (!mounted) {
        giveUp('页面已关闭');
        return false;
      }
      if (seekGeneration != _seekGen) {
        giveUp('目标已被更新的 seek 替代');
        return false;
      }
      // 只看 `_wantPlay` 太脆：一次误置（比如点画面唤出控件）就会把等待直接
      // 短路成「立刻重建会话」。真暂停了位置本来就不动，多等这一轮没损失。
      if (!_wantPlay && !_playbackPlaying && !_playbackBuffering) {
        giveUp('用户已暂停');
        return false;
      }
      if (_loadedEnd >= t + const Duration(seconds: 1)) return true;
      try {
        // 顺手把位置报上去：服务端据此知道「有人在等这一段」，会立刻往前铺
        final job = await ApiSession.instance.client.playerSessionGet(
          id: id,
          pos: t.inMilliseconds.toDouble(),
        );
        if (!mounted || seekGeneration != _seekGen) {
          giveUp('目标已被更新的 seek 替代');
          return false;
        }
        final transcoded = job.transcodedMs ?? 0;
        if (transcoded > _transcodedMs) _transcodedMs = transcoded;
        if (_loadedEnd >= t + const Duration(seconds: 1)) return true;
        final st = '${job.status}';
        if (st == 'failed' || st == 'canceled') {
          giveUp('会话状态 $st');
          return false;
        }
      } catch (_) {
        /* 网络抖动：下一拍再试 */
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    giveUp('等满 ${budget.inSeconds}s，produced=${_loadedEnd.inMilliseconds}ms');
    return false;
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
    _lastSeekAt = DateTime.now();
    // 连按计时器里攒的目标已经落到这次跳转上了，别再让它在跳转之后再补一刀
    _seekByTimer?.cancel();
    _lastSeekTarget = target;
    // 跳转中又有新目标（用户连续拖进度条）：只保留最后一个，
    // 等当前会话起完再跳一次，别每一下拖拽都掐掉 ffmpeg 重来。
    if (_jumping) {
      _pendingJump = target;
      _pendingJumpGen = _seekGen;
      return;
    }
    _seekQueue.invalidate();
    final seekGen = _seekGen;
    final jumpRunGen = ++_jumpRunGen;
    _beginSeekRecovery(target);
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() {
      _jumping = true;
      _seeking = false;
    });
    _jumpingSince = DateTime.now();
    try {
      final sessionCodec = _codec == 'original'
          ? defaultTranscodeCodec()
          : _codec;
      final u = await _ensureTranscode(
        _preset,
        sessionCodec,
        startMs: target.inMilliseconds,
        // 跳转会话同样按段转（跟随偏好，默认 3 分钟）：整片模式已取消，
        // 而且目标位置之后通常只占几分钟，没必要从头铺到头。
      );
      if (!mounted || seekGen != _seekGen || jumpRunGen != _jumpRunGen) {
        return;
      }
      // 新播放列表的时间轴 0 就是 target，不能再 seekTo（否则会跳过 target 那一段）。
      // autoPlay: true —— 拖进度条的人一定是想继续看，浏览器把自己的 play() 丢掉时
      // 要在这里补回来，不能让人手动点第二次。
      await _openUrl(u, retries: 3, autoPlay: true);
      if (mounted && seekGen == _seekGen && jumpRunGen == _jumpRunGen) {
        // 同 `_seekTo`：TV 上跳转会话落成也不能顺手把操作栏叫出来。
        if (!_tvMode || _controls) _poke();
      }
    } catch (e) {
      if (!mounted || seekGen != _seekGen || jumpRunGen != _jumpRunGen) {
        return;
      }
      if ((_codec == 'h265' || _codec == 'av1') &&
          !_originalFallbackAttempted) {
        _showNotice(
          tr('player.codecFallbackOriginal', {
            'want': playCodecOf(_codec)?.label ?? _codec,
          }),
          log: '跳转转码失败，尝试原码直连：${e.runtimeType}',
        );
        await _fallbackToOriginal(_codec, position: target);
        return;
      }
      if (messenger != null && mounted) {
        NasSnack.showOn(messenger, tr('player.seekFailed', {'error': '$e'}));
      }
    } finally {
      if (jumpRunGen == _jumpRunGen) {
        _jumpingSince = null;
        if (mounted) setState(() => _jumping = false);
        final next = _pendingJump;
        final nextGen = _pendingJumpGen;
        _pendingJump = null;
        _pendingJumpGen = null;
        if (next == null && mounted) {
          // 跳转收尾：新会话 open 期间那次 play() 会被「media removed / new load」
          // 打断，浏览器不会自己再补。这里等 `_jumping` 清掉后补一次播放。
          unawaited(_resumeIfIdle('跳转完成'));
        }
        if (next != null && mounted) {
          // 让当前这次 open 的 play() 中断先落地，再发起最后一个仍有效的目标。
          await Future<void>.delayed(const Duration(milliseconds: 300));
          if (mounted && nextGen == _seekGen) unawaited(_jumpTo(next));
        }
      }
    }
  }

  Future<void> _setLoop(PlaylistMode mode, {bool shuffle = false}) async {
    _loop = mode;
    _shuffle = shuffle;
    if (_nativeTvActive) {
      await _tvMedia3Player.setRepeatMode(_nativeRepeatMode(mode));
      await _tvMedia3Player.setShuffle(shuffle);
    } else {
      await _player.setPlaylistMode(mode);
      await _player.setShuffle(shuffle);
    }
    if (mounted) setState(() {});
  }

  String _nativeRepeatMode(PlaylistMode mode) => switch (mode) {
    PlaylistMode.single => 'one',
    PlaylistMode.loop => 'all',
    PlaylistMode.none => 'off',
  };

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final k = event.logicalKey;
    if (k == LogicalKeyboardKey.space) {
      _togglePlay();
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
    // TV 遥控器：返回键先退出沉浸，再退出播放器（普通端保持原行为）
    if (TvScope.of(context) &&
        (k == LogicalKeyboardKey.escape || k == LogicalKeyboardKey.backspace)) {
      if (_immersive) {
        _toggleImmersive();
      } else {
        Navigator.of(context).maybePop();
      }
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
    // 新会话已建好、但新流还没 open：播放器手里的位置属于上一条流，
    // 加上 `_startMs` 就是**翻倍**（2026-11-17：149020 + 189020 = 338040，
    // 用户按了 4 次 → 直接飞到 5 分半）。这段时间一律按新会话起点算 ——
    // 那也正是播放器马上就要停的位置。
    final pending = _pendingStartMs;
    if (pending != null) return pending;
    if (raw <= Duration.zero) return _startOffset;
    final abs = _startOffset + raw;
    // HLS EVENT 列表首片未就绪时，mpv 可能把分片绝对 PTS 当成 time-pos
    // （26 小时量级）。不夹住会让进度条、字幕定位、观看上报一起跑飞。
    final limit = _timelineDuration(_playbackDuration);
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
        playerMs: done ? _playbackDuration.inMilliseconds : 0,
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
        PopupMenuItem<double>(value: v, child: _checked('${v}x', _rate == v)),
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
    final qualityCodec = _codec == 'original'
        ? defaultTranscodeCodec()
        : _codec;
    final cur = _isVideoCopySession
        ? _copySessionLabel
        : _codec == 'original'
        ? tr('player.sourceDirect')
        : playQualityPresetOf(_preset)?.labelFor(qualityCodec) ?? _preset;
    // 只列这部片转得出来的档位：没有 1080p 的片就别给 1080P 选项。
    final options = presetsForSource(_srcHeight).where((p) => !p.copy).toList();
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
            child: _checked(p.labelFor(qualityCodec), _preset == p.key),
          ),
        const PopupMenuDivider(),
        // 原码是播放策略；H.264 只保留为内部兼容编码。
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

  /// 切音轨：源清单可用时按源音轨号重建转码会话（转码流只有一条音轨），
  /// 否则直接把内核的轨道切过去。菜单和 TV 面板共用这一段，避免两套逻辑。
  Future<void> _selectAudio(int i) async {
    final tracks = _player.state.tracks.audio;
    final source = _audioTracks;
    if (_nativeTvActive && !_isTranscode && i >= 0 && i < source.length) {
      await _tvMedia3Player.setAudioTrack(i);
      if (mounted) setState(() => _audioIndex = i);
      return;
    }
    if (source.isEmpty) {
      if (i >= 0 && i < tracks.length) {
        await _player.setAudioTrack(tracks[i]);
      }
      return;
    }
    if (i == _audioIndex) return;
    // 转码流只有一条音轨：切源里的第 N 条要重建会话，并从当前位置接着播
    // （位置直接当成新会话的起转点，时间轴 0 = 这里）
    final pos = _absPosition(_playbackPosition);
    _audioIndex = i;
    final u = await _ensureTranscode(
      _preset,
      _codec,
      startMs: pos.inMilliseconds,
    );
    await _openUrl(u);
  }

  Widget _audioButton() {
    final tracks = _player.state.tracks.audio;
    // 源文件音轨优先：转码流的 tracks.audio 只有一条，看不出内容
    final source = _audioTracks;
    return PopupMenuButton<int>(
      tooltip: tr('player.audioTrack'),
      color: const Color(0xFF222222),
      icon: const Icon(
        Icons.audiotrack_outlined,
        color: Colors.white,
        size: 20,
      ),
      onSelected: (i) async {
        await _selectAudio(i);
        _poke();
      },
      itemBuilder: (_) => [
        if (source.isNotEmpty)
          for (final t in source)
            PopupMenuItem<int>(
              value: t.index,
              child: _checked(
                _audioTrackLabel(t, t.index),
                _audioIndex == t.index,
              ),
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
    final anchor =
        _volumeAnchor.currentContext?.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
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
                _playbackSetVolume(v);
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

  /// P0.5 临时探针：用原生 Activity 直接播当前片源，验证真实 DV 输出。
  ///
  /// 只在非 release 包里有入口（播放信息面板标题长按），正式版不可达；
  /// 方案 A 定稿或否掉后，与 `DvProbeActivity.kt`、`AndroidManifest.xml` 条目一起删除。
  Future<void> _launchDvProbe() async {
    final url = _directUrl.isNotEmpty ? _directUrl : _url;
    if (url.isEmpty) return;
    // 探针会自己起一个播放器：先暂停本页，避免两路音频同时响。
    await _playbackPause();
    try {
      await const MethodChannel('com.colanas.os/dv_probe')
          .invokeMethod<void>('launch', <String, Object?>{
            'url': url,
            'audioUrl': _mergedAudioUrl,
            'formatHint': _probeFormatHint(),
          });
    } on PlatformException catch (e) {
      ClientLogger.instance.warn(
        'DV 探针启动失败：${e.message}',
        route: 'player.probe',
      );
    }
  }

  String _probeFormatHint() {
    final container = widget.compat?['container'] as String?;
    if (container != null && container.isNotEmpty) return container;
    final path = Uri.tryParse(_directUrl)?.path ?? '';
    final dot = path.lastIndexOf('.');
    return dot >= 0 ? path.substring(dot + 1) : '';
  }

  Future<void> _showInfo() async {
    final c = widget.compat ?? const <String, dynamic>{};
    String? v(dynamic x) => x == null || '$x'.isEmpty ? '—' : '$x';
    if (_sessionId != null) {
      await _refreshJob();
      if (!mounted) return;
    }
    // 码率：源码率按「文件大小 ÷ 时长」算，目标码率取当前档位 × 实际编码
    final srcKbps = sourceKbpsOf(
      widget.sourceBytes ?? 0,
      widget.durationMs ?? 0,
    );
    final tgtKbps = _isTranscode
        ? (playQualityPresetOf(_preset)?.bitrateFor(_actualCodec ?? _codec) ??
              0)
        : 0;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1B1B1B),
      // 信息行会随片源变多（HDR 直通 / DV / 设备能力…），小屏上不再固定
      // 9/16 高度，改成可滚动 + 最多占 80% 屏高，避免 RenderFlex overflow。
      isScrollControlled: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.8,
      ),
      builder: (_) => SingleChildScrollView(
        padding: const EdgeInsets.all(NasTokens.spaceLg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              // P0.5 临时探针入口：仅非 release 包，长按标题拉起原生 DV 播放页。
              onLongPress: kReleaseMode ? null : _launchDvProbe,
              child: Text(
                tr('player.mediaInfo'),
                style: const TextStyle(color: Colors.white, fontSize: 17),
              ),
            ),
            const SizedBox(height: NasTokens.spaceMd),
            _infoRow(
              tr('player.playbackSource'),
              _isVideoCopySession
                  ? _copySessionLabel
                  : _isTranscode
                  ? tr('player.sourceTranscode')
                  : tr('player.sourceDirect'),
            ),
            // 是否转码中：直连时这一行没有意义，不显示
            if (_isTranscode)
              _infoRow(tr('player.transcodeState'), _jobStateText),
            _infoRow(
              tr('player.bitrate'),
              _isTranscode && tgtKbps > 0
                  ? tr('player.rateTo', {
                      'from': mbpsLabel(srcKbps),
                      'to': mbpsLabel(tgtKbps),
                    })
                  : mbpsLabel(srcKbps),
            ),
            _infoRow(
              tr('player.quality'),
              playQualityPresetOf(_preset)?.labelFor(_actualCodec ?? _codec) ??
                  _preset,
            ),
            // 转码时把「源编码 → 实际输出编码」写在同一行，别只给分辨率/码率。
            // 编码回落（如 DV 片源 AV1 → H.264）也会在这里直接看到原因。
            _infoRow(
              tr('player.videoCodec'),
              _isVideoCopySession
                  ? _sourceCodecLabel(c['videoCodec'])
                  : _isTranscode
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
            if (_reasons.isNotEmpty) _infoRow(tr('player.hdr'), _reasonText),
            // 渲染器 / 色调映射：色不对时先看这两行，比猜「显卡不支持」有用
            _infoRow(tr('player.renderer'), _rendererSummary),
            _infoRow(
              tr('player.toneMap'),
              !_isTranscode
                  ? tr('player.off')
                  : _actualToneMap == null
                  ? '—'
                  : _actualToneMap!
                  ? tr('player.on')
                  : tr('player.off'),
            ),
            _infoRow(tr('player.hdrDirect'), _directStatusText),
            _infoRow(
              tr('player.dvDirect'),
              _srcHdr == HdrLevel.dolbyVision ? _directStatusText : '—',
            ),
            if (_display.known)
              _infoRow(
                tr('player.tv.hdrCapability'),
                _display.maxHdr == HdrLevel.none
                    ? tr('player.tv.hdrNone')
                    : tr('player.reason.${_display.maxHdr.reason}'),
              ),
            _infoRow(
              tr('player.audioNormalize'),
              _audioNormalizeLabel(PlayPreferences.audioNormalizeMode),
            ),
            _infoRow(
              tr('player.audioDownmix'),
              PlayPreferences.audioDownmix ? tr('player.on') : tr('player.off'),
            ),
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

  String _audioNormalizeLabel(AudioNormalizeMode mode) => switch (mode) {
    AudioNormalizeMode.inherit => tr('video.client.audioNormalizeInherit'),
    AudioNormalizeMode.enabled => tr('video.client.audioNormalizeForceOn'),
    AudioNormalizeMode.disabled => tr('video.client.audioNormalizeForceOff'),
  };

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
              ListTile(
                title: Text(
                  tr('player.audioNormalize'),
                  style: const TextStyle(color: Colors.white),
                ),
                trailing: DropdownButton<AudioNormalizeMode>(
                  dropdownColor: const Color(0xFF333333),
                  value: PlayPreferences.audioNormalizeMode,
                  underline: const SizedBox.shrink(),
                  items: [
                    for (final mode in AudioNormalizeMode.values)
                      DropdownMenuItem<AudioNormalizeMode>(
                        value: mode,
                        child: Text(
                          _audioNormalizeLabel(mode),
                          style: const TextStyle(color: Colors.white),
                        ),
                      ),
                  ],
                  onChanged: (mode) async {
                    if (mode == null) return;
                    await PlayPreferences.saveAudio(normalizeMode: mode);
                    _applyDirectAudio();
                    setLocal(() {});
                    await _switchQuality(
                      _preset,
                      codec: _codec,
                      persist: false,
                      notify: false,
                    );
                  },
                ),
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
                  await _switchQuality(
                    _preset,
                    codec: _codec,
                    persist: false,
                    notify: false,
                  );
                },
              ),
              SwitchListTile(
                title: Text(
                  tr('video.client.toneMap'),
                  style: const TextStyle(color: Colors.white),
                ),
                subtitle: Text(
                  tr('video.client.toneMapHint'),
                  style: const TextStyle(color: Colors.white54),
                ),
                value: PlayPreferences.toneMap,
                onChanged: (v) async {
                  await PlayPreferences.saveToneMap(v);
                  setLocal(() {});
                  await _switchQuality(
                    _preset,
                    codec: _codec,
                    persist: false,
                    notify: false,
                  );
                },
              ),
              if (_tvMode)
                SwitchListTile(
                  title: Text(
                    tr('player.tvDirectOriginal'),
                    style: const TextStyle(color: Colors.white),
                  ),
                  value: PlayPreferences.tvDirectOriginal,
                  onChanged: (v) async {
                    await PlayPreferences.saveTvDirectOriginal(v);
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
      // 原生视频层现在由新页面接管（旧页面 dispose 不会再拆），
      // 这里必须先把旧画面停住，否则切集过程中上一集的声音还在响。
      if (_nativeTvActive) {
        unawaited(_tvMedia3Player.pause());
      } else {
        unawaited(_player.pause());
      }
      await Navigator.of(context).pushReplacement(
        // 换集不能带页面转场：上一页已经把下一条的抽帧滑到整屏，这里再滑 / 缩放
        // 一次就成了「从左到右闪一下」。新页面用同一张图接上，才是无缝。
        PageRouteBuilder<void>(
          transitionDuration: Duration.zero,
          reverseTransitionDuration: Duration.zero,
          pageBuilder: (_, _, _) => PlayerPage(
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
            mixedLibrary: widget.mixedLibrary,
            previewItem: it,
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
    final settings = _btn(
      Icons.settings_outlined,
      tr('player.settings'),
      _showSettings,
    );
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
    // 混合库：列表按钮常驻排在前面（删除按钮在左侧「播放顺序」后面）
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
      // 混合库：列表直接摆在控制栏上，往左靠
      if (widget.mixedLibrary) ?playlist,
      _btn(Icons.more_horiz, tr('common.more'), () {
        _showMore([
          subtitle,
          audio,
          if (!widget.mixedLibrary) ?playlist,
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
        child: Wrap(spacing: 8, runSpacing: 8, children: extras),
      ),
    );
  }

  /// 「删除当前影片」的二次确认是否已被本次登录跳过，以及当时选的回收站设置。
  /// 只存在内存里：重启 App / 重新登录就重新弹。
  static bool _deleteSkipConfirm = false;
  static bool _deleteToTrash = false;

  Future<void> _deleteCurrent() async {
    final id = widget.itemId;
    if (id == null) return;
    var toTrash = _deleteToTrash;
    if (!_deleteSkipConfirm) {
      final picked = await showDialog<({bool toTrash, bool dontAsk})>(
        context: context,
        builder: (_) => _DeleteCurrentDialog(title: widget.title),
      );
      if (picked == null || !mounted) return;
      toTrash = picked.toTrash;
      if (picked.dontAsk) {
        _deleteSkipConfirm = true;
        _deleteToTrash = picked.toTrash;
      }
    }
    if (!mounted) return;
    final ok = await deleteVideoItemsNow(context, [id], toTrash: toTrash);
    if (!ok || !mounted) return;
    final index = _playlist.indexWhere((e) => e.id == id);
    final rest = [..._playlist]..removeWhere((e) => e.id == id);
    setState(() => _playlist = rest);
    if (rest.isEmpty) {
      Navigator.of(context).maybePop();
      return;
    }
    // 删掉当前这条后紧接着播下一条：删除后原位置就是原来的下一条
    final next = rest[(index < 0 ? 0 : index).clamp(0, rest.length - 1)];
    await _playOther(next, popSheet: false);
  }

  Widget _progressRow() => StreamBuilder<Duration>(
    stream: _positionStream,
    builder: (_, pos) => StreamBuilder<Duration>(
      stream: _durationStream,
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
            Text(
              _fmt(Duration(milliseconds: cur)),
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
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
            Text(
              _fmt(d),
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
        );
      },
    ),
  );

  Widget _leftControls(bool wide) => StreamBuilder<bool>(
    stream: _playingStream,
    builder: (_, snap) {
      final playing = snap.data ?? false;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _btn(
            playing ? Icons.pause : Icons.play_arrow,
            playing ? tr('player.pause') : tr('player.play'),
            () => _togglePlay(),
          ),
          // 有播放列表才给「上一集 / 下一集」；没有时这两个位置直接消失，
          // 控制栏不会因为少了按钮而留空。
          if (wide && _hasPlaylist) ...[
            _btn(
              Icons.skip_previous,
              tr('player.prev'),
              () => _playAdjacent(-1),
            ),
            _btn(Icons.skip_next, tr('player.next'), () => _playAdjacent(1)),
          ],
          // 混合库的播放页不要快退 / 快进，位置让给「列表 + 删除」（在右侧按钮组里）
          if (!widget.mixedLibrary) ...[
            _btn(Icons.replay_10, tr('player.rewind10'), () => _seekBy(-10)),
            _btn(Icons.forward_30, tr('player.forward30'), () => _seekBy(30)),
          ],
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
                child: _checked(
                  tr('player.loopSequence'),
                  _loop == PlaylistMode.none && !_shuffle,
                ),
              ),
              PopupMenuItem(
                value: 'single',
                child: _checked(
                  tr('player.loopSingle'),
                  _loop == PlaylistMode.single,
                ),
              ),
              PopupMenuItem(
                value: 'all',
                child: _checked(
                  tr('player.loopAll'),
                  _loop == PlaylistMode.loop && !_shuffle,
                ),
              ),
              PopupMenuItem(
                value: 'shuffle',
                child: _checked(tr('player.loopShuffle'), _shuffle),
              ),
            ],
          ),
          // 混合库：删除当前影片紧跟在「播放顺序」后面
          if (widget.mixedLibrary && widget.itemId != null)
            _btn(
              Icons.delete_outline,
              tr('player.deleteCurrent'),
              _deleteCurrent,
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
            _btn(
              Icons.arrow_back,
              tr('player.back'),
              () => Navigator.of(context).maybePop(),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                widget.title ?? tr('ui.video.001'),
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 15),
              ),
            ),
            if (wide) _btn(Icons.info_outline, tr('player.info'), _showInfo),
            if (wide)
              _btn(Icons.help_outline, tr('player.help'), _showSettings),
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
              if (!widget.mixedLibrary) ...[
                _btn(
                  Icons.replay_30,
                  tr('player.rewind10'),
                  () => _seekBy(-10),
                ),
                const SizedBox(width: 24),
              ],
              StreamBuilder<bool>(
                stream: _playingStream,
                builder: (_, snap) => IconButton(
                  iconSize: 52,
                  icon: Icon(
                    (snap.data ?? false)
                        ? Icons.pause_circle_outline
                        : Icons.play_circle_outline,
                    color: Colors.white,
                  ),
                  onPressed: () {
                    _togglePlay();
                    _poke();
                  },
                ),
              ),
              if (!widget.mixedLibrary) ...[
                const SizedBox(width: 24),
                _btn(
                  Icons.forward_30,
                  tr('player.forward30'),
                  () => _seekBy(30),
                ),
              ],
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
          stream: _positionStream,
          initialData: _playbackPosition,
          builder: (_, snap) {
            final text = activeSubtitleText(
              _cues,
              // 字幕时间是片源时间，会话从中途起转时要加偏移才和画面对得上
              _absPosition(snap.data ?? Duration.zero).inMilliseconds,
            );
            if (text.isEmpty) return const SizedBox.shrink();
            // 字号 / 位置来自 `VideoSubtitlePrefs`（TV 面板可调，默认 1.0 / 底部，
            // 与既有配置完全一致）。位置档 0/1/2 分别再抬高 0 / 90 / 200。
            final scale = VideoSubtitlePrefs.instance.scale;
            final posOffset = switch (VideoSubtitlePrefs.instance.position) {
              1 => 90.0,
              2 => 200.0,
              _ => 0.0,
            };
            return Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: EdgeInsets.only(
                  left: 32,
                  right: 32,
                  bottom: (_controls && !_locked ? 140 : 48) + posOffset,
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
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20 * scale,
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
      // 上下切集进来：整屏已经铺着这一条自己的抽帧，再压一层黑色加载页
      // 就会「图一闪 → 黑一下 → 才出画面」。这里只留一个转圈。
      if (widget.previewItem != null && _showOpeningFrame && _error == null) {
        return const Positioned.fill(
          child: IgnorePointer(
            child: Center(
              child: SizedBox(
                width: 40,
                height: 40,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  color: Colors.white70,
                ),
              ),
            ),
          ),
        );
      }
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
                  // 等超过 8 秒才提一句：这时候是转码任务在排队，不是卡死
                  if (_prepareSeconds >= 8) ...[
                    const SizedBox(height: 6),
                    Text(
                      tr('player.preparingSlow', {
                        'seconds': '$_prepareSeconds',
                      }),
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 12,
                      ),
                    ),
                  ],
                  // 这行「检测到 杜比视界 / HEVC…边转边播」以前常驻加载页，
                  // 用户看到的是一堆看不懂的术语。原因仍然可查：播放信息面板里
                  // 「HDR」那一行就是它。
                  //
                  // 「试试原画」只在真的卡住（90 秒还没起来）时才出现：
                  // 一进来就摆一个「解不了？」的逃生口，会让人以为播放器
                  // 已经判定这部片放不了。
                  if (!_tvMode && _canTryOriginal) ...[
                    const SizedBox(height: NasTokens.spaceMd),
                    OutlinedButton(
                      onPressed: () {
                        _disarmTryOriginal();
                        setState(() => _preparing = false);
                        _openUrl(_directUrl);
                      },
                      child: Text(tr('player.tryOriginal')),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
    }
    if (_switching || _jumping || _seeking || _waitingTarget != null) {
      final String label;
      if (_jumping) {
        label = tr('common.loading');
      } else if (_switching) {
        label = tr('player.switching');
      } else if (_seeking) {
        label = tr('common.loading');
      } else {
        // 目标还没转出来：明确告诉用户「在转，别走」，而不是让画面静静冻着
        label = tr('player.waitingTarget', {'time': _fmt(_waitingTarget!)});
      }
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
                Text(label, style: const TextStyle(color: Colors.white)),
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
    if (_nativeTvActive) {
      // 原生视频层（裸 SurfaceView）由 Activity 垫在 Flutter 下面，这里只占位。
      // 不加 key：换档 / 重开同一页时不要重新挂摘原生视图，否则会黑一下。
      return TvMedia3PlayerSurface(
        controller: _tvMedia3Player,
        onAttached: _onNativeSurfaceAttached,
      );
    }
    return Video(
      controller: _controller,
      controls: null,
      fit: _fit,
      fill: Colors.black,
    );
  }

  /// 跟手切集时补上屏幕空白处的相邻条目封面卡。
  ///
  /// 原生 SurfaceView 在 Flutter 下面，视频往上移走以后露出来的是窗口底色；
  /// 用一张整屏的不透明卡片盖住，观感才是「上一条被推走、下一条跟上来」。
  Widget _swipePreviewLayer() {
    return ValueListenableBuilder<double>(
      valueListenable: _swipeOffset,
      builder: (_, dy, _) {
        if (dy == 0) return const SizedBox.shrink();
        final item = dy < 0 ? _adjacentItem(1) : _adjacentItem(-1);
        if (item == null) return const SizedBox.shrink();
        final h = MediaQuery.sizeOf(context).height;
        final top = dy < 0 ? h + dy : dy - h;
        return Stack(
          children: [
            Positioned(
              top: top,
              left: 0,
              right: 0,
              height: h,
              child: IgnorePointer(
                child: _swipePreviewCard(item, next: dy < 0),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _swipePreviewCard(VideoItem item, {required bool next}) {
    final label = relatedBasename(item.path);
    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 用下一条自己的抽帧铺满整屏：竖屏片源抽出来就是竖屏，和即将起播的
          // 画面同构图。以前用同名横版图 contain 居中，竖屏切换时中间闪一张
          // 横图，割裂感很强。
          VideoFramePreview(item: item),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.center,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Color(0xCC000000)],
              ),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 96),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    tr(next ? 'player.next' : 'player.prev'),
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    label,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_swipeSwitching)
            const Center(
              child: SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(
                  strokeWidth: 2.4,
                  color: Colors.white70,
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 原生 SurfaceView 挂上窗口后，才把整页 / 根背景改成透明。
  void _onNativeSurfaceAttached() {
    if (!mounted || _nativeSurfaceReady) return;
    setState(() => _nativeSurfaceReady = true);
    // 根背景层在 Navigator 下面，必须收起，否则会盖住视频
    nativeVideoLayerActive.value = true;
  }

  /// 错误页上的恢复入口：重新打开当前地址。
  Future<void> _retryPlay() async {
    if (_url.isEmpty) return;
    setState(() => _error = null);
    await _openUrl(_url, retries: 3);
  }

  Future<void> _fallbackToOriginal(
    String requestedCodec, {
    Duration? position,
  }) async {
    if (!mounted) return;
    final itemId = widget.itemId;
    if (_originalFallbackAttempted) return;
    if (itemId == null) {
      if (mounted) {
        setState(() {
          _preparing = false;
          _error = tr('player.originalPlaybackFailed');
        });
      }
      return;
    }
    _originalFallbackAttempted = true;
    _disarmTryOriginal();
    if (_originalFallbackBlockedByColor) {
      if (mounted) {
        setState(() {
          _preparing = false;
          _switching = false;
          _error = tr('player.codecFallbackBlocked');
        });
      }
      ClientLogger.instance.warn(
        '编码 $requestedCodec 不可用，但原片回退受色彩策略阻止',
        route: 'player.fallback',
        detail:
            'toneMapRequired=${PlayPreferences.toneMap && _srcHdr.isHdr} '
            'colorBlocked=$_colorBlocksDirect',
      );
      return;
    }
    if (mounted) {
      setState(() {
        _preparing = false;
        _switching = true;
        _error = null;
      });
    }
    final target = position ?? _absPosition(_playbackPosition);
    final shouldPlay = _wantPlay || _playbackPlaying || _playbackBuffering;
    final processAudio = _audioProcessingRequested || widget.compat == null;
    try {
      _sessionId = null;
      _actualCodec = null;
      _actualToneMap = null;
      _sessionAudioNormalizeEffective = null;
      _jobStatus = null;
      _transcodedMs = 0;
      _startMs = 0;
      _pendingStartMs = null;
      setState(() {
        _codec = 'original';
        _preset = 'original';
        _isTranscode = processAudio;
        _error = null;
      });
      if (processAudio) {
        final url = await _ensureTranscode(
          'original',
          defaultTranscodeCodec(),
          startMs: target.inMilliseconds,
        );
        if (!mounted) return;
        ClientLogger.instance.info(
          '编码 $requestedCodec 不可用，回退到视频原码 / 音频处理会话',
          route: 'player.fallback',
        );
        await _openUrl(url, retries: 3, autoPlay: shouldPlay);
      } else {
        final response = await ApiSession.instance.client.videoStreamUrl(
          id: itemId,
        );
        if (!mounted) return;
        final url = response.url.startsWith('http')
            ? response.url
            : '${ApiSession.instance.baseUrl}${response.url}';
        _directUrl = url;
        ClientLogger.instance.info(
          '编码 $requestedCodec 不可用，尝试原码直连',
          route: 'player.fallback',
          detail: _redactedUrlForLog(url),
        );
        await _openUrl(url, seekTo: target, autoPlay: shouldPlay);
      }
      if (mounted && _error != null) {
        setState(() => _error = tr('player.originalAlsoUnsupported'));
      }
    } catch (e) {
      ClientLogger.instance.error(
        '原片回退失败：${e.runtimeType}',
        route: 'player.fallback',
        detail: 'item=$itemId codec=$requestedCodec',
      );
      if (mounted) {
        setState(() {
          _error = processAudio
              ? tr('player.switchFailed', {'error': '$e'})
              : tr('player.originalPlaybackFailed');
        });
      }
    } finally {
      if (mounted) setState(() => _switching = false);
    }
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
          // 播放失败后错误层会盖住控制栏，恢复入口直接放到错误页上。
          Wrap(
            alignment: WrapAlignment.center,
            spacing: NasTokens.spaceSm,
            children: [
              for (final codec in playableTranscodeCodecs())
                OutlinedButton(
                  onPressed: () => _switchQuality(
                    _transcodeFallback(codec: codec.key),
                    codec: codec.key,
                  ),
                  child: Text(codec.label),
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

  // ---------------------------------------------------------------- TV 控制层
  //
  // 遥控器只有五类键：方向、OK、返回、播放/暂停、快进/快退。这里全部用
  // 「索引式焦点」处理（_tvRow / _tvIndex），不依赖 Flutter 的焦点遍历，
  // 也不依赖控件是否布局在可视区域内 —— 按钮数量随片源变化，靠几何走焦点
  // 会在「有没有上一集」这种差异上直接卡死。

  int get _tvPlayIndex => 0;

  /// TV 按钮上只放「画质」本身（`原画` / `1080P` / `720P`），
  /// 带码率的完整名字留给弹窗（`_tvQualityPanel` 的选项与 hint）。
  String get _tvQualityShort {
    if (_isVideoCopySession || _codec == 'original') {
      return tr('player.tv.original');
    }
    return playQualityPresetOf(_preset)?.label ?? _preset;
  }

  List<_TvAction> _tvActions() {
    final playing = _playbackPlaying;
    return <_TvAction>[
      _TvAction(
        icon: playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
        label: tr(playing ? 'player.pause' : 'player.play'),
        onTap: () {
          _togglePlay();
          _poke();
        },
      ),
      _TvAction(
        icon: Icons.replay_10_rounded,
        // 按钮下面只有一行位置：用短标签，完整语义靠图标 + 弹窗
        label: tr('player.tv.rewind10'),
        onTap: () => _seekBy(-10),
      ),
      _TvAction(
        icon: Icons.forward_30_rounded,
        label: tr('player.tv.forward30'),
        onTap: () => _seekBy(30),
      ),
      if (_hasPlaylist)
        _TvAction(
          icon: Icons.skip_previous_rounded,
          label: tr('player.prev'),
          onTap: () => _playAdjacent(-1),
        ),
      if (_hasPlaylist)
        _TvAction(
          icon: Icons.skip_next_rounded,
          label: tr('player.next'),
          onTap: () => _playAdjacent(1),
        ),
      _TvAction(
        icon: Icons.speed_rounded,
        label: tr('player.speed'),
        onTap: _tvSpeedPanel,
      ),
      _TvAction(
        icon: _activeSub == null ? Icons.subtitles_outlined : Icons.subtitles,
        label: tr('player.subtitle'),
        onTap: _tvSubtitlePanel,
      ),
      _TvAction(
        icon: Icons.audiotrack_outlined,
        label: tr('player.audioTrack'),
        onTap: _tvAudioPanel,
      ),
      _TvAction(
        icon: Icons.hd_outlined,
        // 直接显示当前画质（原画 / 1080P），比写死「画质」有用得多
        label: _tvQualityShort,
        onTap: _tvQualityPanel,
      ),
      _TvAction(
        icon: Icons.info_outline_rounded,
        label: tr('player.tv.info'),
        onTap: _tvInfoPanel,
      ),
    ];
  }

  /// 按钮行里左右移动焦点。进度行的左右是「直接跳时间」，不在这里处理。
  void _tvMove(int dx) {
    final actions = _tvActions();
    final next = (_tvIndex + dx).clamp(0, actions.length - 1);
    if (next != _tvIndex) setState(() => _tvIndex = next);
  }

  /// 返回键语义（TV）：分层返回，逐级退出而不是一下子跳回栏目。
  ///
  /// 顺序：**选项小窗 → 操作栏 → 播放页**。
  /// - 字幕 / 音轨等小窗开着：只关小窗，操作栏保留；
  /// - 操作栏显示着：只收起操作栏，回到全屏观看；
  /// - 都没有了：才真正退出播放页。
  ///
  /// 系统返回（PopScope）和 goBack 键事件可能同一次按键都送到这里，
  /// 150ms 内只算一次，避免「按一下退两层」。
  void _tvBack() {
    final now = DateTime.now();
    final last = _lastTvBackAt;
    if (last != null && now.difference(last).inMilliseconds < 150) return;
    _lastTvBackAt = now;

    // ① 选项小窗开着：关小窗，留在播放页（操作栏该在还在）。
    if (_tvPanelOpen) {
      Navigator.of(context).maybePop();
      return;
    }
    // ② 操作栏显示：收起操作栏，回到全屏观看。
    if (_controls) {
      _hideTimer?.cancel();
      setState(() => _controls = false);
      return;
    }
    // ③ 已经是全屏、且没有小窗：退出播放页。
    _allowPop = true;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).maybePop();
    });
  }

  DateTime? _lastTvBackAt;

  /// TV 遥控器的五类键：
  ///
  /// - 没有操作栏时：OK = 暂停 / 继续，左右 = 直接跳时间，下 = 唤出操作栏；
  /// - 操作栏显示时：默认落在进度行（左右依然是跳时间，OK 收起操作栏）；
  ///   再按一次下进入按钮行，左右选字幕 / 音轨 / 画质等，OK 执行选中的按钮，
  ///   上从按钮行回到进度行、进度行再往上收起操作栏；
  /// - 返回：分层——先关选项小窗，再收操作栏，都没有才退出播放页（见 [_tvBack]）。
  KeyEventResult _onTvKey(KeyEvent event) {
    if (event is KeyUpEvent) {
      // 长按拖动：松开左右键才提交 seek。
      if (_tvHoldDir != 0 &&
          (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
              event.logicalKey == LogicalKeyboardKey.arrowRight)) {
        _commitTvHold();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    final k = event.logicalKey;

    final isOk =
        k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.numpadEnter ||
        k == LogicalKeyboardKey.select ||
        k == LogicalKeyboardKey.gameButtonA ||
        k == LogicalKeyboardKey.space;
    final isBack =
        k == LogicalKeyboardKey.escape ||
        k == LogicalKeyboardKey.backspace ||
        k == LogicalKeyboardKey.goBack ||
        k == LogicalKeyboardKey.browserBack;

    if (isBack) {
      _tvBack();
      return KeyEventResult.handled;
    }

    // 媒体键：不管控制层在不在都直接生效（电视遥控器最爱用这两个）
    if (k == LogicalKeyboardKey.mediaPlayPause) {
      _togglePlay();
      _poke();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.mediaFastForward) {
      _seekBy(30);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.mediaRewind) {
      _seekBy(-10);
      return KeyEventResult.handled;
    }

    final left = k == LogicalKeyboardKey.arrowLeft;
    final right = k == LogicalKeyboardKey.arrowRight;
    final up = k == LogicalKeyboardKey.arrowUp;
    final down = k == LogicalKeyboardKey.arrowDown;

    if (!_controls) {
      if (left || right) {
        // 左右就是跳时间：不唤出操作栏，用画面中央的快进/快退提示给反馈。
        // 短按立即 ±30s / ±10s；按住超过 420ms 升级为加速拖动（松开才落地），
        // 长按产生的 repeat 一律忽略，交给定时器驱动。
        if (event is KeyDownEvent) {
          _beginTvHold(left ? -1 : 1);
          _seekBy(left ? -10 : 30);
        }
        return KeyEventResult.handled;
      }
      if (up || down) {
        // 下唤出操作栏（上也可以），先落在进度行：左右仍然能跳时间。
        setState(() {
          _controls = true;
          _tvRow = 0;
          _tvIndex = _tvPlayIndex;
        });
        _resetHideTimer();
        return KeyEventResult.handled;
      }
      if (isOk) {
        _togglePlay();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    if (left || right) {
      if (_tvRow == 0) {
        // 进度行：短按跳时间，长按加速拖动（与控件隐藏时同一套语义）。
        if (event is KeyDownEvent) {
          _beginTvHold(left ? -1 : 1);
          _seekBy(left ? -10 : 30);
        }
      } else if (event is KeyDownEvent || event is KeyRepeatEvent) {
        _tvMove(left ? -1 : 1);
      }
      return KeyEventResult.handled;
    }
    if (down) {
      // 进度行 → 按钮行；按钮行已经是最后一行。
      if (_tvRow == 0) {
        setState(() {
          _tvRow = 1;
          _tvIndex = _tvPlayIndex;
        });
      }
      return KeyEventResult.handled;
    }
    if (up) {
      if (_tvRow == 1) {
        setState(() {
          _tvRow = 0;
        });
      } else {
        _hideTimer?.cancel();
        setState(() => _controls = false);
      }
      return KeyEventResult.handled;
    }
    if (isOk) {
      if (_tvRow == 0) {
        // 进度行按确定：收起操作栏，继续沉浸观看。
        _hideTimer?.cancel();
        setState(() {
          _controls = false;
        });
      } else {
        final actions = _tvActions();
        if (_tvIndex >= 0 && _tvIndex < actions.length) {
          actions[_tvIndex].onTap();
        }
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Widget _tvTopBar() {
    final m = TvLayout.of(context);
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: m.px(24), vertical: m.px(16)),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xB3000000), Color(0x00000000)],
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: Row(
            children: [
              Icon(
                Icons.arrow_back_rounded,
                color: Colors.white,
                size: m.px(26),
              ),
              SizedBox(width: m.px(10)),
              Expanded(
                child: Text(
                  widget.title ?? tr('ui.video.001'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: m.px(24),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                tr('tv.player.hint'),
                style: TextStyle(color: Colors.white54, fontSize: m.px(13)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tvBottomBar() {
    final m = TvLayout.of(context);
    final actions = _tvActions();
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        // 上边距收一点、进度条与按钮之间也收紧：整块变矮后进度条自然落到更低的位置，
        // 四种屏宽（1280/1920/2560/3840）都是同一套比例，不会一边贴死一边留白。
        padding: EdgeInsets.fromLTRB(m.px(24), m.px(26), m.px(24), m.px(16)),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [Color(0xD9000000), Color(0x00000000)],
          ),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _tvProgress(),
              SizedBox(height: m.px(8)),
              TvPlayerBar(
                focusedIndex: _tvRow == 1 ? _tvIndex : -1,
                itemWidth: m.px(88),
                gap: m.px(10),
                buttons: [
                  for (var i = 0; i < actions.length; i += 1)
                    TvPlayerButton(
                      icon: actions[i].icon,
                      label: actions[i].label,
                      size: m.px(88),
                      highlighted: _tvRow == 1 && _tvIndex == i,
                      onTap: () {
                        setState(() {
                          _tvRow = 1;
                          _tvIndex = i;
                        });
                        actions[i].onTap();
                      },
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tvProgress() {
    return StreamBuilder<Duration>(
      stream: _positionStream,
      initialData: _playbackPosition,
      builder: (_, snap) {
        final total = _timelineDuration(_playbackDuration);
        final totalMs = total.inMilliseconds;
        double frac(Duration d) =>
            totalMs <= 0 ? 0 : (d.inMilliseconds / totalMs).clamp(0.0, 1.0);
        final abs = _absPosition(snap.data ?? Duration.zero);
        final played = frac(abs);
        return TvPlayerProgress(
          progress: played,
          loaded: _isTranscode ? frac(_loadedEnd) : null,
          // 长按左右键拖动时，进度条上直接标出目标位置。
          seekTarget: _tvHoldActive ? frac(_tvHoldTarget) : null,
          highlighted: _tvRow == 0,
          leftLabel: _fmt(_tvHoldActive ? _tvHoldTarget : abs),
          rightLabel: _fmt(total),
        );
      },
    );
  }

  /// 长按遥控器左右键拖动时的最小反馈：底部只出一条进度条，
  /// 不出现顶栏和按钮行（那会打断拖动本身）。
  Widget _tvSeekOverlay() {
    final m = TvLayout.of(context);
    final total = _timelineDuration(_playbackDuration);
    final totalMs = total.inMilliseconds;
    double frac(Duration d) =>
        totalMs <= 0 ? 0 : (d.inMilliseconds / totalMs).clamp(0.0, 1.0);
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: IgnorePointer(
        child: Container(
          padding: EdgeInsets.fromLTRB(
            m.px(24),
            m.px(26),
            m.px(24),
            m.px(16),
          ),
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [Color(0xD9000000), Color(0x00000000)],
            ),
          ),
          child: SafeArea(
            top: false,
            child: TvPlayerProgress(
              progress: frac(_absPosition(_playbackPosition)),
              loaded: _isTranscode ? frac(_loadedEnd) : null,
              seekTarget: frac(_tvHoldTarget),
              highlighted: true,
              leftLabel: _fmt(_tvHoldTarget),
              rightLabel: _fmt(total),
            ),
          ),
        ),
      ),
    );
  }

  /// 片源 / 播放信息（TV 面板版）。键 → 值两列网格，遥控器上下左右都能翻。
  List<TvPanelOption> _tvInfoOptions() {
    final c = widget.compat ?? const <String, dynamic>{};
    String v(dynamic x) => x == null || '$x'.isEmpty ? '—' : '$x';
    final srcKbps = sourceKbpsOf(
      widget.sourceBytes ?? 0,
      widget.durationMs ?? 0,
    );
    final tgtKbps =
        playQualityPresetOf(_preset)?.bitrateFor(_actualCodec ?? _codec) ?? 0;
    String row(String k, String val) => '$k|$val';
    final pairs = <String>[
      row(
        tr('player.playbackSource'),
        _isVideoCopySession
            ? _copySessionLabel
            : _isTranscode
            ? tr('player.sourceTranscode')
            : tr('player.sourceDirect'),
      ),
      if (_isTranscode) row(tr('player.transcodeState'), _jobStateText),
      row(
        tr('player.bitrate'),
        _isTranscode && tgtKbps > 0
            ? tr('player.rateTo', {
                'from': mbpsLabel(srcKbps),
                'to': mbpsLabel(tgtKbps),
              })
            : mbpsLabel(srcKbps),
      ),
      row(
        tr('player.quality'),
        playQualityPresetOf(_preset)?.labelFor(_actualCodec ?? _codec) ??
            _preset,
      ),
      row(tr('player.videoCodec'), _sourceCodecLabel(c['videoCodec'])),
      row(tr('player.audioCodec'), v(c['audioCodec'])),
      row(
        tr('player.resolution'),
        c['width'] == null ? '—' : '${c['width']} × ${v(c['height'])}',
      ),
      row(
        tr('player.hdr'),
        _srcHdr == HdrLevel.none
            ? 'SDR'
            : tr('player.reason.${_srcHdr.reason}'),
      ),
      row(
        tr('player.tv.hdrCapability'),
        _display.known
            ? (_display.maxHdr == HdrLevel.none
                  ? tr('player.tv.hdrNone')
                  : tr('player.reason.${_display.maxHdr.reason}'))
            : tr('player.tv.hdrUnknown'),
      ),
      row(tr('player.renderer'), _rendererSummary),
      row(
        tr('player.toneMap'),
        _srcHdr.isHdr ? tr('player.on') : tr('player.off'),
      ),
      row(tr('player.hdrDirect'), _directStatusText),
      row(
        tr('player.dvDirect'),
        _srcHdr == HdrLevel.dolbyVision ? _directStatusText : '—',
      ),
    ];
    return [
      for (final p in pairs)
        TvPanelOption(
          value: '__info',
          label: p.split('|').first,
          subtitle: p.split('|').last,
        ),
    ];
  }

  /// 统一的电视选项小窗入口：包一层 `_tvPanelOpen` 标志，返回键才能先关小窗。
  Future<String?> _showTvPanel(
    BuildContext _, {
    required String title,
    required List<TvPanelOption> options,
    String? hint,
    String? status,
    int columns = 3,
  }) async {
    _tvPanelOpen = true;
    try {
      return await TvPlayerPanel.show(
        context,
        title: title,
        options: options,
        hint: hint,
        status: status,
        columns: columns,
      );
    } finally {
      _tvPanelOpen = false;
    }
  }

  Future<void> _tvInfoPanel() async {
    await _showTvPanel(
      context,
      title: tr('player.mediaInfo'),
      options: _tvInfoOptions(),
      columns: 2,
    );
    _poke();
  }

  Future<void> _tvSpeedPanel() async {
    const speeds = <double>[0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
    final picked = await _showTvPanel(
      context,
      title: tr('player.speed'),
      options: [
        for (final s in speeds)
          TvPanelOption(
            value: '$s',
            label: s == 1.0 ? '1.0x' : '${s}x',
            selected: (_rate - s).abs() < 0.001,
          ),
      ],
      columns: 3,
    );
    if (picked == null) return;
    final v = double.tryParse(picked);
    if (v != null) await _setRate(v);
    _poke();
  }

  Future<void> _tvSubtitlePanel() async {
    final options = <TvPanelOption>[
      TvPanelOption(
        value: VideoSubtitlePrefs.off,
        label: tr('ui.video.023'),
        selected: _activeSub == null,
      ),
      for (final sub in _subs)
        TvPanelOption(
          value: sub.name,
          label: _subLabel(sub),
          selected: _activeSub == sub.name,
        ),
      TvPanelOption(
        value: '__size-',
        label: tr('player.tv.subtitleSmaller'),
        subtitle: '${(VideoSubtitlePrefs.instance.scale * 100).round()}%',
      ),
      TvPanelOption(
        value: '__size+',
        label: tr('player.tv.subtitleLarger'),
        subtitle: '${(VideoSubtitlePrefs.instance.scale * 100).round()}%',
      ),
      for (var i = 0; i < 3; i += 1)
        TvPanelOption(
          value: '__pos$i',
          label: tr('player.tv.subtitlePos.$i'),
          selected: VideoSubtitlePrefs.instance.position == i,
        ),
    ];
    final picked = await _showTvPanel(
      context,
      title: tr('player.tv.subtitleTitle'),
      options: options,
      columns: 3,
    );
    if (picked == null) return;
    switch (picked) {
      case '__size-':
        await VideoSubtitlePrefs.instance.setScale(
          VideoSubtitlePrefs.instance.scale - 0.1,
        );
        if (mounted) setState(() {});
        break;
      case '__size+':
        await VideoSubtitlePrefs.instance.setScale(
          VideoSubtitlePrefs.instance.scale + 0.1,
        );
        if (mounted) setState(() {});
        break;
      case '__pos0':
      case '__pos1':
      case '__pos2':
        await VideoSubtitlePrefs.instance.setPosition(
          int.parse(picked.substring(5)),
        );
        if (mounted) setState(() {});
        break;
      case VideoSubtitlePrefs.off:
        await _chooseSubtitle(VideoSubtitlePrefs.off, null);
        break;
      default:
        final file = _findSub(picked);
        await _chooseSubtitle(file?.lang ?? VideoSubtitlePrefs.auto, file);
    }
    _poke();
  }

  Future<void> _tvAudioPanel() async {
    final tracks = _player.state.tracks.audio;
    final source = _audioTracks;
    final options = <TvPanelOption>[
      if (source.isNotEmpty)
        for (final t in source)
          TvPanelOption(
            value: '${t.index}',
            label: _audioTrackLabel(t, t.index),
            selected: _audioIndex == t.index,
          )
      else
        for (var i = 0; i < tracks.length; i += 1)
          TvPanelOption(
            value: '$i',
            label:
                tracks[i].title ??
                tracks[i].language ??
                tr('player.audioTrack'),
            selected: _audioIndex == i,
          ),
      if (source.isEmpty && tracks.isEmpty)
        TvPanelOption(value: '__none', label: tr('player.noAudioTracks')),
    ];
    final picked = await _showTvPanel(
      context,
      title: tr('player.audioTrack'),
      options: options,
      columns: 2,
    );
    final i = int.tryParse(picked ?? '');
    if (i == null) return;
    await _selectAudio(i);
    _poke();
  }

  Future<void> _tvQualityPanel() async {
    final qualityCodec = _codec == 'original'
        ? defaultTranscodeCodec()
        : _codec;
    final options = presetsForSource(_srcHeight).where((p) => !p.copy).toList();
    final picked = await _showTvPanel(
      context,
      title: tr('player.quality'),
      options: [
        for (final p in options)
          TvPanelOption(
            value: p.key,
            label: p.labelFor(qualityCodec),
            selected: _preset == p.key,
          ),
      ],
      hint: tr('player.qualityHint', {
        'preset': _isVideoCopySession
            ? _copySessionLabel
            : _codec == 'original'
            ? tr('player.sourceDirect')
            : playQualityPresetOf(_preset)?.labelFor(qualityCodec) ?? _preset,
      }),
      columns: 3,
    );
    if (picked == null || picked == _preset) return;
    await _switchQuality(picked);
    _poke();
  }

  Widget _noticeLayer() {
    final text = _notice;
    if (text == null) return const SizedBox.shrink();
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        bottom: false,
        child: Center(
          child: Container(
            margin: const EdgeInsets.only(top: 66),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            constraints: const BoxConstraints(maxWidth: 720),
            decoration: BoxDecoration(
              color: const Color(0xE6262626),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.white24),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.info_outline_rounded,
                  color: Colors.white70,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    text,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 页面重新回到最上层时收回原生视频层的所有权（换集新页面已销毁的场景）
    if (ModalRoute.of(context)?.isCurrent ?? true) _tvMedia3Player.claim();
    final tv = TvScope.of(context);
    final wide = MediaQuery.sizeOf(context).width >= 720;
    return PopScope(
      // TV：返回键直接退出播放页（见 _tvBack）
      canPop: _allowPop || !tv,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && tv) _tvBack();
      },
      child: Focus(
        autofocus: true,
        onKeyEvent: (node, event) {
          final result = tv ? _onTvKey(event) : _onKey(node, event);
          // TV 上任何一次按键都算「还在操作」，重新计时自动隐藏
          if (tv && result == KeyEventResult.handled && _controls) {
            _resetHideTimer();
          }
          return result;
        },
        child: Scaffold(
          // 原生 SurfaceView 真正挂上之前保持黑底：窗口此时还是半透明的，
          // 过早露出会闪到手机桌面。挂上后整页透明，视频从下面露出来；
          // 黑边由原生 PlayerView 的黑底提供。
          backgroundColor: _nativeTvActive && _nativeSurfaceReady
              ? Colors.transparent
              : Colors.black,
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
                    // 手机：双击 = 播放 / 暂停；桌面 / Web：双击 = 全屏
                    onDoubleTap: _phoneGestures
                        ? _onPhoneDoubleTap
                        : _onDoubleTap,
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
                      _playbackSetRate(2.0);
                      setState(() {});
                    },
                    onLongPressEnd: (_) {
                      _boosting = false;
                      _playbackSetRate(_rate);
                      setState(() {});
                    },
                    child: ValueListenableBuilder<double>(
                      valueListenable: _swipeOffset,
                      builder: (_, dy, child) {
                        // 安卓画面在原生层上，已经由 setOffset 平移；这里只搬 Flutter 画面
                        if (_nativeTvActive || dy == 0) return child!;
                        return Transform.translate(
                          offset: Offset(0, dy),
                          child: child,
                        );
                      },
                      child: _videoSurface(),
                    ),
                  ),
                ),
              ),
              // 跟手切集时，屏幕剩下的部分由相邻条目的封面卡补上（不接手势）
              _swipePreviewLayer(),
              // 换集进场：新页面一出来就铺上这一条自己的抽帧（和上一页滑走的
              // 那张是同一张图，缓存命中不闪），等真正解出第一帧再撤掉。
              if (widget.previewItem != null &&
                  _showOpeningFrame &&
                  _error == null)
                Positioned.fill(
                  child: IgnorePointer(
                    child: VideoFramePreview(item: widget.previewItem!),
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
                  if (tv) _tvTopBar() else _topBar(wide),
                  if (!tv) _centerControls(wide),
                  if (tv) _tvBottomBar() else _bottomBar(wide),
                ],
                // 长按遥控器左右键拖动进度：只出底部一条进度条，不弹操作区。
                if (_tvHoldActive && !_controls) _tvSeekOverlay(),
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
              // 提示条放在最上层：全屏 / 控件隐藏时也要看得见
              _noticeLayer(),
            ],
          ),
        ),
      ),
    );
  }
}

/// 混合库播放页「删除当前影片」的二次确认。
///
/// 默认不勾选回收站（和其他影视删除一致）；勾选「不再提示」后，
/// 本次登录内再删就按这次的选择直接删，不再弹窗。
class _DeleteCurrentDialog extends StatefulWidget {
  const _DeleteCurrentDialog({this.title});

  final String? title;

  @override
  State<_DeleteCurrentDialog> createState() => _DeleteCurrentDialogState();
}

class _DeleteCurrentDialogState extends State<_DeleteCurrentDialog> {
  bool _toTrash = false;
  bool _dontAsk = false;

  @override
  Widget build(BuildContext context) {
    final title = widget.title;
    return AlertDialog(
      title: Text(tr('player.deleteCurrent')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null && title.isNotEmpty) ...[
            Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 6),
          ],
          CheckboxListTile(
            value: _toTrash,
            onChanged: (v) => setState(() => _toTrash = v ?? false),
            title: Text(tr('video.dup.toTrash')),
            subtitle: Text(tr('video.dup.toTrashHint')),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            dense: true,
          ),
          if (!_toTrash)
            Text(
              tr('video.delete.permanentHint'),
              style: TextStyle(
                fontSize: NasTokens.fontCaption,
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          CheckboxListTile(
            value: _dontAsk,
            onChanged: (v) => setState(() => _dontAsk = v ?? false),
            title: Text(tr('player.deleteDontAsk')),
            subtitle: Text(tr('player.deleteDontAskHint')),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            dense: true,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr('common.cancel')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            (toTrash: _toTrash, dontAsk: _dontAsk),
          ),
          child: Text(tr('common.delete')),
        ),
      ],
    );
  }
}

/// TV 控制层的一个动作（图标 + 文案 + 回调）。
class _TvAction {
  const _TvAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
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
      Paint()
        ..color = sliderTheme.inactiveTrackColor ?? const Color(0x3DFFFFFF),
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
