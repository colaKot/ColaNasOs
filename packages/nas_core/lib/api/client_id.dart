import 'client_id_stub.dart' if (dart.library.io) 'client_id_io.dart' as impl;

/// 客户端机器标识（随每个请求发 `x-colanas-client`）。
///
/// 用途：同步任务按「用户 + 机器」隔离 —— 同一个账号在两台电脑上各看各的任务，
/// 而同一台机器上的主客户端与独立同步客户端（`apps/sync_client`）共用同一个值，
/// 这样独立端看到的就是这台机器上的同步任务。
///
/// 取值来源：
///   - Windows / macOS / Linux 桌面端：机器名（`Platform.localHostname`），
///     天然「同机一致、异机不同」，不需要额外持久化；
///   - Web / Android / iOS：机器名没有意义（都是 localhost / 随机），由应用层在启动时
///     用 [override] 给一个持久化的随机 id。
class ColanasClientId {
  ColanasClientId._();

  static String? _override;

  /// 应用层覆盖（移动端 / Web 用本地持久化的随机 id）
  static set override(String? value) => _override = (value ?? '').trim();

  /// 当前请求要带的客户端标识；空串表示不带（服务端按历史同组处理）
  static String get value {
    final o = _override;
    if (o != null && o.isNotEmpty) return o;
    return impl.computeClientId();
  }
}
