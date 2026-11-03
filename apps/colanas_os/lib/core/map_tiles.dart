import 'session.dart';

/// 底图瓦片统一走内核代理（服务端 30 天本地缓存）。
///
/// 客户端不再直连 Esri / OSM：内网 NAS 到外部底图经常超时，且每次打开地图都会
/// 重复下载；代理后由服务端统一拉取、落盘、过期回退。
String tileProxyTemplate({String? serverId}) {
  final base = ApiSession.instance.baseUrl;
  final server =
      serverId == null || serverId.isEmpty
          ? ''
          : '&server=${Uri.encodeComponent(serverId)}';
  return '$base/api/v1/photo/map/tile?z={z}&x={x}&y={y}$server';
}

/// flutter_map 的 TileLayer 支持 headers，所以代理接口仍走普通 Bearer 鉴权。
Map<String, String> tileProxyHeaders() {
  final token = ApiSession.instance.token;
  return {if (token != null) 'authorization': 'Bearer $token'};
}