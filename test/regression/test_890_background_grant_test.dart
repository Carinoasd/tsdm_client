/// Sending backgrounds (tsdmapp 3.9.0 `bggrant`, `schema` 31): the catalogue, its search and pages, the background
/// plugin's own form posted as the answer describes it (a tampered one is never used), the expiry shortcuts, the notice
/// left out when not wanted, the plugin's message read as done only when it starts with `success_prefix`, and the
/// entry asked only when `status` says the background plugin is on.
///
/// The answers are the test forum's (scrubbed); the write results are shaped as the spec gives them (sending is left
/// to the emulator check).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/background_grant/models/background_grant.dart';
import 'package:tsdm_client/features/background_grant/repository/background_grant_repository.dart';
import 'package:tsdm_client/features/background_grant/view/background_grant_page.dart';
import 'package:tsdm_client/features/moderate/utils/panel_tools_access.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';

Map<String, dynamic> _fixture(String name) =>
    jsonDecode(File('test/data/tsdmapp_390/$name.json').readAsStringSync()) as Map<String, dynamic>;

/// [json] without the preview images (the image cache is not set up in these tests).
Map<String, dynamic>? _noImages(Map<String, dynamic>? json) => json == null
    ? null
    : {
        ...json,
        if (json['backgrounds'] is List)
          'backgrounds': [
            for (final b in json['backgrounds'] as List) {...(b as Map<String, dynamic>)}..remove('image'),
          ],
      };

/// A repository answering [answer] for each ask (without the preview images) and [reply] for a post, recording both.
BackgroundGrantRepository _repo({
  Map<String, dynamic>? Function(Map<String, String> query)? answer,
  Object? reply,
  List<Map<String, String>>? asked,
  List<(String, Map<String, String>)>? posted,
  int Function()? uid,
}) => BackgroundGrantRepository(
  ask: (query) async {
    asked?.add(query);
    return _noImages(answer == null ? _fixture('bggrant_can') : answer(query));
  },
  post: (url, data) async {
    posted?.add((url, data));
    return reply ?? _fixture('bggrant_result_success');
  },
  currentUid: uid ?? () => 31,
);

Future<void> _pump(WidgetTester tester, Widget home) async {
  tester.view.physicalSize = const Size(900, 2600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(scaffoldMessengerKey: snackbarKey, home: home),
    ),
  );
  await tester.pumpAndSettle();
}

TextEditingController _field(WidgetTester tester, String key) =>
    tester.widget<TextField>(find.byKey(ValueKey(key))).controller!;

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
  });

  setUp(PanelToolsAccess.reset);

  group('answer', () {
    test('the catalogue, the expiry and the form of an account that may send', () {
      final info = BackgroundGrantInfo.fromJson(_fixture('bggrant_can'))!;
      expect(info.uid, 31);
      expect(info.usable, isTrue);
      expect(info.items.map((b) => b.file), ['1209-1.jpg', '1209-2.jpg', '1209-3.jpg', '1209-4.jpg']);
      expect(info.items.first.name, '夜空');
      expect(info.items.first.imageUrl, 'https://forum.test/source/plugin/background/background/1209-1.jpg');
      expect(info.paging, (page: 1, pages: 1, total: 4));
      expect(info.defaultExpiry, '0');
      expect(info.presets.map((p) => (p.days, p.months)), [(0, 0), (7, 0), (0, 1), (0, 3), (0, 12)]);
      expect(info.maxUrl, 255);
      final form = info.form!;
      expect(form.url, '$baseUrl/plugin.php?id=background:memcp&ac=slotadd');
      expect(form.fields, {'formhash': 'f1f2f3f4', 'slotaddsubmit': 'true'});
      expect(
        (form.urlField, form.uidsField, form.timeField, form.notifyField),
        ('slotaddurl', 'slotadduid', 'slotaddtime', 'slotaddnotify'),
      );
      expect(form.successPrefix, '已发放给');
    });

    test('an account that may not send, a plugin missing, a search without match', () {
      final cannot = BackgroundGrantInfo.fromJson(_fixture('bggrant_cannot'))!;
      expect(cannot.canGrant, isFalse);
      expect(cannot.usable, isFalse);
      expect(BackgroundGrantInfo.fromJson({'ok': 1, 'api': 1, 'installed': 0}), isNull);
      expect(BackgroundGrantInfo.fromJson({'ok': 0, 'error': 'action'}), isNull);
      expect(BackgroundGrantInfo.fromJson(null), isNull);
      final none = BackgroundGrantInfo.fromJson(_fixture('bggrant_none'))!;
      expect(none.items, isEmpty);
      expect(none.paging.total, 0);
      final kw = BackgroundGrantInfo.fromJson(_fixture('bggrant_keyword'))!;
      expect(kw.keyword, '夜空');
      expect(kw.items.length, 2);
    });

    test('a form posting anywhere else, or with other field names, is never used', () {
      Map<String, dynamic> form(Map<String, dynamic> change) => {
        ...(_fixture('bggrant_can')['form'] as Map<String, dynamic>),
        ...change,
      };
      expect(BackgroundGrantForm.parse(form({})), isNotNull);
      for (final bad in [
        {'url': 'https://evil.test/plugin.php?id=background:memcp&ac=slotadd'},
        {'url': 'plugin.php?id=background:memcp&ac=slotdel'},
        {'url': 'plugin.php?id=other:memcp&ac=slotadd'},
        {'url': 'plugin.php?id=background:memcp&ac=slotadd&action=x'},
        {'url': 'home.php?id=background:memcp&ac=slotadd'},
        {'url': ''},
        {'uids_field': 'slotadduid[]'},
        {'notify_field': ''},
        {'success_prefix': ''},
        {'fields': 'formhash'},
      ]) {
        expect(BackgroundGrantForm.parse(form(bad)), isNull, reason: '$bad');
      }
    });

    test('expiry shortcuts as the website sends them', () {
      const p = BackgroundExpiryPreset.new;
      final jan31 = DateTime(2026, 1, 31);
      expect(p(label: '', days: 0, months: 0).value(jan31), '0');
      expect(p(label: '', days: 7, months: 0).value(jan31), '7天');
      expect(p(label: '', days: 0, months: 1).value(jan31), '2026-02-28');
      expect(p(label: '', days: 0, months: 3).value(DateTime(2026, 11, 12)), '2027-02-12');
      expect(p(label: '', days: 0, months: 12).value(jan31), '2027-01-31');
    });

    test('the body: the image, the members, the expiry, the notice only when wanted', () {
      final form = BackgroundGrantInfo.fromJson(_fixture('bggrant_can'))!.form!;
      expect(form.body(image: '1209-2.jpg', uids: [35, 36], expiry: '7天', notify: true), {
        'formhash': 'f1f2f3f4',
        'slotaddsubmit': 'true',
        'slotaddurl': '1209-2.jpg',
        'slotadduid': '35,36',
        'slotaddtime': '7天',
        'slotaddnotify': '1',
      });
      final quiet = form.body(image: 'https://img.test/a.jpg', uids: [35], expiry: '', notify: false);
      expect(quiet.containsKey('slotaddnotify'), isFalse);
      expect(quiet['slotaddtime'], '0');
      expect(quiet['slotaddurl'], 'https://img.test/a.jpg');
    });

    test('the fixed fields never carry the ones the app fills: no notice is no field', () {
      final json = _fixture('bggrant_can')['form'] as Map<String, dynamic>;
      final form = BackgroundGrantForm.parse({
        ...json,
        'fields': {...json['fields'] as Map<String, dynamic>, 'slotaddnotify': '1', 'slotadduid': '1'},
      })!;
      expect(form.fields, {'formhash': 'f1f2f3f4', 'slotaddsubmit': 'true'});
      final body = form.body(image: 'a.jpg', uids: [35], expiry: '0', notify: false);
      expect(body.containsKey('slotaddnotify'), isFalse);
      expect(body['slotadduid'], '35');
    });

    test('done only when the message starts with the prefix', () {
      expect(backgroundGrantResultOf('已发放给 1 位会员，到期 2026-11-19 23:59', '已发放给').success, isTrue);
      expect(backgroundGrantResultOf('没有发放背景的权限', '已发放给'), (success: false, message: '没有发放背景的权限'));
      expect(backgroundGrantResultOf('请填写用户 UID（已发放给）', '已发放给').success, isFalse);
      expect(backgroundGrantResultOf('已发放给', '').success, isFalse);
    });
  });

  group('repository', () {
    test('search and page are asked as query, nothing for the first page unfiltered', () async {
      final asked = <Map<String, String>>[];
      final repo = _repo(asked: asked);
      await repo.load();
      await repo.load(keyword: '夜空');
      await repo.load(page: 2);
      expect(asked, [
        <String, String>{},
        {'kw': '夜空'},
        {'page': '2'},
      ]);
    });

    test('an answer served to another account is dropped', () async {
      await expectLater(_repo(uid: () => 32).load(), throwsA(isA<IdentityChangedException>()));
    });

    test('posts the form once and reads the message', () async {
      final posted = <(String, Map<String, String>)>[];
      final repo = _repo(posted: posted);
      final info = (await repo.load())!;
      final done = await repo.submit(info, image: '1209-1.jpg', uids: [35], expiry: '0', notify: true);
      expect(done.success, isTrue);
      expect(done.message, startsWith('已发放给 1 位会员'));
      expect(posted.single.$1, info.form!.url);
      expect(posted.single.$2['slotadduid'], '35');

      final refused = await _repo(
        reply: _fixture('bggrant_result_noperm'),
      ).submit(info, image: '1209-1.jpg', uids: [35], expiry: '0', notify: true);
      expect(refused, (success: false, message: '没有发放背景的权限'));
    });

    test('never posts once the account changed, and drops a result for another account', () async {
      final posted = <(String, Map<String, String>)>[];
      final info = (await _repo().load())!;
      await expectLater(
        _repo(posted: posted, uid: () => 32).submit(info, image: 'a.jpg', uids: [35], expiry: '0', notify: true),
        throwsA(isA<IdentityChangedException>()),
      );
      expect(posted, isEmpty);
      final other = {..._fixture('bggrant_result_success'), 'uid': 32};
      await expectLater(
        _repo(reply: other).submit(info, image: 'a.jpg', uids: [35], expiry: '0', notify: true),
        throwsA(isA<IdentityChangedException>()),
      );
    });
  });

  group('entry', () {
    Map<String, dynamic> status({int bggrant = 1, int report = 1}) => {
      'ok': 1,
      'version': '3.9.0',
      'admin': 1,
      'modcp_report': report,
      'bggrant': bggrant,
    };

    test('bggrant is asked only when status says the plugin is on', () async {
      final asked = <Map<String, String>>[];
      expect(
        await PanelToolsAccess.check(
          31,
          status: () async => status(bggrant: 0),
          backgrounds: _repo(asked: asked),
        ),
        (background: false, modcpReport: true),
      );
      expect(asked, isEmpty);
      expect(
        await PanelToolsAccess.check(
          32,
          status: () async => status(report: 0),
          backgrounds: _repo(uid: () => 32),
        ),
        isNull,
        reason: 'the catalogue served to another account is dropped, nothing told',
      );
      expect(
        await PanelToolsAccess.check(
          33,
          status: () async => status(),
          backgrounds: _repo(asked: asked),
        ),
        (background: true, modcpReport: true),
      );
      expect(asked.length, 1);
      // Kept: not asked again.
      await PanelToolsAccess.check(33, status: () async => throw Exception('asked again'));
      expect(PanelToolsAccess.cached(33), (background: true, modcpReport: true));
    });

    test('can_grant 0 hides it; an older plugin and a failed status tell nothing', () async {
      expect(
        await PanelToolsAccess.check(
          31,
          status: () async => status(),
          backgrounds: _repo(answer: (_) => _fixture('bggrant_cannot')),
        ),
        (background: false, modcpReport: true),
      );
      expect(
        await PanelToolsAccess.check(34, status: () async => {'ok': 1, 'version': '3.8.0'}),
        (background: false, modcpReport: false),
      );
      expect(await PanelToolsAccess.check(35, status: () async => null), isNull);
      expect(PanelToolsAccess.cached(35), isNull);
      expect(
        await PanelToolsAccess.check(36, status: () async => status(), stillCurrent: () => false, backgrounds: _repo()),
        isNull,
      );
      expect(PanelToolsAccess.cached(36), isNull);
    });

    test('the catalogue failing is shown without the entry and asked again later', () async {
      expect(
        await PanelToolsAccess.check(
          31,
          status: () async => status(),
          backgrounds: _repo(answer: (_) => null),
        ),
        (background: false, modcpReport: true),
      );
      expect(PanelToolsAccess.cached(31), isNull);
    });

    test('the first page read for the entry is handed to the page once', () async {
      await PanelToolsAccess.check(31, status: () async => status(), backgrounds: _repo());
      expect(PanelToolsAccess.takeFirstPage(31)?.items.length, 4);
      expect(PanelToolsAccess.takeFirstPage(31), isNull);
      expect(PanelToolsAccess.takeFirstPage(32), isNull);
    });
  });

  group('page', () {
    testWidgets('pick, fill, confirm, send: the plugin message is shown', (tester) async {
      final posted = <(String, Map<String, String>)>[];
      await _pump(
        tester,
        BackgroundGrantPage(
          repository: _repo(posted: posted),
          initialMembers: '35',
          today: () => DateTime(2026, 1, 31),
        ),
      );
      expect(_field(tester, 'bggrant-members').text, '35');
      expect(_field(tester, 'bggrant-expiry').text, '0');
      expect(find.byKey(const ValueKey('bggrant-item-1')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('bggrant-item-2')));
      await tester.pump();
      expect(_field(tester, 'bggrant-image').text, '1209-2.jpg');
      await tester.tap(find.byKey(const ValueKey('bggrant-preset-2')));
      await tester.pump();
      expect(_field(tester, 'bggrant-expiry').text, '2026-02-28');
      await tester.enterText(find.byKey(const ValueKey('bggrant-members')), '35, 36');
      await tester.tap(find.byKey(const ValueKey('bggrant-notify')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('bggrant-send')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('UID 35、36'), findsOneWidget);
      await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.byType(FilledButton)));
      await tester.pumpAndSettle();

      expect(posted.single.$2, {
        'formhash': 'f1f2f3f4',
        'slotaddsubmit': 'true',
        'slotaddurl': '1209-2.jpg',
        'slotadduid': '35,36',
        'slotaddtime': '2026-02-28',
      });
      expect(find.textContaining('1209-1.jpg'), findsOneWidget);
    });

    testWidgets('nothing is sent without an image or with a token that is not a UID', (tester) async {
      final posted = <(String, Map<String, String>)>[];
      await _pump(
        tester,
        BackgroundGrantPage(
          repository: _repo(posted: posted),
          initialMembers: '35',
        ),
      );
      await tester.tap(find.byKey(const ValueKey('bggrant-send')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      await tester.enterText(find.byKey(const ValueKey('bggrant-image')), '1209-1.jpg');
      await tester.enterText(find.byKey(const ValueKey('bggrant-members')), '35 abc');
      await tester.tap(find.byKey(const ValueKey('bggrant-send')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(posted, isEmpty);
    });

    testWidgets('search and pages are asked of the forum', (tester) async {
      final asked = <Map<String, String>>[];
      await _pump(
        tester,
        BackgroundGrantPage(
          repository: _repo(
            asked: asked,
            answer: (q) => q.containsKey('kw')
                ? _fixture('bggrant_keyword')
                : {..._fixture('bggrant_can'), 'pages': 2, 'page': int.parse(q['page'] ?? '1')},
          ),
        ),
      );
      await tester.tap(find.byIcon(Icons.chevron_right));
      await tester.pumpAndSettle();
      expect(asked.last, {'page': '2'});
      await tester.enterText(find.byKey(const ValueKey('bggrant-search')), '夜空');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(asked.last, {'kw': '夜空'});
      expect(find.byKey(const ValueKey('bggrant-item-3')), findsNothing);
    });

    testWidgets('an account that may not send sees the reason only', (tester) async {
      await _pump(tester, BackgroundGrantPage(repository: _repo(answer: (_) => _fixture('bggrant_cannot'))));
      expect(find.byKey(const ValueKey('bggrant-send')), findsNothing);
      expect(find.text(t.medalTitleTools.noPermission), findsOneWidget);
    });
  });
}
