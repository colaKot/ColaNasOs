import 'dart:async';

import 'package:colanas_os/features/music/playback/playback_controller.dart';
import 'package:colanas_os/features/music/playback/playback_engine.dart';
import 'package:colanas_os/features/music/playback/playback_queue.dart';
import 'package:colanas_os/features/music/playback/playback_state.dart';
import 'package:colanas_os/features/music/playback/track.dart';
import 'package:flutter_test/flutter_test.dart';

/// 假引擎：不碰任何真实音频，只把「业务调了什么」和「事件什么时候来」
/// 暴露给测试。有了它，播放状态机可以完全脱离设备和网络验证 ——
/// 这正是把引擎抽成接口的意义。
class FakeEngine implements PlaybackEngine {
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _buffered = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _buffering = StreamController<bool>.broadcast();
  final _completed = StreamController<void>.broadcast();
  final _error = StreamController<PlaybackError>.broadcast();

  final List<String> calls = <String>[];
  Uri? lastOpened;
  Duration lastStartAt = Duration.zero;
  Duration lastSeek = Duration.zero;
  bool disposed = false;

  /// 让测试模拟「播完了」
  void emitCompleted() => _completed.add(null);

  /// 让测试模拟引擎报错
  void emitError(String message) => _error.add(PlaybackError.fromEngine(message));

  @override
  Stream<Duration> get positionStream => _position.stream;
  @override
  Stream<Duration> get durationStream => _duration.stream;
  @override
  Stream<Duration> get bufferedStream => _buffered.stream;
  @override
  Stream<bool> get playingStream => _playing.stream;
  @override
  Stream<bool> get bufferingStream => _buffering.stream;
  @override
  Stream<void> get completedStream => _completed.stream;
  @override
  Stream<PlaybackError> get errorStream => _error.stream;

  @override
  Future<void> open(
    Uri uri, {
    Duration startAt = Duration.zero,
    bool autoPlay = true,
  }) async {
    calls.add('open');
    lastOpened = uri;
    lastStartAt = startAt;
    if (autoPlay) _playing.add(true);
  }

  @override
  Future<void> play() async {
    calls.add('play');
    _playing.add(true);
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
    _playing.add(false);
  }

  @override
  Future<void> seek(Duration position) async {
    calls.add('seek');
    lastSeek = position;
    _position.add(position);
  }

  @override
  Future<void> setVolume(double volume) async => calls.add('volume');

  @override
  Future<void> setRate(double rate) async => calls.add('rate');

  @override
  Future<void> setLoop(PlaybackLoop loop) async => calls.add('loop:${loop.name}');

  @override
  Future<void> dispose() async {
    disposed = true;
    await _position.close();
    await _duration.close();
    await _buffered.close();
    await _playing.close();
    await _buffering.close();
    await _completed.close();
    await _error.close();
  }
}

Track _track(int i) => Track(
  id: 't$i',
  uri: Uri.parse('http://nas/music/$i.mp3'),
  title: '歌 $i',
  duration: const Duration(minutes: 3),
);

/// 让正在排队的微任务 / 流事件跑完
Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  group('PlaybackQueue', () {
    test('空队列 advance 返回 exhausted 且不改变游标', () {
      final (queue, action) = PlaybackQueue.empty().advance();
      expect(action, QueueAdvance.exhausted);
      expect(queue.isEmpty, isTrue);
    });

    test('列表循环：队尾的下一首回到第一首', () {
      final queue = PlaybackQueue.of(
        [_track(0), _track(1)],
        startAt: 1,
        loop: PlaybackLoop.all,
      );
      final (next, action) = queue.advance();
      expect(action, QueueAdvance.next);
      expect(next.current!.id, 't0');
    });

    test('顺序播放：队尾不循环，停在原地', () {
      final queue = PlaybackQueue.of(
        [_track(0), _track(1)],
        startAt: 1,
        loop: PlaybackLoop.none,
      );
      final (next, action) = queue.advance();
      expect(action, QueueAdvance.exhausted);
      expect(next.current!.id, 't1');
    });

    test('单曲循环：游标不动，语义是「重播当前」', () {
      final queue = PlaybackQueue.of(
        [_track(0), _track(1)],
        startAt: 0,
        loop: PlaybackLoop.one,
      );
      final (next, action) = queue.advance();
      expect(action, QueueAdvance.repeatCurrent);
      expect(next.cursor, 0);
    });

    test('removeAt 删掉当前曲之前的项，游标跟着前移（不会跳过一首）', () {
      final queue = PlaybackQueue.of(
        [_track(0), _track(1), _track(2)],
        startAt: 2,
      );
      final after = queue.removeAt(0);
      expect(after.length, 2);
      expect(after.current!.id, 't2');
      expect(after.cursor, 1);
    });

    test('开随机时当前曲留在原位，关掉恢复原顺序', () {
      final original = [_track(0), _track(1), _track(2), _track(3)];
      final queue = PlaybackQueue.of(original, startAt: 1);
      final shuffled = queue.withShuffle(true);

      expect(shuffled.shuffleEnabled, isTrue);
      expect(shuffled.current!.id, 't1');

      final restored = shuffled.withShuffle(false);
      expect(restored.shuffleEnabled, isFalse);
      expect(
        restored.tracks.map((t) => t.id).toList(),
        original.map((t) => t.id).toList(),
      );
      expect(restored.current!.id, 't1');
    });
  });

  group('PlaybackController', () {
    test('playAll 会打开当前曲目并进入 ready', () async {
      final engine = FakeEngine();
      final controller = PlaybackController(engine);

      await controller.playAll([_track(0), _track(1)], startAt: 0);
      await _settle();

      expect(engine.lastOpened.toString(), 'http://nas/music/0.mp3');
      expect(engine.calls.contains('open'), isTrue);
      expect(controller.state, isA<PlaybackReady>());
      expect(controller.isPlaying, isTrue);

      controller.dispose();
    });

    test('自然播完会自动播下一首（列表不循环也一样，只要还有下一首）', () async {
      final engine = FakeEngine();
      final controller = PlaybackController(engine);
      await controller.playAll([_track(0), _track(1)], startAt: 0);
      await _settle();

      engine.emitCompleted();
      await _settle();
      await _settle();

      expect(controller.currentTrack!.id, 't1');
      expect(engine.lastOpened.toString(), 'http://nas/music/1.mp3');

      controller.dispose();
    });

    test('pause 后状态是 paused，切歌后仍能继续', () async {
      final engine = FakeEngine();
      final controller = PlaybackController(engine);
      await controller.playAll([_track(0), _track(1)]);
      await _settle();

      await controller.togglePlayPause();
      await _settle();
      expect(controller.state, isA<PlaybackPaused>());
      expect(engine.calls.contains('pause'), isTrue);

      await controller.togglePlayPause();
      await _settle();
      expect(controller.state, isA<PlaybackReady>());

      controller.dispose();
    });

    test('重复点同一首只 seek 回起点，不重新打开（省一次加载、不断音）', () async {
      final engine = FakeEngine();
      final controller = PlaybackController(engine);
      await controller.playAll([_track(0), _track(1)], startAt: 0);
      await _settle();
      final openCount = engine.calls.where((c) => c == 'open').length;

      await controller.jumpTo(0);
      await _settle();

      expect(engine.calls.where((c) => c == 'open').length, openCount);
      expect(engine.lastSeek, Duration.zero);

      controller.dispose();
    });

    test('传输层噪声（tcp: ffurl read returned）不切成失败状态', () async {
      final engine = FakeEngine();
      final controller = PlaybackController(engine);
      await controller.playAll([_track(0)]);
      await _settle();

      engine.emitError('tcp: ffurl read returned 0');
      await _settle();

      expect(controller.state, isNot(isA<PlaybackFailed>()));
      expect(controller.isPlaying, isTrue);

      controller.dispose();
    });

    test('真错误会进入 failed 且保留曲目信息', () async {
      final engine = FakeEngine();
      final controller = PlaybackController(engine);
      await controller.playAll([_track(0)]);
      await _settle();

      engine.emitError('failed to open file');
      await _settle();

      final state = controller.state;
      expect(state, isA<PlaybackFailed>());
      expect((state as PlaybackFailed).track?.id, 't0');

      controller.dispose();
    });

    test('dispose 会释放引擎', () async {
      final engine = FakeEngine();
      final controller = PlaybackController(engine);
      controller.dispose();
      await _settle();
      expect(engine.disposed, isTrue);
    });
  });
}
