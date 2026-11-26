import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:nas_core/nas_core.dart';

import '../../core/android_notification_permission.dart';
import '../../core/audio_background.dart';
import '../../core/audio_fade.dart';
import '../../core/audio_focus.dart';
import '../../core/client_log.dart';
import '../../core/session.dart';
import '../music/media_session.dart';

/// 播放来源：AI 新闻（服务端生成的 mp3）与本地博客（用户目录里的音频）。
///
/// 队列结构相同（[BlogEpisodeItem]），差异只在取播放地址与播放页是否展示文章区。
enum BlogPlaybackKind { aiNews, localBlog }

/// 接口返回的封面 / 音频地址是相对路径（令牌放在 query 里），
/// `Image.network` / media_kit 需要绝对地址，这里统一拼上服务端根地址。
String? blogMediaUrl(String? url) {
  if (url == null || url.isEmpty) return null;
  if (url.startsWith('http://') || url.startsWith('https://')) return url;
  return '${ApiSession.instance.baseUrl}$url';
}

/// AI 新闻的**全局**播放器。
///
/// 不复用 `MusicPlaybackService`：那个服务的队列是 `MusicTrack`，走曲库 stream 路由；
/// 播客 mp3 在数据目录里，硬塞进音乐队列会冲掉用户的歌单。
///
/// 为什么是单例（2026-11-06）：以前它是页面 State 的成员，页面重建 / 热重载时
/// 旧的 media_kit Player（Web 端是一个挂在 globalContext 里的 `<video>` 元素）来不及
/// dispose，会继续出声；新页面又建一个 Player，就成了「两路音频同时播」。
/// 现在播放器与页面生命周期解耦：切模块、最小化、熄屏都不断，全应用也只有这一个实例。
class BlogPlayer extends ChangeNotifier {
  BlogPlayer._();

  static final BlogPlayer instance = BlogPlayer._();

  Player? _player;

  /// 起停淡入淡出：切换音源（播客 ↔ 音乐）时硬切会有一声爆音。
  AudioFader? _fader;

  final List<StreamSubscription<Object?>> _subs = [];

  /// 停播看门狗：mpv 对「长连接被对方关掉、又不再续传」不会报错，也不会自己
  /// 重连，表现就是播到某个位置后彻底安静、界面上还显示「正在播放」。
  /// 2026-11-20 早上的实测：08:27 开播，那条 206 请求 6.8 秒就被断开，
  /// 之后 20 分钟一个请求都没有，26 分钟的一期播到 20 分钟处停死。
  Timer? _watchdog;
  Duration _lastProgress = Duration.zero;
  DateTime _lastProgressAt = DateTime.now();

  /// 连续失败次数。**位置一旦真的往前走了就清零**，所以正常播放期间恒为 0，
  /// 只有「一直播不动」才会累加。
  int _retryAttempt = 0;
  Timer? _retryTimer;

  /// 用户明确停过（停止 / 清队列）。置位后不再自动重连，避免「已经关了还自己响」。
  bool _stopped = false;
  bool _recovering = false;

  static const Duration _stallCheckInterval = Duration(seconds: 5);
  static const Duration _stallThreshold = Duration(seconds: 20);

  /// 断流后的退避序列。
  ///
  /// 为什么不是「一断就报错」（2026-11-22 用户反馈「播两三分钟就停，弹
  /// ClientException with SocketException」）：日志里那段时间确实在重连
  /// （21:28:36 起播 → 21:30:48 → 21:31:22 → 21:35:14），每次都是**新的流地址**，
  /// 说明是连接中途断掉；而重连那一刻连 `blogAudioUrl` 本身都抛 SocketException，
  /// 即手机侧网络瞬时不可用。这种抖动通常几秒就恢复，一上来就报错等于把这一期判死。
  /// 6 次退避合计约 1 分半，足够跨过 WiFi 重连 / 熄屏省电切网。
  static const List<Duration> _retryBackoff = <Duration>[
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
    Duration(seconds: 15),
    Duration(seconds: 30),
    Duration(seconds: 30),
  ];

  /// 当前播放队列（可编辑：加入 / 移除 / 跳转）。
  List<BlogEpisodeItem> _queue = const [];

  /// 列表页给出的全部已完成期次：播放列表弹层「添加期次」从这里挑。
  List<BlogEpisodeItem> _library = const [];

  int _index = -1;

  /// 当前队列属于哪个二级入口。播放页据此决定是否展示新闻稿 / 文章区。
  BlogPlaybackKind _kind = BlogPlaybackKind.aiNews;
  BlogPlaybackKind get kind => _kind;

  Duration position = Duration.zero;
  Duration duration = Duration.zero;
  bool playing = false;
  bool loading = false;
  String? error;
  double rate = 1;

  /// 音量（media_kit 的 0~100）。淡入淡出只临时改播放器音量，
  /// 这里单独记住用户目标值，避免淡入结束后回到旧音量。
  double _volume = 100;
  double get volume => _volume;
  bool get muted => _volume <= 0;

  /// 本地博客进度上报节流：位置 / 时间任一维度走够 15s 才上报一次
  static const Duration _progressReportInterval = Duration(seconds: 15);
  DateTime? _lastReportAt;
  int _lastReportPosMs = -1;
  bool _reportedListened = false;
  String? _progressEpisodeId;

  List<BlogEpisodeItem> get queue => _queue;
  List<BlogEpisodeItem> get library => _library;
  int get index => _index;

  BlogEpisodeItem? get episode =>
      _index >= 0 && _index < _queue.length ? _queue[_index] : null;

  String? get episodeId => episode?.id;

  bool isCurrent(String id) => episode?.id == id;

  bool inQueue(String id) => _queue.any((e) => e.id == id);

  Player _ensure() {
    final existing = _player;
    if (existing != null) return existing;
    final p = Player();
    _subs.add(p.stream.position.listen((v) {
      position = v;
      // 只有真的往前走了才算「活着」：暂停、拖动时位置本来就不动
      if (v > _lastProgress + const Duration(milliseconds: 300)) {
        _lastProgress = v;
        _lastProgressAt = DateTime.now();
        // 真的往前走了 = 这一路已经活了，把退避计数和残留错误一起清掉
        _resetRetry();
        if (error != null) error = null;
      }
      // 锁屏面板的进度：只有活跃音源能写，别把音乐的系统面板抢过来
      if (AudioFocus.instance.holds(this)) {
        if (kIsWeb) {
          updateMediaSessionPosition(duration: duration, position: position);
        } else {
          // 原生端走前台服务；内部按 900ms 节流，不会每 100ms 刷一次通知
          _syncMediaSession();
        }
      }
      // 本地博客：把断点报给服务端，90% 由服务端标记为已听
      _reportProgress();
      notifyListeners();
    }));
    _subs.add(p.stream.duration.listen((v) {
      duration = v;
      _syncMediaSession();
      notifyListeners();
    }));
    _subs.add(p.stream.playing.listen((v) {
      playing = v;
      // 从暂停恢复的那一刻重新起算：暂停期间位置不动是用户意愿，
      // 不重置的话恢复播放会立刻被看门狗判成「卡死」。
      if (v) _lastProgressAt = DateTime.now();
      _syncMediaSession();
      notifyListeners();
    }));
    _subs.add(p.stream.completed.listen((done) {
      if (done) {
        // 播完也算听到 100%：先把进度落库，再切下一期
        _reportProgress(force: true, at: duration);
        unawaited(next());
      }
    }));
    _subs.add(p.stream.error.listen(_handleStreamError));
    _player = p;
    _fader = AudioFader(p);
    _startWatchdog();
    return p;
  }

  void _startWatchdog() {
    _watchdog?.cancel();
    _lastProgress = position;
    _lastProgressAt = DateTime.now();
    _watchdog = Timer.periodic(_stallCheckInterval, (_) => _checkStall());
  }

  void _checkStall() {
    if (_recovering || loading || error != null) return;
    if (!playing || _player == null) return;
    if (duration <= Duration.zero) return;
    if (episode == null) return;
    if (DateTime.now().difference(_lastProgressAt) < _stallThreshold) return;
    _scheduleRetry('停滞 ${_stallThreshold.inSeconds}s');
  }

  /// 流中途报错（连接被重置 / SocketException）不等于这一期坏了。
  ///
  /// 以前这里直接把 error 抛到界面，而 [_checkStall] 又以 `error != null` 提前
  /// 返回 —— 一次瞬时断网就让播放永久停住，看起来就是「播到一半忽然停了还报错」。
  /// 现在改成交给 [_scheduleRetry]，退避重连、位置接上，只有连续失败才认栽。
  void _handleStreamError(String message) {
    loading = false;
    notifyListeners();
    _scheduleRetry('stream.error: $message');
  }

  void _resetRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _retryAttempt = 0;
  }

  /// 失败后按退避序列排一次续播；次数用尽才把错误交给界面。
  void _scheduleRetry(String reason) {
    if (_stopped) return;
    if (episode == null) {
      error = reason;
      loading = false;
      notifyListeners();
      return;
    }
    // 已经在等下一次重连了，别重复排（看门狗每 5s 一拍，会一直撞到这里）
    if (_retryTimer?.isActive ?? false) return;
    if (_retryAttempt >= _retryBackoff.length) {
      playing = false;
      loading = false;
      error = I18n.instance.tr('blog.loadFailed');
      notifyListeners();
      ClientLogger.instance.warn(
        '播客重连 ${_retryBackoff.length} 次仍失败，停止',
        route: 'blog.player/${episodeId ?? '-'}',
        detail:
            'pos=${position.inMilliseconds}ms dur=${duration.inMilliseconds}ms '
            'reason=$reason',
      );
      return;
    }
    final delay = _retryBackoff[_retryAttempt];
    _retryAttempt += 1;
    // 界面上只显示「加载中」，不弹红色错误：多数抖动会在 1~2 次内恢复
    loading = true;
    notifyListeners();
    ClientLogger.instance.warn(
      '播客断流，${delay.inSeconds}s 后第 $_retryAttempt/${_retryBackoff.length} 次重连',
      route: 'blog.player/${episodeId ?? '-'}',
      detail:
          'pos=${position.inMilliseconds}ms dur=${duration.inMilliseconds}ms '
          'playing=$playing reason=$reason',
    );
    _retryTimer = Timer(delay, () => unawaited(_retryNow()));
  }

  /// 重新取一次播放地址，从当前位置续上。
  ///
  /// 必须重走 `blogAudioUrl`：URL 里带的是短期令牌，前一次链接可能早就过了有效期，
  /// 拿旧地址重试只会 401。
  Future<void> _retryNow() async {
    if (_recovering || episode == null) return;
    _recovering = true;
    final at = position;
    try {
      await _load(resumeAt: at);
    } catch (e) {
      _scheduleRetry('load 抛错: $e');
    } finally {
      _recovering = false;
      _lastProgress = position;
      _lastProgressAt = DateTime.now();
    }
  }

  /// 上报本地博客播放进度（只对本地博客；AI 新闻有自己的服务端记录）。
  ///
  /// 节流口径：位置 / 墙钟任一走够 15s 才发一次；跨过 90% 时强制立刻发一次，
  /// 保证「听完」标签及时落库。上报失败静默重试（下一次节流点还会再报）。
  void _reportProgress({bool force = false, Duration? at}) {
    if (_kind != BlogPlaybackKind.localBlog) return;
    final source = episode?.sourcePath;
    if (source == null || source.isEmpty) return;
    final total = duration.inMilliseconds;
    if (total <= 0) return;
    final pos = (at ?? position).inMilliseconds.clamp(0, total);
    final ratio = pos / total;
    final crossed = ratio >= 0.9 && !_reportedListened;
    if (crossed) _reportedListened = true;
    final now = DateTime.now();
    final last = _lastReportAt;
    if (!force &&
        !crossed &&
        last != null &&
        now.difference(last) < _progressReportInterval &&
        (pos - _lastReportPosMs).abs() < _progressReportInterval.inMilliseconds) {
      return;
    }
    _lastReportAt = now;
    _lastReportPosMs = pos;
    unawaited(() async {
      try {
        await ApiSession.instance.client.blogLocalProgress(
          body: BlogLocalProgressBody(
            path: source,
            positionMs: pos,
            durationMs: total,
          ),
        );
      } catch (_) {
        // 断网 / 服务端忙碌：不打扰播放，下一次节流点再报
      }
    }());
  }

  /// 只暂停，不释放资源：交给 AudioFocus 在别的音源开播时调用。
  ///
  /// 先淡出再暂停：直接硬切会在切换音源时留下一声爆音（用户听感像打碟）。
  Future<void> pause() async {
    final fader = _fader;
    if (fader != null) {
      await fader.fadeOutAndPause();
    } else {
      await _player?.pause();
    }
    playing = false;
    notifyListeners();
    _reportProgress(force: true);
  }

  /// 播放某一期：默认把列表里的全部已完成期次当成队列（自动连播）。
  /// [queue] 同时进 `_library`，播放列表弹层可以再把其它期次加进来。
  /// [startAt] 用于「继续播放」：从上次断点起播。
  Future<void> play(
    BlogEpisodeItem target,
    List<BlogEpisodeItem> queue, {
    BlogPlaybackKind kind = BlogPlaybackKind.aiNews,
    Duration? startAt,
  }) async {
    final playable = queue.where((e) => e.status == 'done').toList(growable: false);
    if (playable.isEmpty) return;
    // 换期前把上一期听到哪了落库（否则用户点另一条就丢了断点）
    if (episode != null) _reportProgress(force: true);
    _kind = kind;
    _library = playable;
    _queue = playable;
    _index = playable.indexWhere((e) => e.id == target.id).clamp(0, playable.length - 1);
    await _load(resumeAt: startAt);
  }

  /// 追加到队尾；队列空时直接开播，不冲掉已有的 `_library`。
  Future<void> enqueue(BlogEpisodeItem ep) async {
    if (ep.status != 'done' || inQueue(ep.id)) return;
    if (_queue.isEmpty) {
      _queue = [ep];
      _index = 0;
      await _load();
      return;
    }
    _queue = [..._queue, ep];
    notifyListeners();
  }

  /// 插到当前期后面（下一期就放它）。
  Future<void> enqueueNext(BlogEpisodeItem ep) async {
    if (ep.status != 'done') return;
    if (_queue.isEmpty) {
      _queue = [ep];
      _index = 0;
      await _load();
      return;
    }
    final existing = _queue.indexWhere((e) => e.id == ep.id);
    final next = [..._queue];
    if (existing >= 0) next.removeAt(existing);
    final at = (_index + 1).clamp(0, next.length);
    next.insert(at, ep);
    _queue = next;
    if (existing >= 0 && existing < _index) _index -= 1;
    notifyListeners();
  }

  Future<void> jumpTo(int i) async {
    if (i < 0 || i >= _queue.length) return;
    if (i != _index) _reportProgress(force: true);
    _index = i;
    await _load();
  }

  Future<void> removeAt(int i) async {
    if (i < 0 || i >= _queue.length) return;
    if (_queue.length == 1) {
      await clearQueue();
      return;
    }
    final next = [..._queue]..removeAt(i);
    _queue = next;
    if (i < _index) {
      _index -= 1;
      notifyListeners();
      return;
    }
    if (i == _index) {
      _index = _index.clamp(0, next.length - 1);
      await _load();
      return;
    }
    notifyListeners();
  }

  Future<void> clearQueue() async {
    _reportProgress(force: true);
    await _player?.stop();
    _queue = const [];
    _index = -1;
    position = Duration.zero;
    duration = Duration.zero;
    playing = false;
    _stopped = true;
    _resetRetry();
    _lastProgress = Duration.zero;
    _lastProgressAt = DateTime.now();
    AudioFocus.instance.release(this);
    _clearMediaSession();
    notifyListeners();
  }

  Future<void> setRate(double value) async {
    rate = value.clamp(0.5, 2.0);
    await _player?.setRate(rate);
    notifyListeners();
  }

  /// 音量滑杆：同步更新淡入淡出的目标音量，避免下一次淡入又拉回 100。
  Future<void> setVolume(double value) async {
    _volume = value.clamp(0.0, 100.0).toDouble();
    final fader = _fader;
    if (fader != null) fader.target = _volume;
    try {
      await _player?.setVolume(_volume);
    } catch (_) {
      // 播放器可能已被释放，音量失败不影响界面状态
    }
    notifyListeners();
  }

  /// 静音 / 取消静音（记忆上一次的非零音量）
  Future<void> toggleMute() async {
    if (_volume > 0) {
      _lastAudibleVolume = _volume;
      await setVolume(0);
    } else {
      await setVolume(_lastAudibleVolume <= 0 ? 100 : _lastAudibleVolume);
    }
  }

  double _lastAudibleVolume = 100;

  Future<void> _load({Duration? resumeAt}) async {
    final current = episode;
    if (current == null) return;
    // 换了一期：进度上报的节流状态清零；同一期重试则保留
    if (_progressEpisodeId != current.id) {
      _progressEpisodeId = current.id;
      _reportedListened = false;
      _lastReportPosMs = -1;
      _lastReportAt = null;
    }
    _stopped = false;
    // 开播前先让音乐 / 音色试听让路，避免两路声音叠在一起
    await AudioFocus.instance.request(this, pause);
    error = null;
    loading = true;
    // 续播时不要把进度条闪回 0：界面按断点画，seek 成功前也不会跳
    position = resumeAt ?? Duration.zero;
    duration = Duration(seconds: current.durationSec.round());
    notifyListeners();
    try {
      // Android 13+ 不给通知权限，前台服务挂不住，切后台 / 熄屏就被系统掐掉。
      // 音乐链路早申请了，播客以前漏了这一步（2026-11-10 反馈「切后台就断」）。
      if (!kIsWeb) {
        final granted = await ensureAndroidNotificationPermission();
        if (!granted) {
          // 没有通知权限就没有前台服务通知 → 系统不当它是前台服务，
          // 切后台 / 熄屏后直接掐进程内连接。表现同时是「状态栏没有播放进度」
          // 和「听几分钟就断」，值得在客户端日志里留一条以便对症。
          ClientLogger.instance.warn(
            '通知权限未授予：前台服务无法常驻，切后台/熄屏会被系统掐断',
            route: 'blog.player/${current.id}',
          );
        }
        // 启动时初始化可能失败过（权限当时还没给），这里幂等重试一次
        await audioBackground.ensureStarted(
          channelName: I18n.instance.tr('audio.channelName'),
        );
      }
      final String url;
      if (_kind == BlogPlaybackKind.localBlog) {
        final source = current.sourcePath;
        if (source == null || source.isEmpty) {
          throw StateError('local blog item missing sourcePath');
        }
        final res = await ApiSession.instance.client.blogLocalAudioUrl(
          path: source,
          // Web 端浏览器解不了 WMA / APE：让服务端转 AAC 缓存后再播
          format: kIsWeb ? 'auto' : null,
        );
        url = '${ApiSession.instance.baseUrl}${res.url}';
      } else {
        final res = await ApiSession.instance.client.blogAudioUrl(id: current.id);
        url = '${ApiSession.instance.baseUrl}${res.url}';
      }
      final p = _ensure();
      // 先把音量压到 0，起播后再淡回来：与「音乐刚停」的输出重配叠在一起时
      // 满音量起播会有一声爆音。
      await _fader?.silence();
      await p.open(Media(url), play: true);
      if (resumeAt != null && resumeAt > Duration.zero) {
        await p.seek(resumeAt);
      }
      await p.setRate(rate);
      _fader?.fadeInFromSilence();
      // open(play:true) 的 playing 流可能晚一拍；先把面板推成「正在播」，
      // 前台服务要看到 playing=true 才会真正常驻。
      playing = true;
      loading = false;
      _lastProgress = position;
      _lastProgressAt = DateTime.now();
      _syncMediaSession();
      notifyListeners();
    } catch (e) {
      // 取地址 / open 失败也可能是瞬时网络问题（日志里就出现过重连时抛
      // `ClientException with SocketException`），统一交给退避重连；
      // 次数用尽才把错误交给界面，并且每次都落到客户端日志里方便回查。
      loading = false;
      _scheduleRetry('load 失败: $e');
    }
  }

  Future<void> toggle() async {
    final p = _player;
    if (p == null) {
      if (episode != null) await _load();
      return;
    }
    // 从暂停恢复也是「开播」，同样要抢焦点
    if (!playing) {
      _stopped = false;
      _lastProgressAt = DateTime.now();
      await AudioFocus.instance.request(this, pause);
      await _fader?.fadeInAndPlay();
      return;
    }
    await pause();
  }

  Future<void> seek(Duration to) async {
    // 手动拖动后重新起算：不然「往回调」会被看门狗当成停滞
    _lastProgress = to;
    _lastProgressAt = DateTime.now();
    _resetRetry();
    await _player?.seek(to);
  }

  Future<void> next() async {
    if (_queue.isEmpty) return;
    _reportProgress(force: true);
    _index = (_index + 1) % _queue.length;
    await _load();
  }

  Future<void> prev() async {
    if (_queue.isEmpty) return;
    _reportProgress(force: true);
    _index = (_index - 1 + _queue.length) % _queue.length;
    await _load();
  }

  Future<void> stop() async {
    final held = AudioFocus.instance.holds(this);
    _reportProgress(force: true);
    await _player?.stop();
    playing = false;
    _stopped = true;
    _resetRetry();
    _lastProgressAt = DateTime.now();
    AudioFocus.instance.release(this);
    if (held) _clearMediaSession();
    notifyListeners();
  }

  /// 系统媒体面板显示「AI 新闻 / 本地博客」，与播放来源保持一致
  String get _sourceLabel => I18n.instance.tr(
        _kind == BlogPlaybackKind.localBlog
            ? 'blog.nav.localBlog'
            : 'blog.nav.aiNews',
      );

  /// 系统媒体面板（锁屏 / 通知栏 / 耳机键）。Web 端有它，Android 才把这一路
  /// 当成真正的媒体会话，切后台 / 熄屏时不会被浏览器冻掉；桌面 / 原生端是空实现。
  void _syncMediaSession() {
    final current = episode;
    // 只有持焦点的那一路能写：暂停方不能把音乐（或反过来）的面板抢过去
    if (current == null || !AudioFocus.instance.holds(this)) return;
    if (!kIsWeb) {
      // 原生 Android：推给前台服务，通知栏 / 锁屏才有控制、熄屏才不被冻结
      audioBackground.update(
        AudioSnapshot(
          owner: this,
          id: current.id,
          title: current.title,
          artist: _sourceLabel,
          album: '',
          playing: playing,
          position: position,
          duration: duration,
          onPlay: () {
            if (!playing) unawaited(toggle());
          },
          onPause: () {
            if (playing) unawaited(pause());
          },
          onNext: () => unawaited(next()),
          onPrevious: () => unawaited(prev()),
          onSeek: (to) => unawaited(seek(to)),
          onStop: () => unawaited(stop()),
        ),
      );
      return;
    }
    updateMediaSession(
      title: current.title,
      artist: _sourceLabel,
      album: '',
      playing: playing,
      onPlay: () {
        if (!playing) unawaited(toggle());
      },
      onPause: () {
        if (playing) unawaited(pause());
      },
      onNext: () => unawaited(next()),
      onPrevious: () => unawaited(prev()),
    );
    updateMediaSessionPosition(duration: duration, position: position);
  }

  void _clearMediaSession() {
    if (!kIsWeb) {
      audioBackground.clear(this);
      return;
    }
    // 把面板标成「没在播」，handle 留着也无害：下一次播放会重新注册
    updateMediaSession(
      title: '',
      artist: '',
      album: '',
      playing: false,
      onPlay: () {},
      onPause: () {},
      onNext: () {},
      onPrevious: () {},
    );
  }

  /// 页面不要调它：单例要跨页面存活。保留给应用整体退出时用。
  @override
  void dispose() {
    AudioFocus.instance.release(this);
    _watchdog?.cancel();
    _watchdog = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    _subs.clear();
    final p = _player;
    _player = null;
    _fader = null;
    unawaited(_disposePlayer(p));
    super.dispose();
  }

  /// 先同步 pause 再异步 dispose：异步 dispose 在热重载时容易被丢掉，
  /// 留下一个还在出声的 `<video>` 元素。
  Future<void> _disposePlayer(Player? p) async {
    if (p == null) return;
    try {
      await p.pause();
      await p.dispose();
    } catch (_) {
      // 已经销毁过就算了
    }
  }
}
