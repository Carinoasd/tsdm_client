import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/features/root/stream/scroll_to_top_stream.dart';

void main() {
  group('ScrollToTopStream 测试', () {
    test('发送 ScrollToTopEvent 后，监听者能正确收到对应的 TabIndex', () async {
      final completer = Completer<ScrollToTopEvent>();

      final subscription = scrollToTopStream.stream.listen((event) {
        if (!completer.isCompleted) {
          completer.complete(event);
        }
      });

      // 模拟底栏被双击，发送一个 TabIndex 为 1（分区）的事件
      scrollToTopStream.add(const ScrollToTopEvent(1));

      final event = await completer.future;

      // 断言：接收到的 index 必须和我们发送的一致
      expect(event.tabIndex, 1);

      await subscription.cancel();
    });
  });
}
