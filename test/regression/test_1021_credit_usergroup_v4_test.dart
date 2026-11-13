/// My credits and my user group read from the forum's app API (plugin 4.0.0, `tsdmv=4`): the statistics page of the
/// credits (`credit_base`, schema 52) and the group comparison page (`usergroup_info`, schema 54).
///
/// * Asked as a page (`tsdmapp=json&tsdmv=4&nodoc=1`) only once `status` listed it in `credit_pages`; otherwise, and
///   for any answer that is not the page, the web page is read as before.
/// * The same data read either way gives the same credits, the same latest changes (to the minute the page prints)
///   and the same groups, thresholds and menus.
/// * The forum's message is shown as the page's; another account's answer is refused.
///
/// The rules of the credits (`credit_rule`, schema 53) have no page in the app: nothing reads them.
///
/// Fixtures: the answers and pages of the test forum (cleaned).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/points/models/models.dart';
import 'package:tsdm_client/features/points/repository/points_repository.dart';
import 'package:tsdm_client/features/points/utils/credit_page_api.dart';
import 'package:tsdm_client/features/profile/models/user_group_progress.dart';
import 'package:tsdm_client/features/profile/repository/user_group_progress_repository.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';

import 'tsdmapp_v4_fake.dart';

const _uid = 31;

bool _v4(Uri u) => u.queryParameters['tsdmv'] == '4';

DateTime _minute(DateTime t) => DateTime(t.year, t.month, t.day, t.hour, t.minute);

List<String> _rows(List<PointsChange> changes) => [
  for (final c in changes) '${c.operation}|${c.changeMap}|${c.detail}|${c.pointsChangeType}|${_minute(c.time)}',
];

void main() {
  setUpAll(registerV4TestServices);
  tearDownAll(resetV4TestServices);
  setUp(TsdmAppApi.reset);

  group('my credits (credit_base, schema 52)', () {
    Future<Either<String, PointsStatistics>> fetch(V4Forum forum, {int uid = _uid}) async {
      useV4Forum(forum);
      return (await PointsRepository(currentUid: () => uid).fetchStatistics().run()).getOrElse((e) => throw e);
    }

    V4Forum forum() => V4Forum(
      (o) => _v4(o.uri) ? V4Reply(v4Json('g3_credit_base_v52.json')) : V4Reply(v4Raw('g3_credit_base_web.html')),
    );

    test('the answer and the page of the same account give the same credits and changes', () async {
      knowV4Status();
      final viaApi = forum();
      final api = (await fetch(viaApi)).getOrElse(fail);
      expect(viaApi.requests, hasLength(1));
      expect(viaApi.requests.single.uri.queryParameters, allOf(containsPair('nodoc', '1'), containsPair('op', 'base')));
      TsdmAppApi.reset();
      knowV4Status(v4Status({'credit_pages': <String>[]}));
      final viaWeb = forum();
      final web = (await fetch(viaWeb)).getOrElse(fail);
      expect(viaWeb.requests.where((r) => _v4(r.uri)), isEmpty);

      final total = t.profilePage.statistics.credits;
      expect(api.points[total], '2644');
      expect(web.points['积分'], '2644');
      expect({...api.points}..remove(total), {...web.points}..remove('积分'));
      expect(api.points.keys.first, '天使币', reason: 'the credit of the trades first, as the page');
      expect(api.changes, hasLength(web.changes.length));
      expect(_rows(api.changes), _rows(web.changes));
      expect(api.changes.first.time.second, isNot(0), reason: 'the answer gives the second');
    });

    test('a unit is printed after the value; a special upgrade group adds its total', () {
      final json = v4Json('g3_credit_base_v52.json');
      ((json['credits'] as List).first as Map)['unit'] = '枚';
      json['upgroup'] = {'name': '字幕组', 'value': 120, 'formula': '发帖数'};
      final stats = pointsStatisticsFromApi(json);
      expect(stats.points['天使币'], '1504 枚');
      expect(stats.points['字幕组${t.profilePage.statistics.credits}'], '120');
    });

    test("the guest prompt is the page's message; another account's answer is refused", () async {
      knowV4Status();
      final guest = await fetch(V4Forum((o) => V4Reply(v4Json('g3_credit_base_guest.json'))));
      expect(guest.getLeft().toNullable(), isNotEmpty);
      useV4Forum(V4Forum((o) => V4Reply({...v4Json('g3_credit_base_v52.json'), 'uid': 35})));
      final other = await PointsRepository(currentUid: () => _uid).fetchStatistics().run();
      expect(other.getLeft().toNullable(), isA<IdentityChangedException>());
    });

    test('an answer that is not the page reads the page', () async {
      knowV4Status();
      final f = V4Forum(
        (o) => _v4(o.uri) ? const V4Reply({'ok': 0, 'error': 'off'}) : V4Reply(v4Raw('g3_credit_base_web.html')),
      );
      expect((await fetch(f)).isRight(), isTrue);
      expect(f.requests, hasLength(2));
    });
  });

  group('my user group (usergroup_info, schema 54)', () {
    String page(UserGroupPage p) =>
        '${p.uid} ${p.mainGroupName} ${p.credits} ${p.viewedGroupName} ${p.viewedGid} ${p.viewedThreshold} '
        '${p.memberGroups} ${p.extraGroups}';

    test('the answer and the page give the same groups (own page and one group)', () {
      for (final (json, html) in [
        ('g3_usergroup_v54.json', 'g3_usergroup_web.html'),
        ('g3_usergroup_v54_gid15.json', 'g3_usergroup_web_gid15.html'),
      ]) {
        final api = UserGroupPage.fromApi(v4Json(json));
        final web = UserGroupPage.parse(v4Raw(html))!;
        expect(page(api), page(web), reason: json);
      }
      final gid15 = UserGroupPage.fromApi(v4Json('g3_usergroup_v54_gid15.json'));
      expect((gid15.viewedGroupName, gid15.viewedThreshold), ('论坛元老', 3000));
      expect(UserGroupPage.fromApi(v4Json('g3_usergroup_v54.json')).viewedGroupName, isNull);
    });

    V4Forum forum({required bool api, int uid = _uid}) => V4Forum((o) {
      final gid = o.uri.queryParameters['gid'];
      if (_v4(o.uri)) {
        if (!api) {
          return null;
        }
        final json = v4Json(gid == null ? 'g3_usergroup_v54.json' : 'g3_usergroup_v54_gid15.json');
        // The account's main group taken as a credit-based one below the next (論壇元老) for the progress.
        return V4Reply({...json, 'uid': uid});
      }
      return V4Reply(v4Raw(gid == null ? 'g3_usergroup_web.html' : 'g3_usergroup_web_gid15.html'));
    });

    test('the progress: the same from the answers and from the pages', () async {
      knowV4Status();
      final viaApi = forum(api: true);
      useV4Forum(viaApi);
      final api = await UserGroupProgressRepository(currentUid: () => _uid).fetchProgress().run();
      expect(viaApi.requests.every((r) => _v4(r.uri)), isTrue);
      TsdmAppApi.reset();
      knowV4Status(
        v4Status({
          'credit_pages': <String>['credit_base'],
        }),
      );
      final viaWeb = forum(api: false);
      useV4Forum(viaWeb);
      final web = await UserGroupProgressRepository(currentUid: () => _uid).fetchProgress().run();
      expect(viaWeb.requests.where((r) => _v4(r.uri)), isEmpty);
      expect(api.isRight(), isTrue);
      expect(api.getOrElse((e) => throw e), isNull, reason: 'a special group: no next group');
      expect(web.getOrElse((e) => throw e), isNull);
    });

    test("another account's answer is refused; the forum's message is the failure", () async {
      knowV4Status();
      useV4Forum(forum(api: true, uid: 35));
      final other = await UserGroupProgressRepository(currentUid: () => _uid).fetchProgress().run();
      expect(other.getLeft().toNullable(), isA<IdentityChangedException>());
      useV4Forum(
        V4Forum(
          (o) => const V4Reply({
            'ok': 0,
            'error': 'message',
            'message': '您需要先登录才能继续本操作',
            'message_key': 'to_login',
            'login': 1,
            'uid': 0,
          }),
        ),
      );
      final guest = await UserGroupProgressRepository(currentUid: () => _uid).fetchProgress().run();
      expect(guest.getLeft().toNullable(), isA<ServerRespondedErrorException>());
    });
  });
}
