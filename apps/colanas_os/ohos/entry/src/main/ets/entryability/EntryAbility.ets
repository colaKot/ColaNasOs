// HarmonyOS 入口 Ability（CL4-01）。
//
// 由 flutter_ohos 的 FlutterAbility 承载：`flutter build hap` 会把 Flutter 引擎与
// `flutter_assets` 一起打进 entry 模块。插件注册类 GeneratedPluginRegistrant 由
// flutter_ohos 构建时生成，接入 SDK 后按模板在 configureFlutterEngine 里补注册。
import { FlutterAbility } from '@ohos/flutter_ohos';

export default class EntryAbility extends FlutterAbility {}