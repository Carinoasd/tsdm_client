import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/notification/bloc/notification_state_cubit.dart';
import 'package:tsdm_client/features/notification/repository/notification_info_repository.dart';
import 'package:tsdm_client/features/profile/utils/parse_profile.dart';
import 'package:tsdm_client/instance.dart';
import 'package:universal_html/parsing.dart';

/// Page headers captured from Discuz! X5: `ul#myprompt_menu` comes first and repeats `a#pm_ntc` without `.new`.
void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  test('header with unread notices and messages', () {
    final doc = parseHtmlDocument(File('test/data/header_unread_x5.html').readAsStringSync());
    expect(doc.querySelectorAll('a#pm_ntc'), hasLength(2), reason: 'X5 renders the anchor twice');
    expect(buildUnreadInfoStatus(doc), (3, true));
  });

  test('header without unread items', () {
    final doc = parseHtmlDocument(File('test/data/header_read_x5.html').readAsStringSync());
    expect(buildUnreadInfoStatus(doc), (0, false));
  });

  test('server hint only raises unread counts', () async {
    final repo = NotificationInfoRepository();
    addTearDown(repo.dispose);
    final seen = <NotificationStateInfo>[];
    final sub = repo.status.listen(seen.add);
    addTearDown(sub.cancel);

    repo
      ..applyServerHint(noticeCount: 3, hasPersonalMessage: true)
      ..updateInfo(unreadNoticeCount: 5, unreadPersonalMessageCount: 0, unreadBroadcastMessageCount: 2)
      ..applyServerHint(noticeCount: 1, hasPersonalMessage: false);
    await Future<void>.delayed(Duration.zero);

    expect(seen.map((e) => (e.notice, e.personalMessage, e.broadcastMessage)), [(3, 1, 0), (5, 0, 2)]);
  });
}
