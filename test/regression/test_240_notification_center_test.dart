/// The notification center (UX audit, item 4).
///
/// * Data: the notice of `notify` keeps `author`, `from_id` and `from_idtype`; the notice page reads the author's
///   name from the author's link. Stored in schema 16, a copy read from the page keeps the API fields of the same
///   revision.
/// * Kinds: the forum's `type` / `from_idtype` values give the icon and the title of a card; the card opens the floor
///   of its first "find post" link (else its thread), offers a quick reply for replies, quotes, mentions and comments,
///   shows a relative time; lists are grouped by today, yesterday, earlier.
/// * The page: one "mark all as read", a local search, an empty state per tab.
/// * System notifications: who did what in the title and the body, several items listed (inbox style), the newest of
///   a kind announced (the forum lists them newest first), the payload naming the floor or the conversation of a
///   single item; a tap opens it.
/// * Accounts: the account cards of "sync all accounts" open the notice page as that account, the avatar menu shows
///   the unread notifications of the other accounts.
///
/// The notes are shaped like the forum's own (`home_notification.note`), with made-up users and threads.
///
/// Screenshots: with `NOTICE_SHOTS_DIR` (output directory) and `NOTICE_SHOTS_FONT` (a font file with CJK glyphs) set,
/// the last group writes the notice page (light and dark) and the system notification styles as png files.
library;

// The notes are written as the forum prints them, pieces of one html string.
// ignore_for_file: missing_whitespace_between_adjacent_strings, no_adjacent_strings_in_list

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/blocking/cubit/user_block_cubit.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/features/homepage/widgets/user_operation_dialog.dart';
import 'package:tsdm_client/features/local_notice/keys.dart';
import 'package:tsdm_client/features/local_notice/show.dart';
import 'package:tsdm_client/features/local_notice/tap.dart';
import 'package:tsdm_client/features/multi_user/utils/switch_account.dart';
import 'package:tsdm_client/features/notification/bloc/auto_notification_cubit.dart';
import 'package:tsdm_client/features/notification/bloc/notification_bloc.dart';
import 'package:tsdm_client/features/notification/bloc/notification_state_cubit.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/features/notification/repository/notification_info_repository.dart';
import 'package:tsdm_client/features/notification/repository/notification_repository.dart';
import 'package:tsdm_client/features/notification/utils/auto_sync_info.dart';
import 'package:tsdm_client/features/notification/utils/notice_info.dart';
import 'package:tsdm_client/features/notification/utils/relative_time.dart';
import 'package:tsdm_client/features/notification/view/notification_page.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/shared/repositories/fragments_repository/fragments_repository.dart';
import 'package:tsdm_client/themes/app_themes.dart';
import 'package:tsdm_client/widgets/card/notice_card_v2.dart';
import 'package:tsdm_client/widgets/heroes.dart';
import 'package:universal_html/parsing.dart';

const _alice = UserLoginInfo(username: 'Alice', uid: 1000);
const _bob = UserLoginInfo(username: 'Bob', uid: 1001);

/// The device's "now" of every relative time here: 2026-10-23 15:00.
///
/// The member's wall clock (offset 8), read as the device's local time like every stored notification time.
final _now = DateTime(2026, 10, 23, 15);

/// The device's clock at [_now]: the same moment, whatever the zone the test runs in.
final _deviceNow = DateTime.utc(2026, 10, 23, 7);

/// A stored time (the member's wall clock read as local time) in seconds.
int _secondsAt(DateTime t) => t.millisecondsSinceEpoch ~/ 1000;

/// The real time (a `dateline` of the forum) when the wall clock of a member at +8 shows [wall].
int _apiSeconds(DateTime wall) =>
    DateTime.utc(
      wall.year,
      wall.month,
      wall.day,
      wall.hour,
      wall.minute,
      wall.second,
    ).subtract(const Duration(hours: 8)).millisecondsSinceEpoch ~/
    1000;

/// Notes of the forum (`home_notification.note`), one per kind, with made-up users and threads.
const _replyNote =
    '<a href="home.php?mod=space&uid=2001">Carol</a> 回复了您的帖子 '
    '<a href="forum.php?mod=redirect&goto=findpost&ptid=5001&pid=7001" target="_blank">合成主题 甲</a> &nbsp; '
    '<a href="forum.php?mod=redirect&goto=findpost&pid=7001&ptid=5001" target="_blank" class="lit">查看</a>';
const _atNote =
    '<a href="home.php?mod=space&uid=2002" target="_blank">Dave</a> 在主题 '
    '<a href="forum.php?mod=redirect&goto=findpost&ptid=5002&pid=7002" target="_blank">合成主题 乙</a> 中提到了您'
    '<div class="quote"><blockquote>@Alice 一起来看看这个</blockquote></div>'
    '<a href="forum.php?mod=redirect&goto=findpost&ptid=5002&pid=7002" target="_blank">现在去看看</a>。';
const _rateNote =
    '您在主题 <a href="forum.php?mod=redirect&goto=findpost&pid=7003&ptid=5003" target="_blank">合成主题 丙</a> '
    '的帖子被 <a href="home.php?mod=space&uid=2003">Erin</a> 评分 威望 +1 '
    '<div class="quote"><blockquote>写得好</blockquote></div>';
const _friendRequestNote =
    '<a href="home.php?mod=space&uid=2004">Frank</a> 请求加您为好友，附言：你好&nbsp;&nbsp;'
    '<a onclick="showWindow(this.id, this.href, \'get\', 0);" class="xw1" id="afr_2004" '
    'href="home.php?mod=spacecp&ac=friend&op=add&uid=2004&from=notice">批准申请</a>';
const _systemNote =
    '您发表的主题 <a href="forum.php?mod=viewthread&tid=5005" target="_blank">合成主题 戊</a> 已由管理团队 审核通过！ '
    '&nbsp; <a href="forum.php?mod=viewthread&tid=5005" target="_blank" class="lit">查看 &rsaquo;</a>';
const _medalNote = '恭喜您获得了勋章「合成勋章」（永久）！发放理由：测试';
const _wallNote =
    '<a href="home.php?mod=space&uid=2006">Grace</a> 在留言板上给您 '
    '<a href="home.php?mod=space&uid=1000&do=wall&cid=6&goto=new#comment_6_li" target="_blank">留言</a>';
const _moderationNote =
    '您的主题 <a href="forum.php?mod=viewthread&tid=5007" target="_blank">合成主题 庚</a> 被 '
    '<a href="home.php?mod=space&uid=2007">Heidi</a> 关闭 <div class="quote"><blockquote>请勿重复发帖</blockquote></div>';

/// A notice of `notify` (plugin 1.9.0 and later).
Map<String, Object?> _api(
  int id,
  String note, {
  required String type,
  required int authorId,
  String author = '',
  int fromId = 0,
  String fromIdType = '',
  int? dateline,
  bool unread = true,
}) => {
  'id': id,
  'new': unread ? 1 : 0,
  'type': type,
  'category': authorId == 0 ? 3 : 1,
  'authorid': authorId,
  'author': author,
  'note': note,
  'text': '',
  'dateline': dateline ?? _apiSeconds(_now.subtract(const Duration(minutes: 3))),
  'from_id': fromId,
  'from_idtype': fromIdType,
  'from_num': 1,
};

NoticeV2 _fromApi(Map<String, Object?> json) => Notice.toV2FromApi(json, timeOffset: 8)!;

/// The notice page of [notes] (Discuz X5 markup): `(id, authorId, type, note)`.
String _noticePage(List<(int, int, String, String)> notes) {
  final rows = [
    for (final (id, authorId, type, note) in notes)
      '<dl class="cl " notice="$id" id="notice_$id"><dt><a class="d b" '
          'href="home.php?mod=spacecp&amp;ac=common&amp;op=ignore&amp;authorid=$authorId&amp;type=$type&amp;'
          'handlekey=noticeignore" id="a_note_$id">屏蔽</a><span class="xg1 xw0"><span title="2026-10-23 14:57">3 分钟前'
          '</span></span></dt><dd class="ntc_body" style="color:#000;font-weight:bold;">$note</dd></dl>',
  ];
  return '<html><body><div class="nts">${rows.join()}</div></body></html>';
}

final class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

final class _Auth extends Fake implements AuthenticationRepository {
  _Auth(this.currentUser);

  @override
  UserLoginInfo? currentUser;

  final _controller = StreamController<AuthStatus>.broadcast(sync: true);

  @override
  Stream<AuthStatus> get status => _controller.stream;

  @override
  AuthStatus? get latestStatus => null;

  @override
  int? get effectiveCurrentUid => currentUser?.uid;

  @override
  UserLoginInfo? get effectiveCurrentUser => currentUser;

  Future<void> close() => _controller.close();
}

/// The notification bloc of the page: its state is pushed by the test, its events recorded.
final class _Notifications extends Fake implements NotificationBloc {
  _Notifications(this._state);

  NotificationState _state;
  final _controller = StreamController<NotificationState>.broadcast(sync: true);
  final events = <NotificationEvent>[];

  @override
  NotificationState get state => _state;

  @override
  Stream<NotificationState> get stream => _controller.stream;

  @override
  bool get isClosed => false;

  void push(NotificationState next) {
    _state = next;
    _controller.add(next);
  }

  @override
  void add(NotificationEvent event) => events.add(event);

  @override
  Future<void> close() => _controller.close();
}

Future<void> _settle(WidgetTester tester, {int rounds = 6}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// The list of the page and of the screenshots: every kind, over three days.
List<NoticeV2> _sampleNotices() => [
  _fromApi(
    _api(
      1,
      _replyNote,
      type: 'post',
      authorId: 2001,
      author: 'Carol',
      fromId: 5001,
      fromIdType: 'post',
      dateline: _apiSeconds(_now.subtract(const Duration(minutes: 3))),
    ),
  ),
  _fromApi(
    _api(
      2,
      _atNote,
      type: 'at',
      authorId: 2002,
      author: 'Dave',
      fromId: 5002,
      fromIdType: 'at',
      dateline: _apiSeconds(_now.subtract(const Duration(hours: 2))),
    ),
  ),
  _fromApi(
    _api(
      3,
      _rateNote,
      type: 'rate',
      authorId: 2003,
      author: 'Erin',
      fromIdType: 'rate',
      dateline: _apiSeconds(DateTime(2026, 10, 22, 12, 30)),
      unread: false,
    ),
  ),
  _fromApi(
    _api(
      4,
      _friendRequestNote,
      type: 'friend',
      authorId: 2004,
      author: 'Frank',
      fromId: 2004,
      fromIdType: 'friendrequest',
      dateline: _apiSeconds(DateTime(2026, 10, 22, 9, 5)),
      unread: false,
    ),
  ),
  _fromApi(
    _api(
      5,
      _systemNote,
      type: 'system',
      authorId: 0,
      fromIdType: 'modthreads',
      dateline: _apiSeconds(DateTime(2026, 10, 20, 18, 40)),
      unread: false,
    ),
  ),
  // An older plugin: no type, no author; the card is the generic one, still tappable.
  NoticeV2(
    id: 6,
    timestamp: _secondsAt(DateTime(2026, 10, 18, 8, 15)),
    data: parseHtmlDocument('<html><body>$_medalNote</body></html>').body!.innerHtml!,
    alreadyRead: true,
  ),
];

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.zhCn);
  });

  group('data', () {
    test('a notice of notify keeps author, from_id and from_idtype; a system notice has no author', () {
      final reply = _fromApi(
        _api(1, _replyNote, type: 'post', authorId: 2001, author: 'Carol', fromId: 5001, fromIdType: 'post'),
      );
      expect((reply.ignoreType, reply.authorId, reply.author), ('post', 2001, 'Carol'));
      expect((reply.fromId, reply.fromIdType), (5001, 'post'));

      final system = _fromApi(_api(2, _systemNote, type: 'system', authorId: 0, fromIdType: 'modthreads'));
      expect((system.ignoreType, system.authorId, system.author), ('system', 0, null));
      expect((system.fromId, system.fromIdType), (null, 'modthreads'), reason: 'from_id 0 is none');

      // An older plugin without `author`: the name of the author's link, as the page reads it.
      final old = _fromApi(_api(3, _replyNote, type: 'post', authorId: 2001)..remove('author'));
      expect(old.author, 'Carol');
    });

    test('the author is the user the body links for authorid, not the `author` column', () {
      // A reply held for moderation is announced by the moderator's request: authorid is the replier, the column is
      // the moderator's name.
      final moderated = _fromApi(
        _api(1, _replyNote, type: 'post', authorId: 2001, author: 'Moderator', fromId: 5001, fromIdType: 'post'),
      );
      expect((moderated.authorId, moderated.author), (2001, 'Carol'));
      expect(NoticeInfo.of(moderated).author, 'Carol');
      // A row stored by the first version with the column's name: the body wins as well.
      expect(NoticeInfo.of(moderated.copyWith(author: 'Moderator')).author, 'Carol');
      // The column is only used when the body links no such user.
      final noLink = _fromApi(_api(2, _medalNote, type: 'medal', authorId: 2008, author: 'Ivy'));
      expect(noLink.author, 'Ivy');
    });

    test('the notice page reads the author from the link of the author only', () {
      final doc = parseHtmlDocument(
        _noticePage([
          (1, 2001, 'post', _replyNote),
          (2, 2003, 'rate', _rateNote),
          (3, 2006, 'wall', _wallNote),
          (4, 0, 'system', _systemNote),
          // A moderation notice has no author (0) and names the moderator: not taken.
          (5, 0, 'post', _moderationNote),
        ]),
      );
      final notices = NotificationV2.noticeNodes(doc).map(Notice.toV2).toList();
      expect(notices.map((e) => e?.author), ['Carol', 'Erin', 'Grace', null, null]);
      expect(notices.map((e) => (e?.fromId, e?.fromIdType)).toSet(), {(null, null)}, reason: 'not on the page');
    });

    test('the unread count of another account uses the window of the badge', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final storage = StorageProvider(db, {}, {});
      // 501 notices: the oldest one unread, out of the newest 500 the badge counts.
      await storage
          .saveNotification(
            uid: 1001,
            notificationGroup: NotificationGroup(
              noticeList: [
                for (var id = 1; id <= 501; id++)
                  NoticeEntity(uid: 1001, nid: id, timestamp: 1000 + id, data: 'n', alreadyRead: id != 1),
                const NoticeEntity(uid: 1001, nid: 600, timestamp: 9999, data: 'n'),
              ],
              personalMessageList: const [],
              broadcastMessageList: const [
                BroadcastMessageEntity(uid: 1001, timestamp: 1, data: 'b', pmid: 1, alreadyRead: false),
              ],
            ),
          )
          .run();
      final badge = await countUnreadNotification(storage: storage, uid: 1001);
      final total = await countUnreadNotificationTotal(storage: storage, uid: 1001);
      expect(total, badge.notice + badge.personalMessage + badge.broadcastMessage);
      expect(total, 2, reason: 'the newest notice (no read state counts as unread) and the broadcast message');
    });

    test('a copy from the notice page keeps the API fields of the same revision only', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final storage = StorageProvider(db, {}, {});
      NoticeEntity entity(NoticeV2 e) => NoticeEntity(
        uid: 1000,
        nid: e.id,
        timestamp: e.timestamp,
        data: e.data,
        alreadyRead: e.alreadyRead,
        ignoreType: e.ignoreType,
        authorId: e.authorId,
        author: e.author,
        fromId: e.fromId,
        fromIdType: e.fromIdType,
      );
      Future<void> save(NoticeV2 e) => storage
          .saveNotification(
            uid: 1000,
            notificationGroup: NotificationGroup(
              noticeList: [entity(e)],
              personalMessageList: const [],
              broadcastMessageList: const [],
            ),
          )
          .run();
      Future<NoticeEntity> stored() async =>
          (await storage.fetchNotificationSince(uid: 1000, timestamp: 0).run()).noticeList.single;

      final api = _fromApi(
        _api(1, _replyNote, type: 'post', authorId: 2001, author: 'Carol', fromId: 5001, fromIdType: 'quote'),
      );
      await save(api);
      expect(((await stored()).author, (await stored()).fromId, (await stored()).fromIdType), ('Carol', 5001, 'quote'));

      // The same notice read from the page: no from_id / from_idtype there.
      await save(api.copyWith(fromId: null, fromIdType: null));
      expect(((await stored()).fromId, (await stored()).fromIdType), (5001, 'quote'), reason: 'same revision');

      // A newer revision (merged notice, newer time) read from the page: unknown, not inherited.
      await save(api.copyWith(fromId: null, fromIdType: null, timestamp: api.timestamp + 60));
      expect(((await stored()).fromId, (await stored()).fromIdType), (null, null));
      expect((await stored()).author, 'Carol', reason: 'the page read it from the body');
    });
  });

  group('kinds', () {
    test('the type and from_idtype values of the forum', () {
      const floor = NoticeTarget(tid: 1, pid: 2);
      for (final (type, fromIdType, target, kind) in <(String?, String?, NoticeTarget?, NoticeKind)>[
        ('post', 'post', floor, NoticeKind.reply),
        ('post', 'quote', floor, NoticeKind.quote),
        ('post', 'moderate_关闭', null, NoticeKind.moderation),
        ('post', 'moderate_DLP', null, NoticeKind.moderation),
        ('post', null, floor, NoticeKind.reply),
        ('post', null, null, NoticeKind.post),
        ('at', 'at', floor, NoticeKind.mention),
        ('at', 'atplusgroup', floor, NoticeKind.mention),
        ('rate', 'rate', floor, NoticeKind.rate),
        ('ratetrack', null, floor, NoticeKind.rate),
        ('pcomment', 'pcomment', floor, NoticeKind.comment),
        ('friend', 'friendrequest', null, NoticeKind.friendRequest),
        ('friend', null, null, NoticeKind.friend),
        ('poke', 'pokequery', null, NoticeKind.poke),
        ('wall', 'uid', null, NoticeKind.wall),
        ('reward', null, null, NoticeKind.reward),
        ('activity', null, null, NoticeKind.activity),
        ('medal', null, null, NoticeKind.medal),
        ('magic', null, null, NoticeKind.magic),
        ('system', 'dsumedal', null, NoticeKind.system),
        ('system', 'changeusergroup', null, NoticeKind.system),
        ('report', 'newreport', null, NoticeKind.manage),
        ('pmreport', null, null, NoticeKind.manage),
        ('verifythread', 'verifythread', null, NoticeKind.manage),
        ('somethingnew', null, null, NoticeKind.generic),
        (null, null, floor, NoticeKind.generic),
      ]) {
        expect(
          noticeKindOf(type: type, fromIdType: fromIdType, target: target),
          kind,
          reason: '$type $fromIdType',
        );
      }
      // The notice page has no from_idtype: a friend request is told by its approve link.
      expect(noticeKindOf(type: 'friend', body: _friendRequestNote), NoticeKind.friendRequest);
    });

    test('what a card shows of a notice', () {
      final notices = _sampleNotices();
      final reply = NoticeInfo.of(notices[0]);
      expect((reply.kind, reply.author, reply.authorId), (NoticeKind.reply, 'Carol', 2001));
      expect((reply.target, reply.threadTitle), (const NoticeTarget(tid: 5001, pid: 7001), '合成主题 甲'));
      expect(reply.text, 'Carol 回复了您的帖子 合成主题 甲', reason: 'without the trailing view link');

      final at = NoticeInfo.of(notices[1]);
      expect(
        (at.kind, at.target, at.quote),
        (NoticeKind.mention, const NoticeTarget(tid: 5002, pid: 7002), '@Alice 一起来看看这个'),
      );
      expect(at.threadTitle, '合成主题 乙', reason: 'the thread link, not the author link');

      final friend = NoticeInfo.of(notices[3]);
      expect((friend.kind, friend.target), (NoticeKind.friendRequest, null));

      final system = NoticeInfo.of(notices[4]);
      expect((system.kind, system.author, system.authorId), (NoticeKind.system, null, null));
      expect(system.target, const NoticeTarget(tid: 5005), reason: 'the thread when no floor is linked');

      final old = NoticeInfo.of(notices[5]);
      expect((old.kind, old.target), (NoticeKind.generic, null));
      expect(noticeKindRepliable(reply.kind) && noticeKindRepliable(at.kind), isTrue);
      expect(
        noticeKindRepliable(NoticeKind.rate) ||
            noticeKindRepliable(NoticeKind.system) ||
            noticeKindRepliable(NoticeKind.comment),
        isFalse,
        reason: 'a comment links the own floor',
      );
    });
  });

  group('relative time', () {
    test('"now" is the member\'s wall clock, like the stored times', () {
      // The device at New York or Tokyo: the same moment, the same member clock.
      expect(memberNowOf(_deviceNow, 8), _now);
      expect(memberNowOf(_deviceNow, 9), _now.add(const Duration(hours: 1)));
      expect(memberNowOf(_deviceNow, -5), DateTime(2026, 10, 23, 2));
      // A notice of 3 minutes ago for a member at +8, stored the way the API path stores it.
      final stored = DateTime.fromMillisecondsSinceEpoch(
        apiTimeOf(_deviceNow.subtract(const Duration(minutes: 3)).millisecondsSinceEpoch ~/ 1000, 8) * 1000,
      );
      expect(_now.difference(stored), const Duration(minutes: 3));
      expect(NotificationTimeOffsets.of(null), 8);
    });

    test('just now, minutes, hours, yesterday, this year, before', () async {
      final tr = await AppLocale.zhCn.build();
      String at(DateTime t) => relativeTimeOf(tr, t, now: _now);
      expect(at(_now.subtract(const Duration(seconds: 30))), '刚刚');
      expect(at(_now.add(const Duration(minutes: 2))), '刚刚', reason: 'a few minutes ahead of the device clock');
      expect(at(_now.add(const Duration(minutes: 30))), '10-23 15:30', reason: 'further ahead: the time itself');
      expect(at(_now.subtract(const Duration(minutes: 3))), '3 分钟前');
      expect(at(_now.subtract(const Duration(hours: 2, minutes: 10))), '2 小时前');
      expect(at(DateTime(2026, 10, 22, 12, 30)), '昨天 12:30');
      expect(at(DateTime(2026, 9, 3, 8, 15)), '9-3 08:15');
      expect(at(DateTime(2025, 12, 31, 23, 59)), '2025-12-31 23:59');
      expect(
        [
          DateTime(2026, 10, 23),
          DateTime(2026, 10, 22, 23, 59),
          DateTime(2026, 10, 22),
          DateTime(2026, 10, 21, 23, 59),
        ].map((e) => notificationDayOf(e, _now)),
        [NotificationDay.today, NotificationDay.yesterday, NotificationDay.yesterday, NotificationDay.earlier],
      );
    });
  });

  group('system notification', () {
    late Translations tr;
    setUpAll(() async => tr = await AppLocale.zhCn.build());

    const empty = NotificationV2.empty;
    PersonalMessageV2 pm(int t, String user, String msg, int peer) => PersonalMessageV2(
      timestamp: t,
      data: msg,
      peerUid: peer,
      peerUsername: user,
      sender: false,
      alreadyRead: false,
    );

    test('the newest of a kind is announced, not the last of the list (the forum lists newest first)', () {
      final notices = _sampleNotices();
      // Newest first, as notify and the notice page give them.
      final n = autoSyncInfoOf(empty.copyWith(noticeList: [notices[0], notices[1]]))! as NotificationAutoSyncInfoNotice;
      expect((n.nid, n.author, n.pid), (1, 'Carol', 7001));
      // Whatever the order.
      final m = autoSyncInfoOf(empty.copyWith(noticeList: [notices[1], notices[0]]))! as NotificationAutoSyncInfoNotice;
      expect(m.nid, 1);
      final p =
          autoSyncInfoOf(
                empty.copyWith(personalMessageList: [pm(200, 'Bob', 'new', 1001), pm(100, 'Ivan', 'old', 1002)]),
              )!
              as NotificationAutoSyncInfoPm;
      expect((p.user, p.msg, p.peerUid), ('Bob', 'new', 1001));
    });

    test('a single notice: who did what, the thread, and a tap to its floor', () {
      final info = autoSyncInfoOf(empty.copyWith(noticeList: [_sampleNotices()[0]]))!;
      final content = localNotificationContentOf(tr, info, account: const LocalNoticeAccount(uid: 1000));
      expect(content.title, 'Carol 回复了你的帖子');
      expect(content.body, '《合成主题 甲》');
      expect(content.lines, isEmpty, reason: 'one item: no list');
      // Not every account is announced, the payload still names the account: the item is that account's.
      expect(content.id, localNoticeId);
      expect(LocalNoticeKeys.parseOpenNotification(content.payload), (uid: 1000));
      expect(LocalNoticeKeys.parseTarget(content.payload), const LocalNoticeTarget(nid: 1, tid: 5001, pid: 7001));
      // Without an account (the test notification of the settings page) there is no target.
      expect(LocalNoticeKeys.parseTarget(localNotificationContentOf(tr, info).payload), isNull);

      // Every account announced: the account first, its own payload.
      final named = localNotificationContentOf(
        tr,
        info,
        account: const LocalNoticeAccount(uid: 1000, username: 'Alice', named: true),
      );
      expect(named.title, '[Alice] Carol 回复了你的帖子');
      expect(LocalNoticeKeys.parseOpenNotification(named.payload), (uid: 1000));
      expect(LocalNoticeKeys.parseTarget(named.payload)?.pid, 7001);

      // A mention quotes the post.
      const alice = LocalNoticeAccount(uid: 1000);
      final at = localNotificationContentOf(
        tr,
        autoSyncInfoOf(empty.copyWith(noticeList: [_sampleNotices()[1]]))!,
        account: alice,
      );
      expect((at.title, at.body), ('Dave 提到了你', '《合成主题 乙》 @Alice 一起来看看这个'));

      // A system notice: the forum's own sentence.
      final system = localNotificationContentOf(
        tr,
        autoSyncInfoOf(empty.copyWith(noticeList: [_sampleNotices()[4]]))!,
        account: alice,
      );
      expect((system.title, system.body), ('新提醒', '您发表的主题 合成主题 戊 已由管理团队 审核通过！'));
      expect(LocalNoticeKeys.parseTarget(system.payload), const LocalNoticeTarget(nid: 5, tid: 5005));
    });

    test('a single private message names the sender and opens the conversation', () {
      final info = autoSyncInfoOf(empty.copyWith(personalMessageList: [pm(100, 'Bob', '今晚一起看番吗', 1001)]))!;
      final content = localNotificationContentOf(tr, info, account: const LocalNoticeAccount(uid: 1000));
      expect((content.title, content.body), ('Bob 发来私信', '今晚一起看番吗'));
      expect(LocalNoticeKeys.parseOpenNotification(content.payload), (uid: 1000));
      expect(LocalNoticeKeys.parseTarget(content.payload), const LocalNoticeTarget(peerUid: 1001));
    });

    test('content hidden: the counts only, no list; the account still named; private on the lock screen', () {
      final notices = _sampleNotices();
      final one = autoSyncInfoOf(empty.copyWith(noticeList: [notices[0]]))!;
      final hidden = localNotificationContentOf(
        tr,
        one,
        account: const LocalNoticeAccount(uid: 1000, username: 'Alice', named: true),
        hideContent: true,
      );
      expect((hidden.title, hidden.body), ('[Alice] 新消息', '1 条提醒'));
      expect(hidden.lines, isEmpty);
      final several = localNotificationContentOf(
        tr,
        autoSyncInfoOf(
          empty.copyWith(
            noticeList: [notices[0], notices[1]],
            personalMessageList: [pm(100, 'Bob', '在吗', 1001)],
          ),
        )!,
        hideContent: true,
      );
      expect((several.title, several.body, several.summary), ('新消息', '2 条提醒 · 1 条私信', null));
      expect(several.lines, isEmpty);
      expect(several.body, isNot(contains('Bob')));

      final details = buildLocalNotificationDetails(channelName: 'c', channelDescription: 'd', ticker: 't');
      expect(details.android?.visibility, NotificationVisibility.private);

      // A long thread title is cut.
      final long = _fromApi(
        _api(
          9,
          _replyNote.replaceAll('合成主题 甲', '很长的合成主题' * 8),
          type: 'post',
          authorId: 2001,
          fromIdType: 'post',
        ),
      );
      final content = localNotificationContentOf(tr, autoSyncInfoOf(empty.copyWith(noticeList: [long]))!);
      expect(content.body.length, lessThanOrEqualTo(24 + 3 + 2), reason: '《…》 around at most 24 characters and "..."');
    });

    test('several items: listed newest first with the counts; a tap opens the notice page', () {
      final notices = _sampleNotices();
      final info = autoSyncInfoOf(
        empty.copyWith(
          noticeList: [notices[0], notices[1]],
          personalMessageList: [pm(_secondsAt(_now.subtract(const Duration(minutes: 1))), 'Bob', '在吗', 1001)],
          broadcastMessageList: [
            BroadcastMessageV2(timestamp: _secondsAt(DateTime(2026, 10, 2)), data: '站务公告', pmid: 3),
          ],
        ),
      )!;
      final content = localNotificationContentOf(tr, info);
      expect(content.title, 'Bob 发来私信', reason: 'a private message first, as before');
      expect(content.body, '在吗\n2 条提醒 · 1 条私信 · 1 条公共消息');
      expect(content.lines, hasLength(4));
      expect(content.lines[0], 'Bob：在吗');
      expect(content.lines[1], 'Carol 回复了您的帖子 合成主题 甲');
      expect(content.lines[2], startsWith('Dave 在主题 合成主题 乙 中提到了您'), reason: "the forum's text");
      expect(content.lines[3], '[公共消息] 站务公告');
      expect(content.summary, '2 条提醒 · 1 条私信 · 1 条公共消息');
      expect(LocalNoticeKeys.parseTarget(content.payload), isNull);
      expect(content.payload, LocalNoticeKeys.openNotification);
    });

    test('payloads: the account part reads as before, garbage has no target', () {
      const target = LocalNoticeTarget(nid: 1, tid: 2, pid: 3);
      final payload = LocalNoticeKeys.withTarget(LocalNoticeKeys.openNotificationOf(1000), target);
      expect(payload, 'openNotification:1000#nid=1&tid=2&pid=3');
      expect(LocalNoticeKeys.parseOpenNotification(payload), (uid: 1000));
      expect(LocalNoticeKeys.parseTarget(payload), target);
      expect(LocalNoticeKeys.parseTarget('openNotification#peer=7'), const LocalNoticeTarget(peerUid: 7));
      for (final bad in [
        'openNotification',
        'openNotification#x=1',
        'openNotification#pid=-1',
        'other#pid=3',
        // A malformed percent encoding (a crafted intent) throws an ArgumentError inside the parser.
        'openNotification:1000#tid=%zz',
        'openNotification:1000#tid=%E0%A4%A',
        null,
      ]) {
        expect(LocalNoticeKeys.parseTarget(bad), isNull, reason: '$bad');
      }
      expect(LocalNoticeKeys.parseOpenNotification('other#pid=3'), isNull);
    });
  });

  group('widgets', () {
    late AppDatabase db;
    late StorageProvider storage;
    late SettingsRepository settings;
    late SettingsBloc settingsBloc;
    late UserBlockRepository blocks;
    late _Auth auth;
    late NotificationInfoRepository info;
    late NotificationStateCubit counts;

    setUp(() async {
      notificationCardClock = () => _deviceNow;
      db = AppDatabase(NativeDatabase.memory());
      storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      getIt
        ..registerSingleton<StorageProvider>(storage)
        ..registerSingleton<SettingsRepository>(settings)
        ..registerSingleton<NetErrorSaver>(NetErrorSaver())
        ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
        ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
        ..registerSingleton<ImageCacheProvider>(
          ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _OfflineAdapter())),
        );
      await settings.init();
      settingsBloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository());
      blocks = UserBlockRepository(storage);
      auth = _Auth(_alice);
      info = NotificationInfoRepository();
      counts = NotificationStateCubit(info);
    });

    tearDown(() async {
      notificationCardClock = DateTime.now;
      await info.dispose();
      await counts.close();
      await settingsBloc.close();
      await blocks.dispose();
      await auth.close();
      await getIt.get<ImageCacheProvider>().dispose();
      await getIt.reset();
      await settings.dispose();
      await db.close();
    });

    /// The notice page (or [home]) with the app's providers and the routes a card opens, each route a page saying
    /// its location.
    Future<(GoRouter, _Notifications)> open(
      WidgetTester tester, {
      Widget? home,
      NotificationState? state,
      ThemeData? theme,
      Key? shotKey,
    }) async {
      tester.view
        ..physicalSize = const Size(390, 844)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final notifications = _Notifications(const NotificationState(status: NotificationStatus.loading));
      final blockCubit = UserBlockCubit(
        repository: blocks,
        currentUid: () => auth.currentUser?.uid,
        authStatus: auth.status,
        retryDelays: const [],
      );
      final auto = AutoNotificationCubit(
        authenticationRepository: auth,
        notificationRepository: NotificationRepository(storageProvider: storage),
        storageProvider: storage,
      );
      addTearDown(() async {
        await blockCubit.close();
        await auto.close();
        await notifications.close();
      });
      Widget page(GoRouterState s) => Scaffold(body: Center(child: Text('page ${s.uri}')));
      final router = GoRouter(
        routes: [
          GoRoute(path: '/', builder: (_, _) => home ?? const NotificationPage()),
          for (final path in [
            ScreenPaths.threadV1,
            ScreenPaths.reply,
            ScreenPaths.chatHistory,
            ScreenPaths.profile,
            ScreenPaths.rootNotice,
          ])
            GoRoute(path: path, name: path, builder: (_, s) => page(s)),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        TranslationProvider(
          child: MultiRepositoryProvider(
            providers: [
              RepositoryProvider<AuthenticationRepository>.value(value: auth),
              RepositoryProvider<NotificationInfoRepository>.value(value: info),
            ],
            child: MultiBlocProvider(
              providers: [
                BlocProvider<SettingsBloc>.value(value: settingsBloc),
                BlocProvider<UserBlockCubit>.value(value: blockCubit),
                BlocProvider<NotificationBloc>.value(value: notifications),
                BlocProvider<NotificationStateCubit>.value(value: counts),
                BlocProvider<AutoNotificationCubit>.value(value: auto),
              ],
              child: RepaintBoundary(
                key: shotKey,
                child: MaterialApp.router(
                  debugShowCheckedModeBanner: false,
                  theme: theme,
                  routerConfig: router,
                ),
              ),
            ),
          ),
        ),
      );
      await _settle(tester);
      notifications.push(
        state ?? NotificationState(status: NotificationStatus.success, noticeList: _sampleNotices(), ownerUid: 1000),
      );
      await _settle(tester);
      return (router, notifications);
    }

    Finder card(int id) => find.byKey(ValueKey('notice-card-$id'));
    final list = find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first;

    testWidgets('cards: author, kind and relative time; grouped by day', (tester) async {
      await open(tester);
      expect(find.text('Carol'), findsOneWidget);
      expect(find.text('回复 · 3 分钟前'), findsOneWidget);
      expect(find.text('提到了你 · 2 小时前'), findsOneWidget);
      // A system notice and an older plugin's notice: the kind is the title.
      await tester.scrollUntilVisible(card(6), 200, scrollable: list);
      expect(find.text('系统'), findsOneWidget);
      expect(find.text('提醒'), findsWidgets);
      expect(find.text('10-18 08:15'), findsOneWidget);
      await tester.scrollUntilVisible(find.byKey(const ValueKey('notice-day-today')), -200, scrollable: list);
      expect(find.byKey(const ValueKey('notice-day-today')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the whole card opens the floor and marks the notice read; quick reply opens the reply page', (
      tester,
    ) async {
      final (router, notifications) = await open(tester);
      // The text of the card, not a link in it.
      await tester.tap(find.text('回复 · 3 分钟前'));
      await _settle(tester);
      expect(router.state.uri.path, ScreenPaths.threadV1);
      expect(router.state.uri.queryParameters['pid'], '7001');
      expect(
        notifications.events.whereType<NotificationMarkReadRequested>().map((e) => e.recordMark),
        [const RecordMarkNotice(uid: 1000, nid: 1, alreadyRead: true)],
      );
      router.pop();
      await _settle(tester);

      final quickReply = find.byKey(const ValueKey('notice-quick-reply-1'));
      expect(quickReply, findsOneWidget);
      expect(find.byKey(const ValueKey('notice-quick-reply-3')), findsNothing, reason: 'a rate is not answered');
      await tester.tap(quickReply);
      await _settle(tester);
      expect(router.state.uri.path, startsWith('/reply/'));
      expect(Uri.decodeComponent(router.state.uri.path), contains('goto=findpost&pid=7001&ptid=5001'));
      expect(router.state.uri.queryParameters['noticeType'], '${NoticeType.reply.index}');
    });

    testWidgets('an older plugin: the generic card still opens its link', (tester) async {
      final (router, _) = await open(
        tester,
        state: NotificationState(
          status: NotificationStatus.success,
          ownerUid: 1000,
          noticeList: [
            NoticeV2(
              id: 9,
              timestamp: _secondsAt(_now.subtract(const Duration(minutes: 1))),
              data: parseHtmlDocument('<html><body>$_replyNote</body></html>').body!.innerHtml!,
            ),
          ],
        ),
      );
      expect(find.text('提醒'), findsWidgets, reason: 'no type: the generic title');
      expect(find.text('1 分钟前'), findsOneWidget);
      await tester.tap(find.text('1 分钟前'));
      await _settle(tester);
      expect(router.state.uri.queryParameters['pid'], '7001');
    });

    testWidgets('a list out of time order is grouped once per day', (tester) async {
      await open(
        tester,
        state: NotificationState(
          status: NotificationStatus.success,
          ownerUid: 1000,
          broadcastMessageList: [
            // Delivered now, stamped with the time it was written (#154): listed first.
            BroadcastMessageV2(timestamp: _secondsAt(_now.subtract(const Duration(days: 3))), data: 'old', pmid: 1),
            BroadcastMessageV2(timestamp: _secondsAt(_now.subtract(const Duration(hours: 1))), data: 'today', pmid: 2),
            BroadcastMessageV2(timestamp: _secondsAt(_now.subtract(const Duration(days: 5))), data: 'older', pmid: 3),
          ],
        ),
      );
      await tester.tap(find.text('公共消息'));
      await _settle(tester);
      expect(find.byKey(const ValueKey('notice-day-earlier')), findsOneWidget);
      expect(find.byKey(const ValueKey('notice-day-today')), findsOneWidget);
      expect(
        tester.getTopLeft(find.textContaining('today', findRichText: true)).dy,
        lessThan(tester.getTopLeft(find.textContaining('old', findRichText: true).first).dy),
      );
    });

    testWidgets('mark all as read, search and the empty states', (tester) async {
      final (_, notifications) = await open(tester);
      await tester.tap(find.byKey(const ValueKey('notice-mark-all-read')));
      await _settle(tester);
      expect(notifications.events.whereType<NotificationMarkAllReadRequested>(), hasLength(1));

      await tester.tap(find.byKey(const ValueKey('notice-search')));
      await _settle(tester);
      await tester.enterText(find.byKey(const ValueKey('notice-search-field')), 'dave');
      await _settle(tester);
      expect(find.text('Dave'), findsOneWidget);
      expect(find.text('Carol'), findsNothing);
      await tester.enterText(find.byKey(const ValueKey('notice-search-field')), '没有这个');
      await _settle(tester);
      expect(find.text('没有符合“没有这个”的内容'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('notice-search')));
      await _settle(tester);
      expect(find.text('Carol'), findsOneWidget, reason: 'closing the search shows everything again');

      await tester.tap(find.text('私人消息'));
      await _settle(tester);
      expect(find.text('还没有私人消息'), findsOneWidget);
      await tester.tap(find.text('公共消息'));
      await _settle(tester);
      expect(find.text('还没有公共消息'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('notice-unread-filter')));
      await _settle(tester);
      expect(find.text('没有未读公共消息'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a tapped system notification opens the floor, or the conversation, and marks it read', (
      tester,
    ) async {
      late BuildContext home;
      final (router, notifications) = await open(
        tester,
        home: Builder(
          builder: (context) {
            home = context;
            return const Scaffold(body: Text('home'));
          },
        ),
      );
      expect(openLocalNoticeTarget(home, const LocalNoticeTarget(nid: 1, tid: 5001, pid: 7001)), isTrue);
      await _settle(tester);
      expect(router.state.uri.path, ScreenPaths.threadV1);
      expect(router.state.uri.queryParameters['pid'], '7001');
      router.pop();
      await _settle(tester);

      expect(openLocalNoticeTarget(home, const LocalNoticeTarget(peerUid: 1001)), isTrue);
      await _settle(tester);
      expect(router.state.uri.path, '/chat/history/1001');
      expect(notifications.events.whereType<NotificationMarkReadRequested>().map((e) => e.recordMark), [
        const RecordMarkNotice(uid: 1000, nid: 1, alreadyRead: true),
        const RecordMarkPersonalMessage(uid: 1000, peerUid: 1001, alreadyRead: true),
      ]);
      expect(openLocalNoticeTarget(home, const LocalNoticeTarget(nid: 3)), isFalse, reason: 'nothing to open');

      // Through the account rules: the account in use, the target instead of the notice page.
      router.pop();
      await _settle(tester);
      final result = await openNoticePageOfAccount(
        home,
        uid: 1000,
        target: const LocalNoticeTarget(nid: 2, tid: 5002, pid: 7002),
      );
      await _settle(tester);
      expect((result.step, result.action), (LocalNoticeAccountStep.current, LocalNoticeTapAction.openTarget));
      expect(router.state.uri.queryParameters['pid'], '7002');
      router.pop();
      await _settle(tester);

      // A target naming no account (not a payload of this version) is never opened: the notice page instead.
      final noAccount = await openNoticePageOfAccount(home, uid: null, target: const LocalNoticeTarget(peerUid: 1001));
      await _settle(tester);
      expect(noAccount.action, LocalNoticeTapAction.openNoticePage);
      expect(router.state.uri.path, ScreenPaths.rootNotice);
      router.pop();
      await _settle(tester);

      // An item of another account (Bob's message, Alice in use): switched first; when the switch does not happen the
      // notice page of the account in use opens, never Bob's conversation as Alice.
      await tester.runAsync(
        () => storage.saveCookie(
          username: 'Bob',
          uid: 1001,
          cookie: {'.index': '["$baseHost"]', baseHost: '{"/":{"Ystv_2132_auth":"Ystv_2132_auth=bob; Path=/;_crt=1"}}'},
        ),
      );
      final switches = <int?>[];
      ({LocalNoticeAccountStep step, String? top, LocalNoticeTapAction? action})? other;
      unawaited(
        openNoticePageOfAccount(
          home,
          uid: 1001,
          target: const LocalNoticeTarget(peerUid: 2001),
          switchTo: (_, account) async {
            switches.add(account.uid);
            return SwitchAccountResult.failed;
          },
        ).then((e) => other = e),
      );
      await _settle(tester);
      expect(switches, [1001]);
      expect((other?.step, other?.action), (LocalNoticeAccountStep.notSwitched, LocalNoticeTapAction.openNoticePage));
      expect(router.state.uri.path, ScreenPaths.rootNotice);
      expect(
        notifications.events.whereType<NotificationMarkReadRequested>().where(
          (e) =>
              e.recordMark is RecordMarkPersonalMessage && (e.recordMark as RecordMarkPersonalMessage).peerUid == 2001,
        ),
        isEmpty,
        reason: 'nothing of Bob marked read as Alice',
      );
      // A reply or a post being sent (or another switch running): nothing is opened, the editor stays on top.
      for (final busy in [SwitchAccountResult.replyBusy, SwitchAccountResult.alreadySwitching]) {
        if (router.canPop()) {
          router.pop();
        }
        await _settle(tester);
        final before = router.state.uri.path;
        ({LocalNoticeAccountStep step, String? top, LocalNoticeTapAction? action})? held;
        unawaited(
          openNoticePageOfAccount(
            home,
            uid: 1001,
            target: const LocalNoticeTarget(peerUid: 2001),
            switchTo: (_, _) async => busy,
          ).then((e) => held = e),
        );
        await _settle(tester);
        expect((held?.step, held?.action), (LocalNoticeAccountStep.notSwitched, null), reason: busy.name);
        expect(router.state.uri.path, before, reason: busy.name);
      }

      // Switched: the item opens as Bob.
      ({LocalNoticeAccountStep step, String? top, LocalNoticeTapAction? action})? switched;
      unawaited(
        openNoticePageOfAccount(
          home,
          uid: 1001,
          target: const LocalNoticeTarget(peerUid: 2001),
          reloadTimeout: Duration.zero,
          switchTo: (_, account) async {
            auth.currentUser = _bob;
            return SwitchAccountResult.switched;
          },
        ).then((e) => switched = e),
      );
      await _settle(tester);
      expect((switched?.step, switched?.action), (LocalNoticeAccountStep.switched, LocalNoticeTapAction.openTarget));
      expect(router.state.uri.path, '/chat/history/2001');
      expect(
        notifications.events.whereType<NotificationMarkReadRequested>().last.recordMark,
        const RecordMarkPersonalMessage(uid: 1001, peerUid: 2001, alreadyRead: true),
      );
      auth.currentUser = _alice;
    });

    testWidgets('the avatar menu shows the unread notifications of the other accounts', (tester) async {
      for (final u in [_alice, _bob]) {
        // Only a logged in cookie is saved.
        await storage.saveCookie(
          username: u.username!,
          uid: u.uid!,
          cookie: {
            '.index': '["$baseHost"]',
            baseHost: '{"/":{"Ystv_2132_auth":"Ystv_2132_auth=${u.username!.toLowerCase()}; Path=/;_crt=1"}}',
          },
        );
      }
      await storage
          .saveNotification(
            uid: 1001,
            notificationGroup: NotificationGroup(
              noticeList: [
                for (final id in [1, 2, 3])
                  NoticeEntity(uid: 1001, nid: id, timestamp: 100 + id, data: 'n', alreadyRead: id == 3),
              ],
              personalMessageList: const [
                PersonalMessageEntity(
                  uid: 1001,
                  timestamp: 100,
                  data: 'hi',
                  peerUid: 2001,
                  peerUsername: 'Carol',
                  sender: false,
                  alreadyRead: false,
                ),
              ],
              broadcastMessageList: const [],
            ),
          )
          .run();
      await open(
        tester,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async => showHeroDialog(
                context,
                (context, _, _) => const UserOperationDialog(
                  username: 'Alice',
                  avatarUrl: null,
                  heroTag: 'Alice',
                  latestThreadUrl: null,
                ),
              ),
              child: const Text('menu'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('menu'));
      await _settle(tester, rounds: 10);
      expect(find.byType(UserOperationDialog), findsOneWidget);
      expect(find.byKey(const ValueKey('quick-switch-1001')), findsOneWidget, reason: 'the row of the other account');
      final badge = find.byKey(const ValueKey('quick-switch-unread-1001'));
      expect(badge, findsOneWidget);
      expect(
        find.descendant(of: badge, matching: find.text('3')),
        findsOneWidget,
        reason: '2 notices and 1 message',
      );
      expect(find.byKey(const ValueKey('quick-switch-unread-1000')), findsNothing, reason: 'the account in use');
      // The database stream timers fire before the framework checks for pending timers.
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('screenshots', () {
    final dir = Platform.environment['NOTICE_SHOTS_DIR'];
    final font = Platform.environment['NOTICE_SHOTS_FONT'];
    final skip = dir == null || font == null ? 'set NOTICE_SHOTS_DIR and NOTICE_SHOTS_FONT to write them' : null;
    const family = 'ShotSans';

    setUpAll(() async {
      if (skip != null) {
        return;
      }
      await (FontLoader(family)..addFont(Future.value(ByteData.sublistView(File(font!).readAsBytesSync())))).load();
      final root = Platform.environment['FLUTTER_ROOT'];
      final icons =
          Platform.environment['NOTICE_SHOTS_ICONS'] ??
          (root == null ? null : '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
      if (icons != null && File(icons).existsSync()) {
        await (FontLoader(
          'MaterialIcons',
        )..addFont(Future.value(ByteData.sublistView(File(icons).readAsBytesSync())))).load();
      }
    });

    late AppDatabase db;
    late StorageProvider storage;
    late SettingsRepository settings;
    late SettingsBloc settingsBloc;
    late UserBlockRepository blocks;
    late _Auth auth;
    late NotificationInfoRepository info;
    late NotificationStateCubit counts;

    setUp(() async {
      notificationCardClock = () => _deviceNow;
      db = AppDatabase(NativeDatabase.memory());
      storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      getIt
        ..registerSingleton<StorageProvider>(storage)
        ..registerSingleton<SettingsRepository>(settings)
        ..registerSingleton<NetErrorSaver>(NetErrorSaver())
        ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
        ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
        ..registerSingleton<ImageCacheProvider>(
          ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _OfflineAdapter())),
        );
      await settings.init();
      settingsBloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository());
      blocks = UserBlockRepository(storage);
      auth = _Auth(_alice);
      info = NotificationInfoRepository();
      counts = NotificationStateCubit(info);
    });

    tearDown(() async {
      notificationCardClock = DateTime.now;
      await info.dispose();
      await counts.close();
      await settingsBloc.close();
      await blocks.dispose();
      await auth.close();
      await getIt.get<ImageCacheProvider>().dispose();
      await getIt.reset();
      await settings.dispose();
      await db.close();
    });

    ThemeData theme({required bool dark}) => dark
        ? AppTheme.makeDark(_FakeContext(), seedColor: null, fontFamily: family)
        : AppTheme.makeLight(_FakeContext(), seedColor: null, fontFamily: family);

    Future<void> capture(WidgetTester tester, Key key, String name) async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
      final image = (await tester.runAsync(() => boundary.toImage(pixelRatio: 2)))!;
      final bytes = (await tester.runAsync(() => image.toByteData(format: ui.ImageByteFormat.png)))!;
      image.dispose();
      Directory(dir!).createSync(recursive: true);
      File('$dir/$name.png').writeAsBytesSync(bytes.buffer.asUint8List());
    }

    Future<void> pumpPage(WidgetTester tester, {required bool dark, required Key key}) async {
      tester.view
        ..physicalSize = const Size(390, 1500)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final notifications = _Notifications(
        NotificationState(status: NotificationStatus.success, noticeList: _sampleNotices(), ownerUid: 1000),
      );
      final blockCubit = UserBlockCubit(
        repository: blocks,
        currentUid: () => auth.currentUser?.uid,
        authStatus: auth.status,
        retryDelays: const [],
      );
      final auto = AutoNotificationCubit(
        authenticationRepository: auth,
        notificationRepository: NotificationRepository(storageProvider: storage),
        storageProvider: storage,
      );
      addTearDown(() async {
        await blockCubit.close();
        await auto.close();
        await notifications.close();
      });
      final router = GoRouter(
        routes: [GoRoute(path: '/', builder: (_, _) => const NotificationPage())],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        TranslationProvider(
          child: MultiRepositoryProvider(
            providers: [
              RepositoryProvider<AuthenticationRepository>.value(value: auth),
              RepositoryProvider<NotificationInfoRepository>.value(value: info),
            ],
            child: MultiBlocProvider(
              providers: [
                BlocProvider<SettingsBloc>.value(value: settingsBloc),
                BlocProvider<UserBlockCubit>.value(value: blockCubit),
                BlocProvider<NotificationBloc>.value(value: notifications),
                BlocProvider<NotificationStateCubit>.value(value: counts),
                BlocProvider<AutoNotificationCubit>.value(value: auto),
              ],
              child: RepaintBoundary(
                key: key,
                child: MaterialApp.router(
                  debugShowCheckedModeBanner: false,
                  theme: theme(dark: dark),
                  routerConfig: router,
                ),
              ),
            ),
          ),
        ),
      );
      await _settle(tester, rounds: 10);
    }

    for (final dark in [false, true]) {
      testWidgets('notice page, ${dark ? 'dark' : 'light'}', skip: skip != null, (tester) async {
        const key = ValueKey('shot');
        await pumpPage(tester, dark: dark, key: key);
        expect(tester.takeException(), isNull);
        await capture(tester, key, 'notice_page_${dark ? 'dark' : 'light'}');
      });

      testWidgets('system notifications, ${dark ? 'dark' : 'light'}', skip: skip != null, (tester) async {
        tester.view
          ..physicalSize = const Size(390, 760)
          ..devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        // Real async: the translations load outside the fake clock of the widget test.
        final tr = (await tester.runAsync(AppLocale.zhCn.build))!;
        const empty = NotificationV2.empty;
        final notices = _sampleNotices();
        final single = localNotificationContentOf(tr, autoSyncInfoOf(empty.copyWith(noticeList: [notices[0]]))!);
        final mention = localNotificationContentOf(
          tr,
          autoSyncInfoOf(empty.copyWith(noticeList: [notices[1]]))!,
          account: const LocalNoticeAccount(uid: 1000, username: 'Alice', named: true),
        );
        final pmOnly = localNotificationContentOf(
          tr,
          autoSyncInfoOf(
            empty.copyWith(
              personalMessageList: const [
                PersonalMessageV2(
                  timestamp: 100,
                  data: '今晚一起看番吗？',
                  peerUid: 1001,
                  peerUsername: 'Bob',
                  sender: false,
                  alreadyRead: false,
                ),
              ],
            ),
          )!,
        );
        final several = localNotificationContentOf(
          tr,
          autoSyncInfoOf(
            empty.copyWith(
              noticeList: [notices[0], notices[1], notices[2]],
              personalMessageList: [
                PersonalMessageV2(
                  timestamp: _secondsAt(_now),
                  data: '在吗',
                  peerUid: 1001,
                  peerUsername: 'Bob',
                  sender: false,
                  alreadyRead: false,
                ),
              ],
            ),
          )!,
        );
        const key = ValueKey('shot');
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: theme(dark: dark),
              home: Scaffold(
                appBar: AppBar(title: const Text('系统通知样式（示意）')),
                body: ListView(
                  padding: const EdgeInsets.all(12),
                  children: [
                    for (final (label, c, expanded) in [
                      ('单则提醒（展开）', single, true),
                      ('单则 @，所有账号模式', mention, true),
                      ('单则私信', pmOnly, true),
                      ('多则（收起）', several, false),
                      ('多则（展开，InboxStyle）', several, true),
                    ])
                      _NotificationMock(label: label, content: c, expanded: expanded),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await capture(tester, key, 'system_notification_${dark ? 'dark' : 'light'}');
      });
    }
  });
}

final class _FakeContext extends Fake implements BuildContext {}

/// A drawing of an Android notification of [content], collapsed or [expanded], for the screenshots.
class _NotificationMock extends StatelessWidget {
  const _NotificationMock({required this.label, required this.content, required this.expanded});

  final String label;
  final LocalNotificationContent content;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final inbox = expanded && content.lines.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: textTheme.labelMedium?.copyWith(color: colorScheme.outline)),
          const SizedBox(height: 4),
          DecoratedBox(
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CircleAvatar(
                    radius: 16,
                    backgroundColor: colorScheme.primary,
                    child: Icon(Icons.notifications, size: 18, color: colorScheme.onPrimary),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          inbox && content.summary != null ? 'TSDM Client · ${content.summary}' : 'TSDM Client · 刚刚',
                          style: textTheme.labelSmall?.copyWith(color: colorScheme.onSurfaceVariant),
                        ),
                        const SizedBox(height: 2),
                        Text(content.title, style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                        const SizedBox(height: 2),
                        if (inbox)
                          for (final line in content.lines)
                            Text(line, maxLines: 1, overflow: TextOverflow.ellipsis, style: textTheme.bodyMedium)
                        else
                          Text(
                            expanded ? content.body : content.body.split('\n').first,
                            maxLines: expanded ? 6 : 1,
                            overflow: TextOverflow.ellipsis,
                            style: textTheme.bodyMedium,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
