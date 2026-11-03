import 'dart:io';

import 'sync_autostart.dart';

/// 桌面端开机自启：Windows 写注册表 Run 项，macOS 写 LaunchAgent，
/// Linux 写 XDG autostart 的 .desktop 文件。
///
/// 目标一律取 `Platform.resolvedExecutable`：独立端在系统里就是那个 exe / App，
/// 不做符号链接猜测，避免自启指向开发期的 flutter 启动器。
class IoSyncAutoStart implements SyncAutoStart {
  const IoSyncAutoStart();

  static const _winRunKey =
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
  static const _winValueName = 'ColaNasSync';
  static const _macLabel = 'com.colanas.sync';
  static const _linuxEntry = '.config/autostart/colanas-sync.desktop';

  @override
  bool get supported => Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  @override
  String get unsupportedReasonKey => 'sync.autostart.unsupported';

  @override
  String get targetPath => Platform.resolvedExecutable;

  String get _home => Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '';

  String get _macPlist => '$_home/Library/LaunchAgents/$_macLabel.plist';

  String get _linuxFile => '$_home/$_linuxEntry';

  @override
  bool get enabled {
    if (!supported) return false;
    try {
      if (Platform.isWindows) {
        final r = Process.runSync(
          'reg',
          ['query', _winRunKey, '/v', _winValueName],
          runInShell: false,
        );
        return r.exitCode == 0;
      }
      if (Platform.isMacOS) return File(_macPlist).existsSync();
      return File(_linuxFile).existsSync();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> setEnabled(bool value) async {
    if (!supported) return false;
    if (Platform.isWindows) return _setWindows(value);
    if (Platform.isMacOS) return _setMac(value);
    return _setLinux(value);
  }

  Future<bool> _setWindows(bool value) async {
    final r = value
        ? await Process.run('reg', [
            'add',
            _winRunKey,
            '/v',
            _winValueName,
            '/t',
            'REG_SZ',
            '/d',
            '"$targetPath"',
            '/f',
          ], runInShell: false)
        : await Process.run('reg', [
            'delete',
            _winRunKey,
            '/v',
            _winValueName,
            '/f',
          ], runInShell: false);
    return r.exitCode == 0;
  }

  Future<bool> _setMac(bool value) async {
    final file = File(_macPlist);
    if (!value) {
      await Process.run('launchctl', ['unload', '-w', _macPlist], runInShell: false);
      if (file.existsSync()) await file.delete();
      return true;
    }
    file.parent.createSync(recursive: true);
    await file.writeAsString('''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$_macLabel</string>
  <key>ProgramArguments</key><array><string>$targetPath</string></array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
''');
    final r = await Process.run('launchctl', ['load', '-w', _macPlist], runInShell: false);
    return r.exitCode == 0;
  }

  Future<bool> _setLinux(bool value) async {
    final file = File(_linuxFile);
    if (!value) {
      if (file.existsSync()) await file.delete();
      return true;
    }
    file.parent.createSync(recursive: true);
    await file.writeAsString('''[Desktop Entry]
Type=Application
Name=ColaNasSync
Comment=ColaNasOs sync daemon
Exec="$targetPath"
Terminal=false
X-GNOME-Autostart-enabled=true
''');
    return true;
  }
}

SyncAutoStart createPlatformSyncAutoStart() => const IoSyncAutoStart();
