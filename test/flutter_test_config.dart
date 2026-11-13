import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'network_guard.dart';

/// Global setup `flutter test` runs around every test file under `test/`.
///
/// Tests never reach the real network; see `network_guard.dart`.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  installNetworkGuard();
  setUp(() {
    // Blocked before this test started: in `setUpAll`, or by work the previous test left running.
    final earlier = takeBlockedConnections();
    resetNetworkGuard();
    reinstallHttpGuard();
    if (earlier.isNotEmpty) {
      fail(
        'Something before this test (setUpAll, or the previous test) tried to reach the real network '
        '(測試不得連真實網路); inject a fake client (請注入假 client):\n  ${earlier.join('\n  ')}',
      );
    }
  });
  tearDown(() {
    final blocked = takeBlockedConnections();
    if (blocked.isNotEmpty) {
      fail(
        'This test tried to reach the real network (測試不得連真實網路); inject a fake client '
        '(請注入假 client):\n  ${blocked.join('\n  ')}',
      );
    }
  });
  await testMain();
}
