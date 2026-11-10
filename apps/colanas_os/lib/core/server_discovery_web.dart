/// Web 端的等价实现（能力为空）。
///
/// 浏览器没有 dart:io：拿不到网卡列表、不能扫网段，也不该在页面里乱试端口。
/// Web 端本来就「同源优先」（页面就是内核提供的），地址栏是什么端口，登录框就是什么端口，
/// 所以端口自动匹配只在原生端有意义 —— 这里全部返回空，由 LoginPage 跳过。
library;

class DiscoveredServer {
  const DiscoveredServer({
    required this.baseUrl,
    required this.host,
    required this.port,
    this.name = '',
    this.welcome = '',
  });

  final String baseUrl;
  final String host;
  final int port;
  final String name;
  final String welcome;

  String get label {
    final n = name.trim();
    final w = welcome.trim();
    if (n.isNotEmpty && w.isNotEmpty) return '$n · $w';
    if (n.isNotEmpty) return n;
    if (w.isNotEmpty) return w;
    return baseUrl;
  }
}

const List<int> kDefaultProbePorts = <int>[7788, 7888, 23788, 8080, 80, 443, 3000, 5000];

Future<DiscoveredServer?> probeServer(String baseUrl, {int timeoutMs = 700}) async => null;

Future<DiscoveredServer?> matchPort(
  String hint, {
  List<int> ports = kDefaultProbePorts,
  int timeoutMs = 700,
}) async =>
    null;

Future<List<DiscoveredServer>> scanLan({
  int port = 7788,
  List<int> extraPorts = const <int>[],
  int timeoutMs = 600,
  int concurrency = 32,
}) async =>
    const <DiscoveredServer>[];
