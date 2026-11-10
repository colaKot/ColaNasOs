/// Web 端下载：浏览器自己有下载器，这里只负责把带 token 的地址拼出来。
library;

import 'cola_api_controller.dart';

/// 返回 false 表示「本端不接管」——调用方提示用户用浏览器下载即可。
Future<bool> downloadRemoteFile(String remotePath) async => false;

/// 带 token 的直链（Web 端可以 `window.open` 它）
String downloadUrlFor(String remotePath) {
  final base = ApiController.instance.baseUrl;
  final token = ApiController.instance.accessToken;
  final q = <String>['path=${Uri.encodeQueryComponent(remotePath)}'];
  if (token != null && token.isNotEmpty) {
    q.add('token=${Uri.encodeQueryComponent(token)}');
  }
  return '$base/api/v1/files/download?${q.join('&')}';
}
