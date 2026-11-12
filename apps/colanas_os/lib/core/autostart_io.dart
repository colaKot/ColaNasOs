import 'dart:io';

/// Windows 登录启动项：`HKCU\Software\Microsoft\Windows\CurrentVersion\Run`
///
/// 用 HKCU 而不是 HKLM：安装包是 perUser 安装，写机器级启动项要管理员权限，
/// 会让「勾一下」变成弹 UAC —— 用户只是想要开机自动起来。
const String _runKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';

/// 值名和开始菜单 / 托盘 tip 保持一致，任务管理器「启动」页里一眼能认出来
const String _valueName = 'ColaNasOs 客户端';

bool get autostartSupported => Platform.isWindows;

Future<bool> setAutostartEnabled(bool enabled) async {
  if (!Platform.isWindows) return false;
  final exe = Platform.resolvedExecutable;
  final ProcessResult result;
  if (enabled) {
    // 带空格的路径必须加引号，否则系统只把前半截当程序名
    result = await Process.run('reg', <String>[
      'add',
      _runKey,
      '/v',
      _valueName,
      '/t',
      'REG_SZ',
      '/d',
      '"$exe"',
      '/f',
    ]);
  } else {
    result = await Process.run('reg', <String>[
      'delete',
      _runKey,
      '/v',
      _valueName,
      '/f',
    ]);
  }
  // 删除一个本来就不存在的值 reg 返回 1，这不是错误
  if (result.exitCode == 0) return true;
  return !enabled && '${result.stderr}'.contains('unable to find');
}

/// 启动时对账：开启状态下按**当前 exe 路径**重写一遍启动项。
///
/// 便携版解压到别的目录、安装版换了安装位置后，旧值会指向不存在的 exe，
/// 表现成「勾着但开机不启动」。写一次成本极低，别靠用户手动重勾。
Future<void> syncAutostartEntry(bool enabled) async {
  if (!enabled) return;
  await setAutostartEnabled(true);
}
