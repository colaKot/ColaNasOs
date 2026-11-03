// 自定义 Flutter Web 引导脚本：Flutter 构建时会替换下面三个占位符。
//
// 之所以要自定义（而不是用默认模板）：
//   1. 默认配置拿不到本地 engineRevision，会去 `www.gstatic.com/flutter-canvaskit`
//      下载 canvaskit；内网/无外网时取不到，页面就是一片空白。
//   2. 回退字体走本地镜像（`tool/fetch-fallback-fonts.js` 生成 `fonts_fallback/s/**`），
//      否则汉字会渲染成「方块里一个 X」。
//
// 这里刻意不注册 service worker：内核静态托管每次都读磁盘上的最新产物，
// 加了 SW 反而可能把旧版本缓存下来，升级后又出现空白。
{{flutter_js}}
{{flutter_build_config}}

_flutter.loader.load({
  config: {
    canvasKitBaseUrl: 'canvaskit/',
    fontFallbackBaseUrl: 'fonts_fallback/s/',
  },
});