/// 音乐壳写操作的统一反馈。
///
/// 兼容接口的 `apiPost` 只在网络异常时给 `success=false`，业务失败藏在响应体的
/// `ok=false` 里；以前每个设置页都自己写一遍「取 message → 兜底 → 弹 toast」，
/// 加载弹窗也散落在 try 各处（有的还重复 dismiss）。这里收成四个小工具。
library;

import 'getx.dart';
import 'host.dart';

/// 返回失败原因，成功返回 null。
///
/// [nullDataIsFailure] 只对「必须拿回整行数据」的接口打开：例如更新音乐源后
/// 服务端要回完整记录，空 body 也应当回滚；而扫描接口只回一个入队结果，
/// 空 body 不该误判成失败。
String? businessFailure({
  required bool transportOk,
  Map<String, dynamic>? data,
  String? transportMessage,
  bool nullDataIsFailure = false,
}) {
  final failed =
      !transportOk ||
      (nullDataIsFailure && data == null) ||
      data?['ok'] == false;
  if (!failed) return null;
  final message = data?['message'];
  if (message is String && message.isNotEmpty) return message;
  return transportMessage ?? 'operation_failed'.tr;
}

void notifyFailure(String? reason) =>
    ToastUtil.show(reason ?? 'operation_failed'.tr);

void notifySuccess([String key = 'operation_success']) =>
    ToastUtil.show(key.tr);

/// 把「显示加载 → 执行 → 无论成败收起」收成一处，避免分支里漏关弹窗。
Future<T> withLoadingDialog<T>(Future<T> Function() action) async {
  DialogUtil.showLoading(message: 'loading'.tr);
  try {
    return await action();
  } finally {
    DialogUtil.dismissLoading();
  }
}
