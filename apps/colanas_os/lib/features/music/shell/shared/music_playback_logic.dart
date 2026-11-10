/// 播放控件的数值与文案逻辑（不依赖具体 widget 树）。
///
/// 进度条数值换算、mm:ss 文案、下载百分比、循环模式轮转原先散落在
/// 底部栏、全屏栏、悬浮条与两个入口文件里；这里收成可单独验证的纯函数。
library;

import 'package:flutter/material.dart';

import '../compat/host.dart';
import '../play_service/controller/cola_player_controller.dart';

/// Duration → Slider 值的统一换算。
class MusicSeekBarMath {
  const MusicSeekBarMath._();

  static double maxMs(Duration duration) {
    final ms = duration.inMilliseconds;
    return (ms <= 0 ? 1 : ms).toDouble();
  }

  static double valueMs(
    Duration position,
    Duration duration, {
    bool dragging = false,
    double? dragValueMs,
  }) {
    final max = maxMs(duration);
    if (dragging && dragValueMs != null) {
      return dragValueMs.clamp(0.0, max).toDouble();
    }
    return position.inMilliseconds.toDouble().clamp(0.0, max).toDouble();
  }

  static bool isSeekEnabled(Duration duration) => duration.inMilliseconds > 0;

  static Duration fromMs(double milliseconds) =>
      Duration(milliseconds: milliseconds.round());
}

class MusicTimeText {
  const MusicTimeText._();

  static String of(Duration value) => FormatUtil.formatDurationOf(value);

  static String pair(Duration position, Duration duration) =>
      '${of(position)} / ${of(duration)}';

  static String percent(double progress) =>
      '${(progress.clamp(0.0, 1.0) * 100).toStringAsFixed(0)}%';

  static String downloadPercent(bool downloading, double progress) =>
      downloading ? percent(progress) : '';
}

/// 一次下载状态快照，让 part 组件不再直接读 controller 的 Rx 字段。
class MusicDownloadState {
  const MusicDownloadState({
    required this.downloading,
    required this.fileHash,
    required this.progress,
  });

  static const MusicDownloadState idle = MusicDownloadState(
    downloading: false,
    fileHash: '',
    progress: 0,
  );

  final bool downloading;
  final String fileHash;
  final double progress;

  bool matches(String itemFileHash) {
    if (!downloading) return false;
    final active = fileHash.trim();
    return active.isNotEmpty && active == itemFileHash.trim();
  }

  String get percentText =>
      MusicTimeText.downloadPercent(downloading, progress);
}

/// 循环模式轮转 + UI 元数据，避免两个入口各写一份 switch。
extension MusicLoopModeLogic on MusicLoopMode {
  MusicLoopMode get next => switch (this) {
    MusicLoopMode.sequence => MusicLoopMode.listLoop,
    MusicLoopMode.listLoop => MusicLoopMode.singleLoop,
    MusicLoopMode.singleLoop => MusicLoopMode.shuffle,
    MusicLoopMode.shuffle => MusicLoopMode.sequence,
  };

  String get i18nKey => switch (this) {
    MusicLoopMode.sequence => 'music_loop_sequence',
    MusicLoopMode.listLoop => 'music_loop_list_loop',
    MusicLoopMode.singleLoop => 'music_loop_single_loop',
    MusicLoopMode.shuffle => 'music_loop_shuffle',
  };

  IconData get icon => switch (this) {
    MusicLoopMode.sequence => Icons.format_list_numbered,
    MusicLoopMode.listLoop => Icons.repeat,
    MusicLoopMode.singleLoop => Icons.repeat_one,
    MusicLoopMode.shuffle => Icons.shuffle,
  };
}
