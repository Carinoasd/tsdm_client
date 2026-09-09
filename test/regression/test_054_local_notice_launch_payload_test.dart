import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/features/local_notice/keys.dart';
import 'package:tsdm_client/features/local_notice/stream.dart';

/// Issue #14: a tap on the notification while the app is not running starts it; the payload read from the launch
/// details at boot is parked and the home page consumes it exactly once after its first frame.
void main() {
  tearDown(() => rememberLaunchPayload(null));

  group('notification launch payload', () {
    test('nothing parked: the handler is not called', () async {
      var calls = 0;
      expect(
        await consumePendingLaunchPayload((_) {
          calls++;
        }),
        isFalse,
      );
      expect(calls, 0);
      expect(pendingLaunchPayload, isNull);
    });

    test('a parked payload reaches the handler exactly once', () async {
      rememberLaunchPayload(LocalNoticeKeys.openNotification);
      expect(pendingLaunchPayload, LocalNoticeKeys.openNotification);

      final seen = <String>[];
      expect(await consumePendingLaunchPayload(seen.add), isTrue);
      expect(seen, [LocalNoticeKeys.openNotification]);
      expect(pendingLaunchPayload, isNull, reason: 'forgotten as soon as it is handed out');

      // A rebuilt home page, or a second post-frame callback, finds nothing.
      expect(await consumePendingLaunchPayload(seen.add), isFalse);
      expect(seen, hasLength(1));
    });

    test('an async handler is awaited before the consumer returns', () async {
      rememberLaunchPayload(LocalNoticeKeys.openNotification);
      var finished = false;
      final consumed = consumePendingLaunchPayload((_) async {
        await Future<void>.delayed(Duration.zero);
        finished = true;
      });
      expect(finished, isFalse);
      expect(await consumed, isTrue);
      expect(finished, isTrue);
    });

    test('the payload is forgotten even when the handler throws', () async {
      rememberLaunchPayload(LocalNoticeKeys.openNotification);
      await expectLater(consumePendingLaunchPayload((_) => throw StateError('boom')), throwsStateError);
      expect(pendingLaunchPayload, isNull);
      expect(await consumePendingLaunchPayload((_) => fail('must not be called again')), isFalse);
    });

    test('remembering again replaces, remembering null clears', () async {
      rememberLaunchPayload('first');
      rememberLaunchPayload(LocalNoticeKeys.openNotification);
      expect(pendingLaunchPayload, LocalNoticeKeys.openNotification);
      rememberLaunchPayload(null);
      expect(pendingLaunchPayload, isNull);
      expect(await consumePendingLaunchPayload((_) => fail('nothing to consume')), isFalse);
    });
  });
}
