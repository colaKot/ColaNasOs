/// 产品版本号（单一真源：`package.json.version`，由 `tool/version.js` 同步，勿手改）。
const String kAppVersion = '1.6.1';

/// 客户端构建号（`pubspec.yaml` 里 `version: X.Y.Z+B` 的 B，同样由 `tool/version.js` 同步）。
///
/// 安卓比较版本**必须用它**，不能比 semver 字符串：同一次发布里 `1.4.0+35`
/// 与 `1.4.0+36` 是两次不同的安装包，semver 一样但版本号不同。
const int kAppVersionCode = 84;

/// 项目主页（源码 / 更新日志 / Releases）。
///
/// 客户端「设置 → 关于」与 TV「我的」页都直接展示它，桌面/手机还可以点开。
/// 换仓库地址只改这一处。
const String kProjectUrl = 'https://github.com/colaKot/ColaNasOs';
