// With every account announced ("通知所有帐号", `backgroundSyncAllAccounts`), the notifications of the auto sync name
// their account in the title (`[name] …`), but the outcome of a reply sent from a notification ("回复未发送", "已回复",
// the unknown one) did not: on a device with several accounts it did not tell which account replied.
//
// The outcomes follow the rule of the other notifications: named only when every account is announced and the name is
// known; the notification the reply was typed in, closed with the outcome, says the same title.
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/local_notice/direct_reply.dart';
import 'package:tsdm_client/features/local_notice/keys.dart';
import 'package:tsdm_client/features/local_notice/show.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';

void main() {
  late Translations tr;

  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    tr = await AppLocale.zhCn.build();
  });

  const request = DirectReplyRequest(
    uid: 1000,
    target: LocalNoticeTarget(nid: 5, tid: 9600001, pid: 9700002, title: 'T'),
    message: '好的',
  );
  final outcomes = <(String, DirectReplyOutcome, String Function())>[
    ('sent', const DirectReplySent(), () => tr.localNotification.directReply.sent),
    ('not sent', const DirectReplyNotSent('x'), () => tr.localNotification.directReply.failed),
    ('unknown', const DirectReplyUnconfirmed(), () => tr.localNotification.directReply.unconfirmed),
  ];

  group('the title of an outcome', () {
    for (final (label, outcome, title) in outcomes) {
      test('$label: named like the other notifications when every account is announced', () {
        const named = LocalNoticeAccount(uid: 1000, username: 'Alice', named: true);
        expect(directReplyOutcomeContentOf(tr, request, outcome, account: named).title, '[Alice] ${title()}');
        expect(repliedNoticeToldOf(tr, request, outcome, account: named).title, '[Alice] ${title()}');
      });

      test('$label: as it was otherwise', () {
        for (final account in [
          null,
          const LocalNoticeAccount(uid: 1000, username: 'Alice'),
          const LocalNoticeAccount(uid: 1000, named: true),
          const LocalNoticeAccount(uid: 1000, username: '', named: true),
        ]) {
          expect(directReplyOutcomeContentOf(tr, request, outcome, account: account).title, title());
          expect(repliedNoticeToldOf(tr, request, outcome, account: account).title, title());
        }
      });
    }

    test('the same rule as the notification of the auto sync', () {
      const info = NotificationAutoSyncInfoNotice(
        msg: 'm',
        notice: 1,
        personalMessage: 0,
        broadcastMessage: 0,
        timestamp: 1700000000,
      );
      for (final account in [
        const LocalNoticeAccount(uid: 1000, username: 'Alice', named: true),
        const LocalNoticeAccount(uid: 1000, username: 'Alice'),
      ]) {
        final notice = localNotificationContentOf(tr, info, account: account).title;
        final failed = directReplyOutcomeContentOf(tr, request, const DirectReplyNotSent('x'), account: account).title;
        expect(notice.startsWith('[Alice] '), failed.startsWith('[Alice] '), reason: '${account.named}');
      }
    });
  });

  group('the account of a reply', () {
    Future<List<UserLoginInfo>> users() async => const [
      UserLoginInfo(username: 'Alice', uid: 1000),
      UserLoginInfo(username: 'Bob', uid: 2000),
    ];

    test('named with its saved name when every account is announced', () async {
      final account = await directReplyAccountOf(2000, allAccounts: () async => true, users: users);
      expect((account.uid, account.username, account.named), (2000, 'Bob', true));
    });

    test('not named when only the account in use is announced', () async {
      final account = await directReplyAccountOf(2000, allAccounts: () async => false, users: users);
      expect(account.named, isFalse);
    });

    test('not named when the setting or the accounts can not be read', () async {
      for (final account in [
        await directReplyAccountOf(2000, allAccounts: () async => throw StateError('db'), users: users),
        await directReplyAccountOf(2000, allAccounts: () async => true, users: () async => throw StateError('db')),
      ]) {
        expect((account.uid, account.named), (2000, false));
      }
    });

    test('an account no longer saved has no name: the title stays plain', () async {
      final account = await directReplyAccountOf(3000, allAccounts: () async => true, users: users);
      expect(account.username, isNull);
      expect(
        directReplyOutcomeContentOf(tr, request, const DirectReplyNotSent('x'), account: account).title,
        tr.localNotification.directReply.failed,
      );
    });
  });
}
