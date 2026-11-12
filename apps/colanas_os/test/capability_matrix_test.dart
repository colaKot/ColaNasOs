import 'package:colanas_os/core/endpoint_host.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nas_core/nas_core.dart';

/// 端能力矩阵契约（docs/04 §64）在客户端侧的落地验收：
/// 6 端 × 6 能力必须齐备，且与文档表格的关键格一致。
void main() {
  test('6 项能力 × 6 端档位齐备', () {
    expect(CapabilityMatrix.entries.length, 6);
    for (final entry in CapabilityMatrix.entries) {
      expect(entry.levels.length, 6, reason: '${entry.id} 缺端档位');
      for (final endpoint in CapabilityEndpoint.values) {
        expect(
          entry.levels.containsKey(endpoint),
          isTrue,
          reason: '${entry.id} 缺 ${CapabilityMatrix.keyOf(endpoint)}',
        );
      }
    }
  });

  test('关键格与文档一致', () {
    expect(
      CapabilityMatrix.levelOf('files', CapabilityEndpoint.web),
      CapabilityLevel.limited,
    );
    expect(
      CapabilityMatrix.levelOf('files', CapabilityEndpoint.tvApple),
      CapabilityLevel.none,
    );
    expect(
      CapabilityMatrix.levelOf('video', CapabilityEndpoint.harmony),
      CapabilityLevel.full,
    );
    expect(
      CapabilityMatrix.levelOf('terminal', CapabilityEndpoint.desktop),
      CapabilityLevel.full,
    );
  });

  test('App 归属：找不到能力的 App 返回 null', () {
    expect(CapabilityMatrix.forApp('files')?.id, 'files');
    expect(CapabilityMatrix.forApp('settings')?.id, 'system');
    expect(CapabilityMatrix.forApp('transfer'), isNull);
    expect(CapabilityMatrix.forApp('home'), isNull);
  });

  test('当前端可被测试固定', () {
    addTearDown(() => EndpointHost.overrideForTest(null));
    EndpointHost.overrideForTest(CapabilityEndpoint.web);
    expect(EndpointHost.endpoint, CapabilityEndpoint.web);
  });
}