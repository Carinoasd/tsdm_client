import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/features/local_notice/show.dart';

/// Issue #13: the auto sync notification goes through a fresh channel with high importance, because Android never lets
/// the app raise the importance of the channel it created first; the old id stays known so boot can delete it.
void main() {
  group('local notification channel', () {
    test('the replacement channel has a new id and the legacy id is kept for the cleanup', () {
      expect(localNoticeChannelId, 'newNoticeChannelV2');
      expect(legacyLocalNoticeChannelId, 'newNoticeChannel');
      expect(localNoticeChannelId, isNot(legacyLocalNoticeChannelId));
    });

    test('the notification details use the new channel with high importance and priority', () {
      final details = buildLocalNotificationDetails(channelName: 'name', channelDescription: 'desc', ticker: 'tick');
      final android = details.android;
      expect(android, isNotNull);
      expect(android!.channelId, localNoticeChannelId);
      expect(android.channelName, 'name');
      expect(android.channelDescription, 'desc');
      expect(android.ticker, 'tick');
      expect(android.importance, Importance.high);
      expect(android.priority, Priority.high);
      expect(android.icon, isNull, reason: 'the small icon given to initialize is kept');
      expect(details.iOS, isNull);
      expect(details.linux, isNull);
    });

    test('one notification id: a newer result replaces the previous notification', () {
      expect(localNoticeId, 0);
    });
  });
}
