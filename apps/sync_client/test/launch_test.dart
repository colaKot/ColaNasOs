import 'package:colanas_os/shell/app_launch.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('同步独立端复用主客户端的 launch mode', () {
    expect(AppLaunchMode.values, contains(AppLaunchMode.sync));
    expect(AppLaunchMode.sync, isNot(AppLaunchMode.full));
  });
}
