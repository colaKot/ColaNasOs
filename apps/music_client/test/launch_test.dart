import 'package:colanas_os/shell/app_launch.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('音乐独立端复用主客户端的 launch mode', () {
    expect(AppLaunchMode.values, contains(AppLaunchMode.music));
    expect(AppLaunchMode.music, isNot(AppLaunchMode.full));
  });
}