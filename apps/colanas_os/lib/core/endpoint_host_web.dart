import 'package:nas_core/nas_core.dart';

/// Web 端判定：浏览器里永远是 `web`（TV 开关不影响能力档位）。
CapabilityEndpoint detectEndpoint({required bool tvMode}) => CapabilityEndpoint.web;