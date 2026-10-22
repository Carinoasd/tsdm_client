/// The forum's app API, plugin 2.2.0: the profile page answered as structured fields (`schema: 4`).
///
/// The page (`home.php?mod=space&uid=…&do=profile`, or `username=`) is asked in the JSON mode as before, but an answer
/// of plugin 2.2.0 carries every field the app reads: the owner, the statistics and extended credits, the profile rows
/// the forum prints after its privacy filter, the medals, the moderated forums, the groups, the activity (real
/// instants), the check-in block and the unread counts of the header, while the blocks other plugins add to the
/// profile stay as html in `profile_html`. The app builds [UserProfile] from them ([profileFromApi]) and never parses
/// the `document` of such an answer. An older plugin's answer (no `schema`) and the web page are parsed as before
/// ([buildProfile]).
///
/// The fixtures `profile_v4_*.json` are answers of the test forum (Discuz X5.0.2 with plugin 2.2.0, 2026-10-20) with
/// their `document` and `head` removed: the schema 4 path must not need them. `profile_v4_self.json` keeps a `document`
/// on purpose, a garbage one, to prove that path never reads it. `profile_v4_other_low.json` is a member whose
/// privacy settings hide most rows from the viewer; `profile_v4_guest.json` and `profile_v4_nouser.json` are the
/// forum's messages (no `schema`, `login` tells the guest apart).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/universal_html.dart';
import 'package:tsdm_client/features/profile/models/models.dart';
import 'package:tsdm_client/features/profile/models/profile_medal.dart';
import 'package:tsdm_client/features/profile/repository/profile_repository.dart';
import 'package:tsdm_client/features/profile/utils/parse_profile.dart';
import 'package:tsdm_client/features/profile/utils/profile_page_api.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:universal_html/parsing.dart';

const _dir = 'test/data/tsdmapp';

/// The QQ image the forum prints in the QQ row, and a title badge image of the title plugin.
const _qqImage = '<img src="static/image/common/qq.gif" />';
const _badgeImage = '<img src="data/attachment/title/1.png" />';

String _raw(String name) => File('$_dir/$name').readAsStringSync();

Map<String, dynamic> _json(String name) => jsonDecode(_raw(name)) as Map<String, dynamic>;

/// The profile built from the structured answer [name].
UserProfile _profile(String name) => profileFromApi(_json('profile_v4_$name.json')).getOrElse((e) => throw e);

/// The forum's wall clock (timeoffset 8) of [seconds], as the page prints it and the old parser keeps it.
DateTime _at(int seconds) {
  final t = DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true).add(const Duration(hours: 8));
  return DateTime(t.year, t.month, t.day, t.hour, t.minute);
}

/// A forum answering every request with [body] served as [contentType].
final class _Forum implements HttpClientAdapter {
  _Forum(this.body, {this.contentType = 'application/json; charset=utf-8'});

  final String body;
  final String contentType;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      body,
      200,
      headers: {
        Headers.contentTypeHeader: [contentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// The repository of a forum answering [body].
(ProfileRepository, _Forum) _repository(String body, {String contentType = 'application/json; charset=utf-8'}) {
  final forum = _Forum(body, contentType: contentType);
  getIt.registerFactory<NetClientProvider>(
    () => NetClientProvider.buildNoCookie(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum),
  );
  return (ProfileRepository(), forum);
}

T _right<T>(Either<AppException, T> either) => either.fold((e) => throw e, (v) => v);

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    getIt.allowReassignment = true;
    getIt
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty);
  });
  tearDownAll(() async {
    await getIt.reset();
    getIt.allowReassignment = false;
  });
  setUp(TsdmAppApi.reset);

  group('profileApiAnswerOf tells the structured answers apart', () {
    test('schema 4: the structured page, and the message of the plugin (login tells it)', () {
      for (final name in ['self', 'other_admin', 'other_low', 'username', 'guest', 'nouser']) {
        expect(profileApiAnswerOf(_raw('profile_v4_$name.json')), isNotNull, reason: name);
        expect(profileApiAnswerOf(_json('profile_v4_$name.json')), isNotNull, reason: '$name, decoded');
      }
      expect(_raw('profile_v4_guest.json'), isNot(contains('"schema"')), reason: 'the message has no schema');
      expect(_raw('profile_v4_nouser.json'), isNot(contains('"schema"')));
    });

    test('an older plugin (no schema), the web page, a failed build: null, the old path', () {
      expect(_raw('s3_profile.json'), isNot(contains('"schema"')));
      expect(profileApiAnswerOf(_raw('s3_profile.json')), isNull, reason: 'plugin 1.x: parsed from its document');
      expect(profileApiAnswerOf(_raw('s3_profile.html')), isNull, reason: 'the web page');
      expect(profileApiAnswerOf(File('test/data/profile_self_x5.html').readAsStringSync()), isNull);
      expect(profileApiAnswerOf(null), isNull);
      expect(profileApiAnswerOf(''), isNull);
      expect(profileApiAnswerOf('{"ok":0,"error":"internal"}'), isNull);
      expect(profileApiAnswerOf('{"ok":0,"error":"unknown","document":"<div></div>"}'), isNull);
      expect(
        profileApiAnswerOf('{"ok":0,"error":"message","message":"x","document":"<div></div>"}'),
        isNull,
        reason: 'a message of an older plugin (no login) is parsed from its document',
      );
      expect(profileApiAnswerOf('{"ok":1,"type":"profile","schema":3,"user":{}}'), isNull, reason: 'a lower schema');
      expect(profileApiAnswerOf('{"ok":1,"type":"thread","schema":4,"user":{}}'), isNull, reason: 'another page');
      expect(profileApiAnswerOf('{"ok":1,"schema":4,"user":{}}'), isNull, reason: 'no type');
      expect(profileApiAnswerOf('{"ok":1,"type":"profile","schema":5,"user":{}}'), isNotNull, reason: 'a later one');
      expect(profileApiAnswerOf('{"ok":0,"error":"message","message":"x","schema":4}'), isNotNull);
      expect(profileApiAnswerOf('[1,2]'), isNull);
      expect(profileApiAnswerOf('{'), isNull);
    });
  });

  group('profileFromApi: the own page (self)', () {
    late UserProfile p;
    setUpAll(() => p = _profile('self'));

    test('the owner', () {
      expect(p.username, 'ag_low2');
      expect(p.uid, '35');
      expect(p.avatarUrl, 'https://www.tsdm39.com/data/avatar/noavatar.svg');
      expect(p.online, isTrue);
      expect(p.emailVerified, isFalse);
      expect(p.videoVerified, isNull, reason: 'the forum has no video verification');
      expect(p.customTitle, isNull, reason: 'empty on the answer: no row on the page');
      expect(p.signature, isNull);
    });

    test('the friends row: the fragment the page prints, read as before', () {
      final info = parseFriendsInfo(p.friendsCount);
      expect(info.count, '1');
      expect(info.url, '$baseUrl/home.php?mod=space&uid=35&do=friend&view=me&from=space');
    });

    test('the profile rows, by id', () {
      expect(p.birthdayYear, '2000');
      expect(p.birthdayMonth, '10');
      expect(p.birthdayDay, '11');
      expect(p.gender, '男');
      expect(p.from, '中国 上海 上海');
      expect(p.zodiac, isNull, reason: 'not printed');
      expect(p.msn, isNull);
      expect(p.introduction, isNull);
      expect(p.nickname, isNull);
      expect(p.qq, isNull);
    });

    test('the medals: every one, with the forum id as an opaque string', () {
      expect(p.profileMedals, hasLength(107));
      final first = p.profileMedals!.first;
      expect(first.id, '2332');
      expect(first.name, '验收人次章1790420575');
      expect(first.alter, first.name);
      expect(first.image, 'https://www.tsdm39.com/static/image/common/../../../data/mcdemo/01.gif');
      expect(first.description, '');
      final last = p.profileMedals!.last;
      expect(last.id, '3');
      expect(last.name, '热心会员');
      expect(last.description, 'guestlite 驗收用：熱心會員');
      expect(p.mangedForums, isNull, reason: 'moderates no forum: no block on the page');
    });

    test('the check-in block, as the page prints it', () {
      expect(p.checkinDaysCount, 1);
      expect(p.checkinThisMonthCount, '1');
      expect(p.checkinRecentTime, '2023-11-15 06:13', reason: "the forum's time (timeoffset 8); the fixture tool pins the check-in time");
      expect(p.checkinAllCoins, '6');
      expect(p.checkinLastTimeCoin, '6');
      expect(p.checkinLevel, '[LV.1]初来乍到');
      expect(p.checkinNextLevel, '[LV.2]偶尔看看I');
      expect(p.checkinNextLevelDays, 2);
      expect(p.checkinTodayStatus, '今天未签到');
    });

    test('the groups: the fragment the group section reads', () {
      expect(p.moderatorGroup, isNull);
      final doc = parseHtmlDocument(p.userGroup!).body!;
      expect(doc.firstEndDeepText()?.trim(), 'AG低權組');
      expect(doc.querySelector('a')?.attributes['href'], '$baseUrl/home.php?mod=spacecp&ac=usergroup&gid=23');
      expect(doc.querySelector('font')?.attributes['color'], '');
      expect(doc.children.lastOrNull?.imageUrl(), isNull, reason: 'no icon: no image, the section stays hidden');
    });

    test("the activity: the forum's wall clock as the page prints it, the IPs of the own page, the time zone", () {
      expect(p.onlineTime, '28 小时');
      expect(p.registerTime, DateTime(2026, 9, 4, 1, 19));
      expect(p.lastVisitTime, DateTime(2023, 11, 15, 6, 13), reason: 'the fixture tool pins the viewer-dependent times');
      expect(p.registerTime, _at(1788455940));
      expect(p.lastVisitTime, _at(1700000000));
      expect(p.lastActiveTime, _at(1700000060));
      expect(p.lastPostTime, _at(1792446300));
      expect(p.registerIP, '1.2.3.4:1234 - Invalid');
      expect(p.lastVisitIP, '1.2.3.4:1234 - Reserved');
      expect(p.timezone, '使用系统默认');
    });

    test('the statistics, by title', () {
      expect(p.credits, '1032');
      expect(p.famous, '5');
      expect(p.coins, '675');
      expect(p.publicity, '0');
      expect(p.scheming, '0');
      expect(p.natural, '0');
      expect(p.spirit, '268');
      expect(p.specialAttr, isNull);
      expect(p.specialAttrName, isNull);
      expect(p.specialAttr2, isNull);
    });

    test('the header: unread notices and messages', () {
      final page = ProfileApiPage(_json('profile_v4_self.json'));
      expect(unreadInfoOf(page), (0, false), reason: 'live: ag_low2 had no unread notice when the fixture was fetched');
      final withNotices = ProfileApiPage({
        ..._json('profile_v4_self.json'),
        'unread': {'notice': 5, 'pm': 0},
      });
      expect(unreadInfoOf(withNotices), (5, false));
      expect(page.avatarUrl, 'https://www.tsdm39.com/data/avatar/noavatar.svg');
      expect(page.loggedIn, isTrue);
      final withPm = ProfileApiPage({
        ..._json('profile_v4_self.json'),
        'unread': {'notice': 0, 'pm': 2},
      });
      expect(unreadInfoOf(withPm), (0, true));
    });

    test('the garbage document is there and never read', () async {
      final raw = _raw('profile_v4_self.json');
      expect(raw, contains(r'"document":"<div id=\"wp\">nothing</div>"'));
      expect(tsdmAppAnswerWithoutPage(raw), isFalse);
      final web = await buildProfile(tsdmAppPageDocument(raw)).run();
      expect(web.isLeft(), isTrue, reason: 'the document holds no profile');
      expect(_right(await buildProfilePage(ProfileApiPage(_json('profile_v4_self.json'))).run()).username, 'ag_low2');
    });
  });

  group('profileFromApi: other members', () {
    test('an administrator: both groups, the moderated forums, the signature', () {
      final p = _profile('other_admin');
      expect(p.username, 'ag_admin');
      expect(p.uid, '32');
      // Whether the member is online changes from one capture to the next: follow the sample's 0/1, not a fixed value.
      final online = (_json('profile_v4_other_admin.json')['user'] as Map<String, dynamic>)['online'];
      expect(online, anyOf(0, 1));
      expect(p.online, online == 1);
      const link = '<a href="https://www.tsdm39.com/forum.php?mod=viewthread&amp;tid=9" target="_blank">簽名裡的舊網域連結</a>';
      expect(
        p.signature,
        '<table><tbody><tr><td>$link</td></tr></tbody></table>',
        reason: 'in the one-cell table the page prints, as the old parser keeps it',
      );
      expect(p.gender, '保密');
      expect(p.birthdayYear, isNull, reason: 'the page prints "-"');
      expect(p.birthdayMonth, isNull);
      expect(p.birthdayDay, isNull);
      expect(p.from, isNull);
      expect(p.profileMedals, isEmpty);
      expect(p.mangedForums?.map((e) => (e.fid, e.name)), [(9, '手遊情報站'), (10, 'Galgame・美少女遊戲')]);
      expect(parseHtmlDocument(p.moderatorGroup!).body!.firstEndDeepText()?.trim(), '管理员');
      expect(parseHtmlDocument(p.userGroup!).body!.firstEndDeepText()?.trim(), '管理员');
      expect(p.registerIP, isNull, reason: 'not the viewer: no IP');
      expect(p.lastVisitIP, isNull);
      expect(p.onlineTime, '51 小时');
      expect(p.lastPostTime, _at(1792499820));
      expect(p.credits, '1196');
      expect(p.coins, '833');
      expect(p.checkinAllCoins, '18');
      expect(parseFriendsInfo(p.friendsCount).count, '0');
    });

    test('a member hidden by privacy: fewer rows, every missing one null; negative credits', () {
      final p = _profile('other_low');
      expect(p.username, 'ag_low');
      expect(p.uid, '31');
      expect(p.avatarUrl, 'https://img.ts-dm.net/images/2024/02/01/2024.02.gif');
      expect(p.gender, '男');
      expect(p.from, isNull, reason: 'the forum did not print the city');
      expect(p.birthdayYear, isNull);
      expect(p.zodiac, isNull);
      expect(p.profileMedals, hasLength(24));
      expect(p.profileMedals!.first.id, '1759');
      expect(p.moderatorGroup, isNull);
      expect(p.credits, '-7692');
      expect(p.coins, '-8652');
      expect(p.scheming, '-470');
      expect(p.natural, '-460');
      expect(p.spirit, '-7');
      expect(p.famous, '342');
      expect(p.checkinRecentTime, '2023-11-15 06:13');
    });

    test('a lookup by username: a super moderator', () {
      final p = _profile('username');
      expect(p.username, 'ag_mid');
      expect(p.uid, '33');
      expect(parseHtmlDocument(p.moderatorGroup!).body!.firstEndDeepText()?.trim(), '超级版主');
      expect(parseHtmlDocument(p.userGroup!).body!.querySelector('a')?.attributes['href'], endsWith('gid=2'));
      expect(p.mangedForums, isNull);
      expect(p.spirit, '0');
    });
  });

  group('profileFromApi reads the same profile the old parser reads from the page block', () {
    for (final name in ['self', 'other_admin', 'other_low', 'username']) {
      test(name, () async {
        final api = _profile(name);
        final web = _right(await buildProfile(profileHtmlDocumentOf(_json('profile_v4_$name.json'))).run());
        expect(api.username, web.username);
        expect(api.uid, web.uid);
        expect(api.online, web.online);
        expect(api.emailVerified, web.emailVerified);
        expect(api.videoVerified, web.videoVerified);
        expect(api.customTitle, web.customTitle);
        expect(api.signature, web.signature);
        expect(parseFriendsInfo(api.friendsCount), parseFriendsInfo(web.friendsCount));
        expect(api.birthdayYear, web.birthdayYear);
        expect(api.birthdayMonth, web.birthdayMonth);
        expect(api.birthdayDay, web.birthdayDay);
        expect(api.zodiac, web.zodiac);
        expect(api.msn, web.msn);
        expect(api.introduction, web.introduction);
        expect(api.nickname, web.nickname);
        expect(api.gender, web.gender);
        // The old parser only knows the X3 title `来自`; the X5 page prints `居住地`, which the structured path reads by
        // id (`residecity`), as the contract asks: the one row the structured path shows and the old path does not.
        if (web.from != null) {
          expect(api.from, web.from);
        }
        expect(api.qq, web.qq);
        expect(api.profileMedals?.map((e) => (e.name, e.image, e.description)), [
          ...?web.profileMedals?.map((e) => (e.name, e.image, e.description)),
        ]);
        expect(api.mangedForums, web.mangedForums);
        expect(api.checkinDaysCount, web.checkinDaysCount);
        expect(api.checkinThisMonthCount, web.checkinThisMonthCount);
        expect(api.checkinRecentTime, web.checkinRecentTime);
        expect(api.checkinAllCoins, web.checkinAllCoins);
        expect(api.checkinLastTimeCoin, web.checkinLastTimeCoin);
        expect(api.checkinLevel, web.checkinLevel);
        expect(api.checkinNextLevel, web.checkinNextLevel);
        expect(api.checkinNextLevelDays, web.checkinNextLevelDays);
        expect(api.checkinTodayStatus, web.checkinTodayStatus);
        // The group fragments differ in markup; what the section reads from them does not.
        String? groupName(String? fragment) =>
            fragment == null ? null : parseHtmlDocument(fragment).body?.firstEndDeepText()?.trim();
        String? groupImage(String? fragment) =>
            fragment == null ? null : parseHtmlDocument(fragment).body?.children.lastOrNull?.imageUrl();
        expect(groupName(api.moderatorGroup), groupName(web.moderatorGroup));
        expect(groupImage(api.moderatorGroup), groupImage(web.moderatorGroup));
        expect(groupName(api.userGroup), groupName(web.userGroup));
        expect(groupImage(api.userGroup), groupImage(web.userGroup));
        expect(api.onlineTime, web.onlineTime);
        // The forum's wall clock (timeoffset 8) as the page prints it, the naive time the old parser keeps.
        expect(api.registerTime, web.registerTime);
        expect(api.lastVisitTime, web.lastVisitTime);
        expect(api.lastActiveTime, web.lastActiveTime);
        expect(api.lastPostTime, web.lastPostTime);
        expect(api.registerIP, web.registerIP);
        expect(api.lastVisitIP, web.lastVisitIP);
        expect(api.timezone, web.timezone);
        expect(api.credits, web.credits);
        expect(api.famous, web.famous);
        expect(api.coins, web.coins);
        expect(api.publicity, web.publicity);
        expect(api.natural, web.natural);
        expect(api.scheming, web.scheming);
        expect(api.spirit, web.spirit);
        expect(api.specialAttr, web.specialAttr);
        expect(api.specialAttrName, web.specialAttrName);
        expect(api.specialAttr2, web.specialAttr2);
        expect(api.specialAttrName2, web.specialAttrName2);
      });
    }
  });

  group('profileFromApi: the fields the fixtures do not exercise', () {
    Map<String, dynamic> self() => _json('profile_v4_self.json');

    test('rows matched by title when the id is not the known one; the QQ number from its link', () {
      final json = self()
        ..['profiles'] = [
          {'id': 'x1', 'title': '星座', 'value': '天秤座'},
          {'id': 'x2', 'title': 'MSN', 'value': 'someone@example.com'},
          {'id': 'x3', 'title': '自我介绍', 'value': '你好<br />世界'},
          {'id': 'x4', 'title': '昵称', 'value': '小明'},
          {'id': 'x5', 'title': '来自', 'value': '台北'},
          {
            'id': 'x6',
            'title': 'QQ',
            'value': '<a href="//wpa.qq.com/msgrd?v=3&amp;uin=123456&amp;site=qq&amp;menu=yes">$_qqImage</a>',
          },
          {'id': 'x7', 'title': '生日', 'value': '10 月 11 日'},
        ];
      final p = _right(profileFromApi(json));
      expect(p.zodiac, '天秤座');
      expect(p.msn, 'someone@example.com');
      expect(p.introduction, '你好<br />世界');
      expect(p.nickname, '小明');
      expect(p.from, '台北');
      expect(p.qq, '123456');
      expect(p.birthdayYear, isNull);
      expect(p.birthdayMonth, '10');
      expect(p.birthdayDay, '11');
    });

    test('rows matched by id first (the nickname field of the forum, a constellation, a bare QQ)', () {
      final json = self()
        ..['profiles'] = [
          {'id': 'field1', 'title': '暱稱', 'value': '小華'},
          {'id': 'constellation', 'title': 'Zodiac', 'value': '双鱼座'},
          {'id': 'qq', 'title': 'QQ', 'value': '654321'},
          {'id': 'bio', 'title': 'Bio', 'value': '  hi  '},
          {'id': 'residecity', 'title': '来自', 'value': '上海'},
        ];
      final p = _right(profileFromApi(json));
      expect(p.nickname, '小華');
      expect(p.zodiac, '双鱼座');
      expect(p.qq, '654321');
      expect(p.introduction, 'hi');
      expect(p.from, '上海');
    });

    test('custom title, signature, email verified, offline', () {
      final json = self()
        ..['user'] = {
          ...self()['user'] as Map<String, dynamic>,
          'customstatus': '頭銜',
          'signature_html': '<b>sig</b>',
          'email_verified': 1,
          'online': 0,
        };
      final p = _right(profileFromApi(json));
      expect(p.customTitle, '頭銜');
      expect(p.signature, '<table><tbody><tr><td><b>sig</b></td></tr></tbody></table>');
      expect(p.emailVerified, isTrue);
      expect(p.online, isFalse);
    });

    test('no check-in block: every check-in field null; never checked in: no day', () {
      final none = _right(profileFromApi(self()..['checkin'] = null));
      expect(none.checkinDaysCount, isNull);
      expect(none.checkinThisMonthCount, isNull);
      expect(none.checkinRecentTime, isNull);
      expect(none.checkinAllCoins, isNull);
      expect(none.checkinLastTimeCoin, isNull);
      expect(none.checkinLevel, isNull);
      expect(none.checkinNextLevel, isNull);
      expect(none.checkinNextLevelDays, isNull);
      expect(none.checkinTodayStatus, isNull);
      expect(_right(profileFromApi(self()..remove('checkin'))).checkinLevel, isNull);

      final never = _right(
        profileFromApi(
          self()
            ..['checkin'] = {
              'days': 0,
              'mdays': 0,
              'last': 0,
              'reward': 0,
              'lastreward': 0,
              'reward_title': '天使币',
              'reward_unit': '',
              'level': {'code': 'LV.1', 'name': '初来乍到', 'next': 'LV.2', 'next_name': '偶尔看看I', 'remain': 3},
              'today': 0,
            },
        ),
      );
      expect(never.checkinDaysCount, isNull);
      expect(never.checkinRecentTime, isNull);
      expect(never.checkinThisMonthCount, '0');
      expect(never.checkinNextLevelDays, 3);
    });

    test('checked in today, the top level: no next level, no remaining day', () {
      final p = _right(
        profileFromApi(
          self()
            ..['checkin'] = {
              'days': 400,
              'mdays': 20,
              'last': 1792498820,
              'reward': 9000,
              'lastreward': 30,
              'reward_title': '天使币',
              'reward_unit': '',
              'level': {'code': 'LV.Master', 'name': '签到之神', 'next': '', 'next_name': '', 'remain': 0},
              'today': 1,
            },
        ),
      );
      expect(p.checkinDaysCount, 400);
      expect(p.checkinThisMonthCount, '20');
      expect(p.checkinRecentTime, '2026-10-20 20:20');
      expect(p.checkinAllCoins, '9000');
      expect(p.checkinLastTimeCoin, '30');
      expect(p.checkinLevel, '[LV.Master]签到之神');
      expect(p.checkinNextLevel, isNull);
      expect(p.checkinNextLevelDays, isNull);
      expect(p.checkinTodayStatus, '今天已签到');
    });

    test('a group with a color and an icon: the section reads the name, the color and the image', () {
      final json = self()
        ..['groups'] = {
          'admin': {
            'gid': 3,
            'title': '版主',
            'color': '#FF0000',
            'icon': 'https://www.tsdm39.com/static/image/g/mod.gif',
          },
          'member': {
            'gid': 10,
            'title': 'A & B',
            'color': 'green',
            'icon': 'https://www.tsdm39.com/static/image/g/10.gif',
            'expiry': 0,
            'upgrade_credits': 100,
          },
          'ext': <Map<String, dynamic>>[],
        };
      final p = _right(profileFromApi(json));
      final mod = parseHtmlDocument(p.moderatorGroup!).body!;
      expect(mod.firstEndDeepText()?.trim(), '版主');
      expect(mod.querySelector('font')?.attributes['color'], '#FF0000');
      expect(mod.children.lastOrNull?.imageUrl(), 'https://www.tsdm39.com/static/image/g/mod.gif');
      final member = parseHtmlDocument(p.userGroup!).body!;
      expect(member.firstEndDeepText()?.trim(), 'A & B');
      expect(member.querySelector('font')?.attributes['color'], 'green');
      expect(member.children.lastOrNull?.imageUrl(), 'https://www.tsdm39.com/static/image/g/10.gif');
      expect(member.querySelector('a')?.attributes['href'], '$baseUrl/home.php?mod=spacecp&ac=usergroup&gid=10');
    });

    test('unknown extended credits are the special attributes, in order; decimals and units as printed', () {
      final json = self()
        ..['stats'] = {
          ...self()['stats'] as Map<String, dynamic>,
          'credits': 12,
          'extcredits': [
            {'id': 1, 'title': '威望', 'unit': '枚', 'value': 1},
            {'id': 7, 'title': '活跃', 'unit': '', 'value': 3.5},
            {'id': 8, 'title': '贡献:', 'unit': '', 'value': 7},
            {'id': 10, 'title': '已用空间', 'unit': '', 'value': 0},
            {'id': 11, 'title': '精灵', 'unit': '', 'value': null},
          ],
        };
      final p = _right(profileFromApi(json));
      expect(p.credits, '12');
      expect(p.famous, '1 枚');
      expect(p.spirit, isNull, reason: 'no value: no row');
      expect(p.coins, isNull);
      expect(p.specialAttrName, '活跃');
      expect(p.specialAttr, '3.5');
      expect(p.specialAttrName2, '贡献');
      expect(p.specialAttr2, '7');
    });

    test('activity: 0 times are null, 0 hours online, no time zone', () {
      final json = self()
        ..['activity'] = {
          'oltime': 0,
          'regdate': 1788455940,
          'lastvisit': 0,
          'lastactivity': 0,
          'lastpost': 0,
          'lastsendmail': 0,
          'regip': '',
          'lastip': '',
          'timezone': '9999',
          'timezone_text': '',
        };
      final p = _right(profileFromApi(json));
      expect(p.onlineTime, isNull, reason: 'the page hides the row at 0');
      expect(p.registerTime, _at(1788455940));
      expect(p.lastVisitTime, isNull);
      expect(p.lastActiveTime, isNull);
      expect(p.lastPostTime, isNull);
      expect(p.registerIP, isNull);
      expect(p.lastVisitIP, isNull);
      expect(p.timezone, isNull);
    });

    test('the medal row: a numeric id is kept as a string, missing fields are empty', () {
      expect(ProfileMedal.fromApi({'id': 12, 'name': 'n', 'image': 'i', 'description': 'd'}).id, '12');
      expect(ProfileMedal.fromApi({'id': 'TSDM1745', 'name': 'n', 'image': 'i'}).id, 'TSDM1745');
      final bare = ProfileMedal.fromApi({});
      expect(bare.id, isNull);
      expect(bare.name, '');
      expect(bare.alter, '');
      expect(bare.image, '');
      expect(bare.description, '');
    });

    test('a bare answer builds an empty profile, never throws', () {
      final p = _right(profileFromApi({'ok': 1, 'schema': 4}));
      expect(p.username, isNull);
      expect(p.uid, isNull);
      expect(p.avatarUrl, isNull);
      expect(p.profileMedals, isEmpty);
      expect(p.mangedForums, isNull);
      expect(p.userGroup, isNull);
      expect(p.checkinLevel, isNull);
      expect(p.credits, isNull);
      expect(p.onlineTime, isNull);
      expect(parseFriendsInfo(p.friendsCount).count, '0');
    });
  });

  group('the message answers', () {
    test('a guest is asked to log in', () async {
      final json = _json('profile_v4_guest.json');
      expect(profileFromApi(json).getLeft().toNullable(), isA<ProfileNeedLoginException>());
      final page = ProfileApiPage(json);
      expect(page.loggedIn, isFalse);
      expect(page.avatarUrl, isNull);
      expect(unreadInfoOf(page), (0, false));
      expect(secondaryTitleUrlOf(page), isNull);
      expect((await buildProfilePage(page).run()).getLeft().toNullable(), isA<ProfileNeedLoginException>());
    });

    test('no such user: the forum message, as the page shows it', () {
      final json = _json('profile_v4_nouser.json');
      final e = profileFromApi(json).getLeft().toNullable();
      expect(e, isA<ServerRespondedErrorException>());
      expect(e!.message, '抱歉，您指定的用户空间不存在');
      expect(ProfileApiPage(json).loggedIn, isTrue, reason: 'a member got the message, not a guest');
    });
  });

  group('the blocks other plugins add stay in profile_html, parsed as before', () {
    test('the title badge of the owner', () {
      final json = _json('profile_v4_self.json');
      expect(secondaryTitleUrlOf(ProfileApiPage(json)), isNull, reason: 'the test forum has no title plugin');
      const badge = '<div class="tsdmtitle-badges"><div class="tsdmtitle-title">$_badgeImage</div></div>';
      final withBadge = {
        ...json,
        'profile_html': '$badge${json['profile_html']}',
      };
      expect(secondaryTitleUrlOf(ProfileApiPage(withBadge)), '$baseUrl/data/attachment/title/1.png');
      final doc = profileHtmlDocumentOf(withBadge);
      expect(doc.querySelector('div#ct div.bm_c.u_profile'), isNotNull);
      expect(doc.querySelector('div#wp.wp'), isNotNull);
    });

    test('the page block of the answer is what the old parser reads', () async {
      // The medal of the forum and the check-in block are also in the block; the old parser reads them as the page.
      final web = _right(await buildProfile(profileHtmlDocumentOf(_json('profile_v4_self.json'))).run());
      expect(web.username, 'ag_low2');
      expect(web.profileMedals, hasLength(107));
      expect(web.checkinRecentTime, '2023-11-15 06:13');
    });
  });

  group('the old path', () {
    test('a web page and an older plugin answer are ProfileWebPage, parsed as before', () async {
      final older = ProfileWebPage(tsdmAppPageDocument(_raw('s3_profile.json')));
      final web = ProfileWebPage(parseHtmlDocument(_raw('s3_profile.html')));
      final fromOlder = _right(await buildProfilePage(older).run());
      final fromWeb = _right(await buildProfilePage(web).run());
      final direct = _right(await buildProfile(parseHtmlDocument(_raw('s3_profile.html'))).run());
      expect(fromOlder, direct);
      expect(fromWeb, direct);
      expect(unreadInfoOf(web), buildUnreadInfoStatus(web.document));
      expect(secondaryTitleUrlOf(web), parseProfileSecondaryTitleUrl(web.document));
      expect(web.avatarUrl, parseProfileAvatarUrl(web.document));
      expect(web.loggedIn, isLoggedInDocument(web.document));
      expect(older.avatarUrl, web.avatarUrl);
    });

    test('the X5 profile page of the parsers keeps its values', () async {
      final page = ProfileWebPage(parseHtmlDocument(File('test/data/profile_self_x5.html').readAsStringSync()));
      final p = _right(await buildProfilePage(page).run());
      expect(p.username, 'Alice');
      expect(parseFriendsInfo(p.friendsCount).count, '3');
      expect(page.loggedIn, isTrue);
    });
  });

  group('ProfileRepository.fetchProfile', () {
    tearDown(() async {
      if (getIt.isRegistered<NetClientProvider>()) {
        await getIt.unregister<NetClientProvider>();
      }
    });

    test('schema 4: the structured page of another user, the document never parsed', () async {
      final (repo, forum) = _repository(_raw('profile_v4_other_admin.json'));
      final page = _right(await repo.fetchProfile(uid: '32').run());
      expect(page, isA<ProfileApiPage>());
      expect(forum.requests.single.uri.toString(), startsWith('${uidProfilePage}32&tsdmapp=json'));
      final p = _right(await buildProfilePage(page).run());
      expect(p.username, 'ag_admin');
      expect(p.mangedForums, hasLength(2));
      expect(repo.hasCache(), isFalse, reason: 'another user is never cached');
    });

    test('schema 4 with the garbage document: built from the fields', () async {
      final (repo, _) = _repository(_raw('profile_v4_self.json'));
      final page = _right(await repo.fetchProfile(uid: '35').run());
      expect(page, isA<ProfileApiPage>());
      expect(_right(await buildProfilePage(page).run()).profileMedals, hasLength(107));
    });

    test('a lookup by username', () async {
      final (repo, forum) = _repository(_raw('profile_v4_username.json'));
      final page = _right(await repo.fetchProfile(username: 'ag_mid').run());
      expect(forum.requests.single.uri.toString(), startsWith('${usernameProfilePage}ag_mid&tsdmapp=json'));
      expect(_right(await buildProfilePage(page).run()).uid, '33');
    });

    test('the messages of plugin 2.2.0 are pages: the guest, the unknown user', () async {
      final (guestRepo, _) = _repository(_raw('profile_v4_guest.json'));
      final guest = _right(await guestRepo.fetchProfile(uid: '32').run());
      expect(guest, isA<ProfileApiPage>());
      expect(guest.loggedIn, isFalse);
      expect((await buildProfilePage(guest).run()).getLeft().toNullable(), isA<ProfileNeedLoginException>());
      await getIt.unregister<NetClientProvider>();

      final (nouserRepo, _) = _repository(_raw('profile_v4_nouser.json'));
      final nouser = _right(await nouserRepo.fetchProfile(uid: '99').run());
      expect(nouser, isA<ProfileApiPage>());
      final e = (await buildProfilePage(nouser).run()).getLeft().toNullable();
      expect(e, isA<ServerRespondedErrorException>());
      expect(e!.message, '抱歉，您指定的用户空间不存在');
    });

    test('an older plugin (no schema) and the web page are parsed from the document as before', () async {
      final (olderRepo, _) = _repository(_raw('s3_profile.json'));
      final older = _right(await olderRepo.fetchProfile(uid: '35').run());
      expect(older, isA<ProfileWebPage>());
      final fromOlder = _right(await buildProfilePage(older).run());
      final direct = _right(await buildProfile(tsdmAppPageDocument(_raw('s3_profile.json'))).run());
      expect(fromOlder, direct);
      await getIt.unregister<NetClientProvider>();

      final (webRepo, _) = _repository(_raw('s3_profile.html'), contentType: 'text/html; charset=utf-8');
      final web = _right(await webRepo.fetchProfile(uid: '35').run());
      expect(web, isA<ProfileWebPage>());
      expect(_right(await buildProfilePage(web).run()), direct);
    });

    test('an answer without a page is still a failed request', () async {
      for (final (label, body, type) in [
        ('a failed build', '{"ok":0,"error":"internal"}', 'application/json; charset=utf-8'),
        ('an empty web page', '', 'text/html; charset=utf-8'),
      ]) {
        final (repo, _) = _repository(body, contentType: type);
        expect(
          (await repo.fetchProfile(uid: '35').run()).getLeft().toNullable(),
          isA<HttpRequestFailedException>(),
          reason: label,
        );
        await getIt.unregister<NetClientProvider>();
      }
    });
  });

  group('ProfileRepository: the own page', () {
    late AppDatabase db;
    late StorageProvider storage;
    late SettingsRepository settings;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      getIt
        ..registerSingleton<StorageProvider>(storage)
        ..registerSingleton<SettingsRepository>(settings);
      await settings.init();
      await settings.setValue<int>(SettingsKeys.loginUid, 35);
      await settings.setValue<String>(SettingsKeys.loginUsername, 'ag_low2');
      TsdmAppApi.reset();
    });

    tearDown(() async {
      if (getIt.isRegistered<NetClientProvider>()) {
        await getIt.unregister<NetClientProvider>();
      }
      await getIt.unregister<SettingsRepository>();
      await getIt.unregister<StorageProvider>();
      await settings.dispose();
      await db.close();
    });

    test('the structured page is cached and serves the avatar', () async {
      final (repo, forum) = _repository(_raw('profile_v4_self.json'));
      final page = _right(await repo.fetchProfile().run());
      expect(page, isA<ProfileApiPage>());
      expect(repo.hasCache(), isTrue);
      expect(repo.getCache(), same(page));
      expect(_right(await repo.fetchProfile().run()), same(page), reason: 'served from the cache');
      expect(forum.requests, hasLength(1));
      expect(_right(await repo.fetchAvatarUrl().run()), 'https://www.tsdm39.com/data/avatar/noavatar.svg');
      expect(forum.requests, hasLength(1));
      expect(_right(await repo.fetchAvatarUrl(force: true).run()), 'https://www.tsdm39.com/data/avatar/noavatar.svg');
      expect(forum.requests, hasLength(2));
      repo.logout();
      expect(repo.hasCache(), isFalse);
    });

    test('the guest message means the session expired, and is not cached as the page of the account', () async {
      final (repo, _) = _repository(_raw('profile_v4_guest.json'));
      expect((await repo.fetchAvatarUrl(force: true).run()).getLeft().toNullable(), isA<ProfileNeedLoginException>());
      expect(repo.hasCache(), isFalse);
      expect(_right(await repo.fetchProfile().run()), isA<ProfileApiPage>());
      expect(repo.hasCache(), isFalse, reason: 'a message is not the profile');
    });
  });
}
