import 'package:nas_core/nas_core.dart';
import 'package:web/web.dart' as web;

/// Web 端判定：浏览器里永远是 `web`（TV 开关不影响能力档位）。
CapabilityEndpoint detectEndpoint({required bool tvMode}) => CapabilityEndpoint.web;

/// 是否 PC 客户端：Electron 外壳（`start.bat` / 安装包）加载的也是 Flutter Web 产物，
/// 光看运行时只能判出 `web`，会和「手机浏览器打开」混为一谈。
///
/// Electron 的默认 UA 末尾带 `Electron/<version>`（本项目没有 `setUserAgent` 覆盖它），
/// 用它区分「PC 客户端」和「其它浏览器」。纯浏览器 / 手机 / TV 一律 false。
bool detectPcShell() => web.window.navigator.userAgent.contains('Electron');
