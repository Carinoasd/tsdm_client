/// The magic item log from the forum's app API (plugin 4.0.0: `type: magic_log`, schema 71): four lists (used, bought,
/// given, received), each with pages.
///
/// * The log is only asked once `status` lists `magic_log` in `magic_pages`; without it the magic page shows no entry
///   to it and nothing is asked (the app has no web parser for it).
/// * Used items link to what they were used on (built from its kind and id), sold and dropped items say so; a row the
///   forum has no time for (`dateline` 0) shows none.
/// * Another account's answers are dropped.
///
/// Fixtures: the test forum's lists (cleaned); the given and received rows are the spec's shape (the test forum has
/// none).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/magic/cubit/magic_center_cubit.dart';
import 'package:tsdm_client/features/magic/cubit/magic_log_cubit.dart';
import 'package:tsdm_client/features/magic/models/magic_log.dart';
import 'package:tsdm_client/features/magic/models/magic_models.dart';
import 'package:tsdm_client/features/magic/repository/magic_repository.dart';
import 'package:tsdm_client/features/magic/view/magic_log_page.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';

import 'tsdmapp_v4_fake.dart';

const _uid = 31;

Map<String, dynamic> _given(String operation) => v4Json('magic_log_v71_givelog_empty.json')
  ..['operation'] = operation
  ..['count'] = 2
  ..['list'] = [
    {
      'magicid': 34,
      'name': '猫娘卡',
      'dateline': 1700000000,
      'amount': 2,
      'user': {'uid': 33, 'username': 'ag_mid'},
    },
    {
      'magicid': 1,
      'name': '抢沙发卡',
      'dateline': 0,
      'amount': 1,
      'user': {'uid': 34, 'username': 'ag_area'},
    },
  ];

final class _Harness {
  _Harness([Map<String, Object?>? answers]) : answers = answers ?? {};

  final Map<String, Object?> answers;
  final asked = <String>[];
  final webPages = <String>[];

  MagicRepository repository() => MagicRepository(
    getPage: (url) async {
      webPages.add(url);
      return '';
    },
    getWindow: (url) async => null,
    postForm: (url, body) async => null,
    getV4: (url) async {
      asked.add(url);
      final uri = Uri.parse(url);
      final q = uri.queryParameters;
      if (q['action'] == 'log') return answers['${q['operation']}:${q['page'] ?? 1}'];
      // The recorded lists are of two accounts: both served to [_uid] here.
      return v4Json(q['action'] == 'shop' ? 'magic_shop_v69.json' : 'magic_mybox_v70.json')..['uid'] = _uid;
    },
  );
}

void main() {
  setUpAll(() async {
    registerV4TestServices();
    await LocaleSettings.setLocale(AppLocale.zhCn);
  });
  tearDownAll(resetV4TestServices);
  setUp(TsdmAppApi.reset);

  group('lists (magic_log, schema 71)', () {
    test('used: what on, sold, dropped, nothing', () {
      final json = v4Json('magic_log_v71_uselog.json');
      final rows = (json['list'] as List).cast<Map<String, dynamic>>();
      json['list'] = [
        ...rows,
        {
          'magicid': 2,
          'name': '照妖镜',
          'dateline': 0,
          'target': {'type': 'tid', 'id': 5, 'url': 'forum.php?mod=viewthread&tid=5'},
        },
        {
          'magicid': 3,
          'name': '金钱卡',
          'dateline': 1700000000,
          'target': {'type': 'pid', 'id': 9, 'url': ''},
        },
        {
          'magicid': 4,
          'name': '喧嚣卡',
          'dateline': 1700000000,
          'target': {'type': 'sell'},
        },
        {
          'magicid': 5,
          'name': '变色卡',
          'dateline': 1700000000,
          'target': {'type': 'drop'},
        },
      ];
      final list = magicLogPageFromApi(json, MagicLogTab.use);
      expect(list.entries, hasLength(rows.length + 4));
      final first = list.entries.first;
      expect(first.name, '猫娘卡');
      expect(first.time, isNotNull);
      expect(first.target?.kind, MagicLogTargetKind.user);
      expect(first.target?.url, '$baseUrl/home.php?mod=space&uid=31');
      expect(list.entries[1].target, isNull);
      final extra = list.entries.sublist(rows.length);
      expect(extra[0].time, isNull);
      expect(extra[0].target?.url, '$baseUrl/forum.php?mod=viewthread&tid=5');
      expect(extra[1].target?.url, '$baseUrl/forum.php?mod=redirect&pid=9&goto=findpost');
      expect(extra[2].target?.kind, MagicLogTargetKind.sold);
      expect(extra[2].target?.url, isNull);
      expect(extra[3].target?.kind, MagicLogTargetKind.dropped);
      expect(first.amount, isNull);
      expect(list.page, 1);
      expect(list.pages, 1);
    });

    test('bought: how many, at what price', () {
      final list = magicLogPageFromApi(v4Json('magic_log_v71_buylog.json'), MagicLogTab.buy);
      expect(list.entries, hasLength(10));
      final second = list.entries[1];
      expect(second.name, '猫娘卡');
      expect(second.amount, 2);
      expect(second.price, 1);
      expect(second.creditTitle, '天使币');
      expect(second.target, isNull);
    });

    test('given and received: to or from whom', () {
      final given = magicLogPageFromApi(_given('givelog'), MagicLogTab.give);
      expect(given.entries.first.userId, 33);
      expect(given.entries.first.username, 'ag_mid');
      expect(given.entries.first.amount, 2);
      expect(given.entries.last.time, isNull);
      final empty = magicLogPageFromApi(v4Json('magic_log_v71_givelog_empty.json'), MagicLogTab.give);
      expect(empty.entries, isEmpty);
    });
  });

  group('repository', () {
    test('without magic_log nothing is asked and the magic page offers no log', () async {
      knowV4Status(
        v4Status({
          'magic_pages': <String>['magic_shop', 'magic_mybox'],
        }),
      );
      final h = _Harness();
      expect(await h.repository().logAvailable(), isFalse);
      await expectLater(h.repository().fetchLog(MagicLogTab.use, 1, _uid), throwsStateError);
      final center = MagicCenterCubit(currentUid: () => _uid, repository: h.repository);
      addTearDown(center.close);
      await center.load();
      expect(center.state.shop, isNotNull);
      expect(center.state.logAvailable, isFalse);
      expect(h.asked.where((u) => u.contains('action=log')), isEmpty);
    });

    test('an old plugin: no log', () async {
      knowV4Status(v4Status({'v4': null, 'magic_pages': null}));
      expect(await _Harness().repository().logAvailable(), isFalse);
    });

    test('with it: each list and page asked as a page of 4.0.0', () async {
      knowV4Status();
      final h = _Harness({
        'uselog:1': v4Json('magic_log_v71_uselog.json'),
        'givelog:2': _given('givelog')..['page'] = 2,
      });
      final center = MagicCenterCubit(currentUid: () => _uid, repository: h.repository);
      addTearDown(center.close);
      await center.load();
      expect(center.state.logAvailable, isTrue);
      final repo = h.repository();
      expect((await repo.fetchLog(MagicLogTab.use, 1, _uid)).entries, hasLength(7));
      final log = Uri.parse(h.asked.last).queryParameters;
      expect(log['operation'], 'uselog');
      expect(log['tsdmv'], '4');
      expect(log['tsdmapp'], 'json');
      expect(log.containsKey('page'), isFalse);
      expect((await repo.fetchLog(MagicLogTab.give, 2, _uid)).page, 2);
      expect(Uri.parse(h.asked.last).queryParameters['page'], '2');
      // An answer of another list is not this one.
      await expectLater(
        _Harness({'buylog:1': v4Json('magic_log_v71_uselog.json')}).repository().fetchLog(MagicLogTab.buy, 1, _uid),
        throwsFormatException,
      );
      expect(h.webPages, isEmpty);
    });

    test("another account, the login, the forum's message", () async {
      knowV4Status();
      Future<void> refused(Object? answer, Matcher matcher) => expectLater(
        _Harness({'uselog:1': answer}).repository().fetchLog(MagicLogTab.use, 1, _uid),
        throwsA(matcher),
      );
      await refused(
        v4Json('magic_log_v71_uselog.json')..['uid'] = 77,
        isA<MagicIdentityException>().having((e) => e.guest, 'guest', isFalse),
      );
      await refused(
        {'ok': 0, 'error': 'message', 'message': '您需要先登录才能继续本操作', 'login': 1, 'uid': 0, 'message_key': 'to_login'},
        isA<MagicIdentityException>().having((e) => e.guest, 'guest', isTrue),
      );
      await refused(
        {'ok': 0, 'error': 'message', 'message': '道具功能已关闭', 'login': 0, 'uid': _uid, 'message_key': 'magics_close'},
        isA<MagicForumMessage>().having((e) => e.message, 'message', '道具功能已关闭'),
      );
    });
  });

  group('cubit', () {
    test("loads each list once; another account's completion is dropped", () async {
      knowV4Status();
      var uid = _uid;
      final h = _Harness({
        'uselog:1': v4Json('magic_log_v71_uselog.json'),
        'buylog:1': v4Json('magic_log_v71_buylog.json'),
      });
      final cubit = MagicLogCubit(currentUid: () => uid, repository: h.repository);
      addTearDown(cubit.close);
      await cubit.load(MagicLogTab.use);
      expect(cubit.state.tab(MagicLogTab.use).page?.entries, hasLength(7));
      await cubit.ensureLoaded(MagicLogTab.use);
      expect(h.asked.where((u) => u.contains('uselog')), hasLength(1));
      final loading = cubit.load(MagicLogTab.buy);
      uid = 77;
      await loading;
      expect(cubit.state.tab(MagicLogTab.buy).page, isNull);
    });
  });

  testWidgets('screen: four lists, links to targets and members', (tester) async {
    await LocaleSettings.setLocale(AppLocale.en);
    knowV4Status();
    final h = _Harness({'uselog:1': v4Json('magic_log_v71_uselog.json'), 'givelog:1': _given('givelog')});
    final cubit = MagicLogCubit(currentUid: () => _uid, repository: h.repository);
    addTearDown(cubit.close);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(home: MagicLogPage(controller: cubit)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('magic-log-tab-receive')), findsOneWidget);
    expect(find.byKey(const ValueKey('magic-log-target-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('magic-log-target-1')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('magic-log-tab-give')));
    await tester.pumpAndSettle();
    expect(find.text(t.magicCenter.forumWords.givenTo(name: 'ag_mid')), findsOneWidget);
    expect(find.text(t.magicCenter.owned(count: 2)), findsOneWidget);
  });
}
