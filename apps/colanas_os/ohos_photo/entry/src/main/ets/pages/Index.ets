// Flutter 页面容器（CL4-01）：一页承载整个 Flutter 应用，页面切换由 Flutter 路由负责。
import { FlutterPage } from '@ohos/flutter_ohos';

@Entry
@Component
struct Index {
  build() {
    Column() {
      FlutterPage()
    }
    .width('100%')
    .height('100%')
  }
}