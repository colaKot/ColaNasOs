import 'dart:async';

import '../../compat/getx.dart';
import '../../compat/host.dart' show ToastUtil;
import '../../compat/mutation_feedback.dart';
import '../models/cola_music_source.dart';
import '../service/cola_source_api_service.dart';

/// 音乐源目录设置。
///
/// 这里的写操作大多是「先改本地列表，再发请求，失败就回滚」；加载弹窗与
/// 失败提示统一走 [withLoadingDialog] / [businessFailure]，控制器只保留
/// 每个接口各自的业务判断和回滚位置。
class ColaMusicSourceSettingsController extends GetxController {
  final RxList<ColaMusicSource> sources = <ColaMusicSource>[].obs;
  final RxBool loadingSources = false.obs;
  final RxBool scanning = false.obs;

  ColaMusicSourceApiService get _api => ColaMusicSourceApiService.instance;

  @override
  void onInit() {
    super.onInit();
    unawaited(fetchSources());
  }

  /// 界面上按小时展示间隔；未设置时给 2 小时默认值，范围锁在 1~24。
  int getIntervalHours(ColaMusicSource source) {
    final ms = source.scanIntervalMs;
    if (ms <= 0) return 2;
    return (ms / (3600 * 1000)).round().clamp(1, 24);
  }

  bool getIntervalEnabled(ColaMusicSource source) =>
      source.scanInterval == 1 || source.scanIntervalMs > 0;

  Future<void> fetchSources({bool showLoading = false}) async {
    if (loadingSources.value) return;
    loadingSources.value = true;
    try {
      final listed = await _api.listSources(showLoading: showLoading);
      sources.assignAll(listed);
    } finally {
      loadingSources.value = false;
    }
  }

  /// 批量新增：路径先去重；逐个提交，任意一个失败就停，最后统一刷新。
  Future<bool> addSources(List<String> paths) async {
    final unique = paths
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toSet()
        .toList();
    if (unique.isEmpty) return false;

    return withLoadingDialog(() async {
      for (final path in unique) {
        final reply = await _api.addSource(path, showLoading: false);
        if (!reply.success) {
          notifyFailure(reply.message);
          return false;
        }
      }
      await fetchSources();
      notifySuccess();
      return true;
    });
  }

  Map<String, dynamic> _patchBody({
    int? scanWhenStart,
    int? scanWhenChange,
    int? scanInterval,
    int? scanIntervalMs,
    String? showType,
  }) => <String, dynamic>{
    'scan_when_start': ?scanWhenStart,
    'scan_when_change': ?scanWhenChange,
    'scan_interval': ?scanInterval,
    'scan_interval_ms': ?scanIntervalMs,
    'show_type': ?showType,
  };

  Future<void> updateSourceOptimistic(
    ColaMusicSource source, {
    int? scanWhenStart,
    int? scanWhenChange,
    int? scanInterval,
    int? scanIntervalMs,
    String? showType,
  }) async {
    final index = sources.indexWhere((entry) => entry.id == source.id);
    if (index < 0) return;

    final previous = sources[index];
    sources[index] = previous.copyWith(
      scanWhenStart: scanWhenStart,
      scanWhenChange: scanWhenChange,
      scanInterval: scanInterval,
      scanIntervalMs: scanIntervalMs,
      showType: showType,
    );

    final reply = await _api.updateSource(
      source.id,
      _patchBody(
        scanWhenStart: scanWhenStart,
        scanWhenChange: scanWhenChange,
        scanInterval: scanInterval,
        scanIntervalMs: scanIntervalMs,
        showType: showType,
      ),
      showLoading: false,
    );
    final body = reply.data;
    final reason = businessFailure(
      transportOk: reply.success,
      data: body,
      transportMessage: reply.message,
      nullDataIsFailure: true,
    );
    if (reason != null) {
      sources[index] = previous;
      notifyFailure(reason);
      return;
    }

    // 服务端回整行才覆盖；只回 ok 就保留本地那条（连 path 都没有的不是完整记录）
    if (body?['path'] != null) {
      sources[index] = ColaMusicSource.fromJson(body!);
    }
  }

  Future<void> relocateSource(ColaMusicSource source, String newPath) async {
    try {
      await withLoadingDialog(() async {
        final reply = await _api.relocateSource(
          source.id,
          newPath,
          showLoading: false,
        );
        if (!reply.success) {
          notifyFailure(reply.message);
          return;
        }
        await fetchSources();
        notifySuccess();
      });
    } catch (_) {
      notifyFailure(null);
    }
  }

  void _restore(int index, ColaMusicSource removed) =>
      sources.insert(index.clamp(0, sources.length), removed);

  Future<void> deleteSourceOptimistic(ColaMusicSource source) async {
    final index = sources.indexWhere((entry) => entry.id == source.id);
    if (index < 0) return;
    final removed = sources.removeAt(index);

    try {
      await withLoadingDialog(() async {
        final reply = await _api.deleteSource(source.id, showLoading: false);
        if (!reply.success) {
          _restore(index, removed);
          notifyFailure(reply.message);
          return;
        }
        notifySuccess();
      });
    } catch (_) {
      _restore(index, removed);
      notifyFailure(null);
    }
  }

  /// 扫描是「入队即返回」：整库 probe 要跑几分钟，同步等必然撞客户端 30s 超时。
  /// 因此这里不挂加载圈，只给一句入队反馈，结果由 `scan.done` 事件推动刷新。
  Future<void> scanSource(String path) async {
    final target = path.trim();
    if (target.isEmpty || scanning.value) return;

    scanning.value = true;
    try {
      final reply = await _api.scanSource(target, showLoading: false);
      final body = reply.data;
      final reason = businessFailure(
        transportOk: reply.success,
        data: body,
        transportMessage: reply.message,
      );
      if (reason != null) {
        notifyFailure(reason);
        return;
      }
      final reused = body?['reused'] == true;
      ToastUtil.show(
        (reused ? 'music_source_scan_running' : 'music_source_scan_queued').tr,
      );
      await fetchSources();
    } catch (_) {
      notifyFailure(null);
    } finally {
      scanning.value = false;
    }
  }
}
