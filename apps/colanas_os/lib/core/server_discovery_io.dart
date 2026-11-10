import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 局域网 / 端口自动匹配（桌面 + 移动端）。
///
/// 解决的问题：服务端换了端口（或换机器）之后，登录页的地址要人手改。
/// 这里做两件事：
///  1. `matchPort`：**同一个主机**换端口时，挨个试常见/已知端口，找到谁应 `/health`；
///  2. `scanLan`：手机上根本不知道该填哪个 IP 时，扫本网段里开着的服务。
///
/// 都只认 `/health`（免鉴权），且并发有上限、单个 400~800ms 超时，
/// 扫完最多两秒，不会把登录页卡住。
class DiscoveredServer {
  const DiscoveredServer({
    required this.baseUrl,
    required this.host,
    required this.port,
    this.name = '',
    this.welcome = '',
  });

  /// 可直填登录框的地址（无尾斜杠）
  final String baseUrl;
  final String host;
  final int port;

  /// 服务端自定义主机名（/health 的 hostname），没有就空
  final String name;

  /// 欢迎语（/health 的 welcome）
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

/// 默认端口 + 常见 NAS / 反代端口。顺序 = 优先级。
const List<int> kDefaultProbePorts = <int>[7788, 7888, 23788, 8080, 80, 443, 3000, 5000];

/// 探测一个地址是否是 ColaNasOs 内核。
///
/// 返回 null = 不通 / 不是内核；否则返回主机名与欢迎语（可能都是空串）。
Future<DiscoveredServer?> probeServer(
  String baseUrl, {
  int timeoutMs = 700,
}) async {
  final raw = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
  if (raw.isEmpty) return null;
  final uri = Uri.tryParse(raw);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
  final client = HttpClient()..connectionTimeout = Duration(milliseconds: timeoutMs);
  try {
    final req = await client
        .getUrl(uri.replace(path: '/health'))
        .timeout(Duration(milliseconds: timeoutMs));
    final res = await req.close().timeout(Duration(milliseconds: timeoutMs));
    if (res.statusCode != 200) {
      await res.drain<void>();
      return null;
    }
    // /health 是 UTF-8 JSON（hostname / welcome 可能是中文）
    final body = await res.transform(utf8.decoder).join();
    // 只认内核的 /health：`{"ok":true,...}`。别的服务（路由器、NAS 管理页）不算。
    if (!body.contains('"ok"') || !body.contains('true')) return null;
    String field(String key) {
      final m = RegExp('"$key"\\s*:\\s*"([^"]*)"').firstMatch(body);
      return m?.group(1) ?? '';
    }

    final port = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);
    return DiscoveredServer(
      baseUrl: raw,
      host: uri.host,
      port: port,
      name: field('hostname'),
      welcome: field('welcome'),
    );
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

/// 同主机换端口：按 [ports] 顺序试，返回第一个活的地址。
///
/// [hint] 可以是完整地址、`host:port`、或纯 host。纯 host 时不改协议（默认 http）。
Future<DiscoveredServer?> matchPort(
  String hint, {
  List<int> ports = kDefaultProbePorts,
  int timeoutMs = 700,
}) async {
  final parsed = _parseHint(hint);
  if (parsed == null) return null;
  final host = parsed.host;
  final scheme = parsed.scheme;
  // 已填的端口排在最前（用户大概率是对的，只是服务端还没起来/写错了主机）
  final ordered = <int>[
    if (parsed.port != null) parsed.port!,
    ...ports.where((p) => p != parsed.port),
  ];
  for (final port in ordered) {
    final url = _base(scheme, host, port);
    final hit = await probeServer(url, timeoutMs: timeoutMs);
    if (hit != null) return hit;
  }
  return null;
}

/// 扫本网段（/24）里所有开着 [port] 的内核。
///
/// 只扫本机所在网段，不跨网段；并发 32，单机 600ms 超时。
/// [extraPorts] 里的端口会逐个再扫一遍（比如用户改过端口）。
Future<List<DiscoveredServer>> scanLan({
  int port = 7788,
  List<int> extraPorts = const <int>[],
  int timeoutMs = 600,
  int concurrency = 32,
  /// 只扫指定主机（测试/调试用）；为空才按本机网段展开
  List<String>? onlyHosts,
}) async {
  final myIps = <String>[...?onlyHosts];
  if (onlyHosts == null) {
    try {
      for (final ni in await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      )) {
        for (final a in ni.addresses) {
          if (a.isLoopback) continue;
          myIps.add(a.address);
        }
      }
    } catch (_) {
      return const <DiscoveredServer>[];
    }
  }
  if (myIps.isEmpty) return const <DiscoveredServer>[];

  final hosts = <String>[];
  if (onlyHosts != null) {
    hosts.addAll(onlyHosts);
  } else {
    for (final ip in myIps) {
      final parts = ip.split('.');
      if (parts.length != 4) continue;
      final prefix = '${parts[0]}.${parts[1]}.${parts[2]}';
      for (var i = 1; i <= 254; i++) {
        final h = '$prefix.$i';
        if (!hosts.contains(h)) hosts.add(h);
      }
    }
  }
  // 本机先试：桌面端常见「服务就在这台机器上」
  hosts.sort((a, b) {
    if (a == myIps.first) return -1;
    if (b == myIps.first) return 1;
    return 0;
  });

  final ports = <int>[port, ...extraPorts.where((p) => p != port)];
  final found = <DiscoveredServer>[];
  var cursor = 0;
  Future<void> worker() async {
    while (cursor < hosts.length) {
      final host = hosts[cursor++];
      for (final p in ports) {
        final hit = await probeServer(_base('http', host, p), timeoutMs: timeoutMs);
        if (hit != null) {
          if (!found.any((e) => e.baseUrl == hit.baseUrl)) found.add(hit);
          break; // 同一台机器命中一个口就够了
        }
      }
    }
  }

  await Future.wait(List<Future<void>>.generate(
    concurrency.clamp(1, 64),
    (_) => worker(),
  ));
  // 命名过的（自定义主机名）排前面，方便认
  found.sort((a, b) {
    final an = a.name.trim().isEmpty ? 1 : 0;
    final bn = b.name.trim().isEmpty ? 1 : 0;
    if (an != bn) return an - bn;
    return a.host.compareTo(b.host);
  });
  return found;
}

class _Hint {
  const _Hint(this.scheme, this.host, this.port);
  final String scheme;
  final String host;
  final int? port;
}

_Hint? _parseHint(String hint) {
  var s = hint.trim();
  if (s.isEmpty) return null;
  if (!s.contains('://')) s = 'http://$s';
  final uri = Uri.tryParse(s);
  if (uri == null || uri.host.isEmpty) return null;
  final scheme = uri.scheme == 'https' ? 'https' : 'http';
  final port = uri.hasPort
      ? uri.port
      : (uri.scheme == 'https' ? 443 : (uri.scheme == 'http' ? 80 : null));
  return _Hint(scheme, uri.host, port);
}

String _base(String scheme, String host, int port) {
  final defaultPort = (scheme == 'https' && port == 443) || (scheme == 'http' && port == 80);
  return defaultPort ? '$scheme://$host' : '$scheme://$host:$port';
}
