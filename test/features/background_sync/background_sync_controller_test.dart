import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/features/background_sync/background_sync_controller.dart';

void main() {
  group('后台服务语言同步回归测试', () {
    test('服务运行中，语言切换应触发 settingsChanged 通知', () async {
      var settingsChangedNotified = false;

      // 注入假函数，模拟服务已在运行
      final controller = BackgroundSyncController(
        configure: ({required bool autoStartOnBoot}) async {},
        start: () async => true,
        stop: () async => true,
        isRunning: () async => true, // 模拟服务正在运行
        notifySettingsChanged: () {
          settingsChangedNotified = true; // 记录通知是否被触发
        },
      );

      // 模拟调用 applySettings（对应我们在语言切换代码里加的那行）
      final result = await controller.apply(
        enabled: true, 
        intervalSeconds: 600,
      );

      // 断言：服务应处于运行状态，且必须触发了通知
      expect(result, BackgroundSyncApplyResult.running);
      expect(settingsChangedNotified, isTrue);
    });

    test('后台保活关闭时，语言切换不应触发无效通知', () async {
      var settingsChangedNotified = false;

      final controller = BackgroundSyncController(
        configure: ({required bool autoStartOnBoot}) async {},
        start: () async => true,
        stop: () async => true,
        isRunning: () async => false, // 服务不在运行
        notifySettingsChanged: () => settingsChangedNotified = true,
      );

      // 此时开关是关的
      final result = await controller.apply(enabled: false, intervalSeconds: 0);

      // 断言：服务应被停止，且不应发通知
      expect(result, BackgroundSyncApplyResult.stopped);
      expect(settingsChangedNotified, isFalse);
    });
  });
}
