/// Notification categories and quiet hours: which of the new notifications the auto sync announces in system
/// notifications, the Android channel of each, and the settings behind them (default: everything announced).
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/local_notice/show.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/features/notification/utils/auto_sync_info.dart';
import 'package:tsdm_client/features/notification/utils/notice_info.dart';
import 'package:tsdm_client/features/notification/utils/push_rules.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

NoticeV2 _notice(int id, String? type, [String? fromIdType]) =>
    NoticeV2(id: id, timestamp: 100 + id, data: '<p>n$id</p>', ignoreType: type, fromIdType: fromIdType);

const _pm = PersonalMessageV2(
  timestamp: 500,
  data: 'hi',
  peerUid: 2,
  peerUsername: 'Bob',
  sender: false,
  alreadyRead: false,
);
const _bm = BroadcastMessageV2(timestamp: 400, data: 'bm', pmid: 3);

NotificationV2 _fresh({
  List<NoticeV2> notices = const [],
  List<PersonalMessageV2> pms = const [],
  List<BroadcastMessageV2> bms = const [],
}) => NotificationV2(status: 0, noticeList: notices, personalMessageList: pms, broadcastMessageList: bms);

NotificationPushRules _without(Set<NoticeCategory> off) =>
    NotificationPushRules(enabled: {...NoticeCategory.values}..removeAll(off));

DateTime _at(int h, int m) => DateTime(2026, 11, 7, h, m);

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
  });

  group('category of a notice', () {
    test('kinds map onto the five categories', () {
      expect(categoryOfNotice(_notice(1, 'post', 'post')), NoticeCategory.reply);
      expect(categoryOfNotice(_notice(1, 'post', 'quote')), NoticeCategory.reply);
      expect(categoryOfNotice(_notice(1, 'post')), NoticeCategory.reply);
      expect(categoryOfNotice(_notice(1, 'at', 'at')), NoticeCategory.mention);
      expect(categoryOfNotice(_notice(1, 'rate', 'rate')), NoticeCategory.rate);
      expect(categoryOfNotice(_notice(1, 'ratetrack')), NoticeCategory.rate);
      expect(categoryOfNotice(_notice(1, 'pcomment', 'pcomment')), NoticeCategory.rate);
      expect(categoryOfNotice(_notice(1, 'system', 'hongbao')), NoticeCategory.system);
      expect(categoryOfNotice(_notice(1, 'post', 'moderate_closed')), NoticeCategory.system);
      expect(categoryOfNotice(_notice(1, 'friend')), NoticeCategory.system);
      expect(categoryOfNotice(_notice(1, null)), NoticeCategory.system);
      expect(noticeCategoryOf(NoticeKind.generic), NoticeCategory.system);
    });

    test('every category has its own switch and channel', () {
      expect(NoticeCategory.values.map((e) => e.settingsKey).toSet(), hasLength(NoticeCategory.values.length));
      expect(NoticeCategory.values.map((e) => e.channelId).toSet(), hasLength(NoticeCategory.values.length));
      expect(NoticeCategory.values.map((e) => e.channelId), isNot(contains(localNoticeChannelId)));
    });
  });

  group('quiet window', () {
    test('inside one day', () {
      expect(inQuietWindow(minute: 12 * 60, start: 12 * 60, end: 14 * 60), isTrue);
      expect(inQuietWindow(minute: 14 * 60 - 1, start: 12 * 60, end: 14 * 60), isTrue);
      expect(inQuietWindow(minute: 14 * 60, start: 12 * 60, end: 14 * 60), isFalse);
      expect(inQuietWindow(minute: 11 * 60, start: 12 * 60, end: 14 * 60), isFalse);
    });

    test('past midnight', () {
      const start = 23 * 60;
      const end = 8 * 60;
      expect(inQuietWindow(minute: 23 * 60, start: start, end: end), isTrue);
      expect(inQuietWindow(minute: 0, start: start, end: end), isTrue);
      expect(inQuietWindow(minute: 7 * 60 + 59, start: start, end: end), isTrue);
      expect(inQuietWindow(minute: 8 * 60, start: start, end: end), isFalse);
      expect(inQuietWindow(minute: 12 * 60, start: start, end: end), isFalse);
      expect(inQuietWindow(minute: 22 * 60 + 59, start: start, end: end), isFalse);
    });

    test('equal bounds are an empty window', () {
      expect(inQuietWindow(minute: 600, start: 600, end: 600), isFalse);
    });

    test('rules only look at the window when switched on', () {
      expect(NotificationPushRules.all.isQuiet(_at(2, 0)), isFalse);
      expect(const NotificationPushRules(quietHours: true).isQuiet(_at(2, 0)), isTrue);
      expect(const NotificationPushRules(quietHours: true).isQuiet(_at(12, 0)), isFalse);
    });
  });

  group('filtering what is announced', () {
    final mixed = _fresh(
      notices: [_notice(1, 'post', 'post'), _notice(2, 'at', 'at'), _notice(3, 'rate', 'rate'), _notice(4, 'system')],
      pms: [_pm],
      bms: [_bm],
    );

    test('everything on announces everything, as before', () {
      final info = autoSyncInfoOf(mixed)!;
      expect(info.notice, 4);
      expect(info.personalMessage, 1);
      expect(info.broadcastMessage, 1);
      expect(autoSyncInfoOf(mixed, at: _at(3, 0)), isNotNull);
    });

    test('a category switched off is left out of the counts and the lines', () {
      final info = autoSyncInfoOf(mixed, rules: _without({NoticeCategory.reply, NoticeCategory.rate}))!;
      expect(info.notice, 2);
      expect(info.personalMessage, 1);
      expect(info.lines.where((e) => e.kind == NotificationAutoSyncLineKind.notice).map((e) => e.text), [
        'n4',
        'n2',
      ]);
    });

    test('switching private messages off lets the next item headline', () {
      final info = autoSyncInfoOf(mixed, rules: _without({NoticeCategory.pm}))!;
      expect(info, isA<NotificationAutoSyncInfoBm>());
      expect(info.personalMessage, 0);
      final noBm = autoSyncInfoOf(mixed, rules: _without({NoticeCategory.pm, NoticeCategory.system}))!;
      expect(noBm, isA<NotificationAutoSyncInfoNotice>().having((e) => e.nid, 'newest remaining', 3));
      expect(noBm.notice, 3);
    });

    test('broadcast messages follow the system category', () {
      expect(autoSyncInfoOf(_fresh(bms: [_bm]), rules: _without({NoticeCategory.system})), isNull);
      expect(autoSyncInfoOf(_fresh(bms: [_bm]), rules: _without({NoticeCategory.pm})), isNotNull);
    });

    test('nothing is announced when every category the sync brought is off', () {
      final onlyReplies = _fresh(notices: [_notice(1, 'post', 'post')]);
      expect(autoSyncInfoOf(onlyReplies, rules: _without({NoticeCategory.reply})), isNull);
      expect(autoSyncInfoOf(onlyReplies, rules: _without({NoticeCategory.rate})), isNotNull);
      expect(autoSyncInfoOf(mixed, rules: _without(NoticeCategory.values.toSet())), isNull);
    });

    test('quiet hours announce nothing and nothing is made up afterwards', () {
      const quiet = NotificationPushRules(quietHours: true);
      expect(autoSyncInfoOf(mixed, rules: quiet, at: _at(23, 30)), isNull);
      expect(autoSyncInfoOf(mixed, rules: quiet, at: _at(0, 5)), isNull);
      expect(autoSyncInfoOf(mixed, rules: quiet, at: _at(8, 0)), isNotNull);
      // The next sync only brings what is new then: the one before is not announced again.
      expect(autoSyncInfoOf(_fresh(), rules: quiet, at: _at(8, 10)), isNull);
    });

    test('the channel is the one of the headline item', () {
      expect(noticeCategoryOfInfo(autoSyncInfoOf(mixed)!), NoticeCategory.pm);
      expect(noticeCategoryOfInfo(autoSyncInfoOf(_fresh(bms: [_bm]))!), NoticeCategory.system);
      expect(noticeCategoryOfInfo(autoSyncInfoOf(_fresh(notices: [_notice(1, 'at', 'at')]))!), NoticeCategory.mention);
      expect(noticeCategoryOfInfo(autoSyncInfoOf(_fresh(notices: [_notice(1, 'rate')]))!), NoticeCategory.rate);
      expect(
        noticeCategoryOfInfo(autoSyncInfoOf(_fresh(notices: [_notice(1, 'post', 'quote')]))!),
        NoticeCategory.reply,
      );
    });

    test('the notification details use the channel of the category', () {
      final details = buildLocalNotificationDetails(
        channelName: 'n',
        channelDescription: 'd',
        ticker: 't',
        category: NoticeCategory.rate,
      );
      expect(details.android!.channelId, 'noticeRate');
      expect(
        buildLocalNotificationDetails(channelName: 'n', channelDescription: 'd', ticker: 't').android!.channelId,
        localNoticeChannelId,
      );
    });

    test('channel names are translated', () async {
      for (final tr in [await AppLocale.zhCn.build(), await AppLocale.zhTw.build(), await AppLocale.en.build()]) {
        final names = NoticeCategory.values.map((c) => noticeChannelName(tr, c));
        expect(names.toSet(), hasLength(NoticeCategory.values.length));
        expect(names.every((e) => e.isNotEmpty), isTrue);
        expect(tr.settingsPage.behaviorSection.noticeCategories.quietHours, isNotEmpty);
      }
    });
  });

  group('settings', () {
    late AppDatabase db;
    late StorageProvider storage;
    late SettingsRepository settings;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      await settings.init();
    });

    tearDown(() async {
      await settings.dispose();
      await db.close();
    });

    test('a table without the keys (older version) announces everything, no quiet hours', () async {
      final rules = await NotificationPushRules.read(storage);
      expect(rules.enabled, NoticeCategory.values.toSet());
      expect(rules.quietHours, isFalse);
      expect(rules.quietStart, 23 * 60);
      expect(rules.quietEnd, 8 * 60);
      final map = settings.currentSettings;
      expect(
        [map.notifyReply, map.notifyMention, map.notifyRate, map.notifyPersonalMessage, map.notifySystem],
        everyElement(isTrue),
      );
      expect(map.notifyQuietHours, isFalse);
    });

    test('changes are read by the next sync without a restart', () async {
      await settings.setValue(SettingsKeys.notifyMention, false);
      await settings.setValue(SettingsKeys.notifyQuietHours, true);
      await settings.setValue(SettingsKeys.notifyQuietStart, 60);
      await settings.setValue(SettingsKeys.notifyQuietEnd, 120);
      // The service reads through a provider of its own on the same table.
      final other = StorageProvider(db, {}, {});
      final rules = await NotificationPushRules.read(other);
      expect(rules.enabled, NoticeCategory.values.toSet()..remove(NoticeCategory.mention));
      expect(rules.quietHours, isTrue);
      expect(rules.isQuiet(_at(1, 30)), isTrue);
      expect(rules.isQuiet(_at(2, 0)), isFalse);

      await settings.setValue(SettingsKeys.notifyMention, true);
      expect((await NotificationPushRules.read(other)).enabled, NoticeCategory.values.toSet());
    });

    test('the repository keeps the values', () async {
      await settings.setValue(SettingsKeys.notifyRate, false);
      await settings.setValue(SettingsKeys.notifyQuietEnd, 400);
      expect(settings.currentSettings.notifyRate, isFalse);
      expect(settings.currentSettings.notifyQuietEnd, 400);
      final reread = SettingsRepository(StorageProvider(db, {}, {}));
      await reread.init();
      addTearDown(reread.dispose);
      expect(reread.currentSettings.notifyRate, isFalse);
      expect(reread.currentSettings.notifyQuietEnd, 400);
    });
  });
}
