// 打开外部链接：Web / Electron（本质是 Flutter Web）走 window.open，
// 原生端降级成「显示可复制的 URL 文本」。
export 'external_link_stub.dart'
    if (dart.library.js_interop) 'external_link_web.dart';
