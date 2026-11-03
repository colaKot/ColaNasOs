import 'package:web/web.dart' as web;

/// Web 持久化后端：浏览器 localStorage（同源隔离、刷新与重开标签页都保留）。
///
/// 只存一份 JSON 快照，键固定为 [storageKey]；内容与桌面版 `settings.json` 一致。
bool get persistent => true;

const storageKey = 'colanas.settings';

Future<String?> readAll() async {
  try {
    return web.window.localStorage.getItem(storageKey);
  } catch (_) {
    // 隐私模式 / 禁用存储：按空设置启动
    return null;
  }
}

Future<void> writeAll(String json) async {
  try {
    web.window.localStorage.setItem(storageKey, json);
  } catch (_) {
    // 配额不足 / 禁用存储：丢掉这次写入，不阻塞界面
  }
}