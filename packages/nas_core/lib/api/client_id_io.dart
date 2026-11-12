import 'dart:io';

/// 桌面端用机器名做客户端标识：同一台机器上跑的所有客户端算出同一个值，
/// 换一台机器就不同 —— 正好是「同步任务按机器隔离」要的语义。
///
/// 机器名是 localhost / 空串（部分容器、个别移动端）时返回空串，
/// 交给应用层的持久化随机 id 兜底。
String computeClientId() {
  if (!(Platform.isWindows || Platform.isMacOS || Platform.isLinux)) return '';
  final host = Platform.localHostname.trim().toLowerCase();
  if (host.isEmpty || host == 'localhost' || host == '127.0.0.1') return '';
  return 'pc:$host';
}
