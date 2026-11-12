/// The members' permissions in a forum (tsdmapp 3.9.0 `modcp_forumaccess`, `schema` 38): the forums to choose from,
/// the members listed with each permission denied or allowed by the admin centre, the form sent as the answer
/// describes it (the whole set denied, viewing denied denying all, nothing denied giving the user group's back), the
/// panel's verdict (`result`) worded by the app, done only when it says so, the panel's "no permission" in its words.
///
/// The GET answers are the test forum's (scrubbed; it has no member set apart, so the entries are the spec's shape);
/// the answers to the form are shaped as the spec gives them.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/moderate/models/modcp_json_pages.dart';
import 'package:tsdm_client/features/moderate/models/modcp_members.dart';
import 'package:tsdm_client/features/moderate/models/modcp_panel.dart';
import 'package:tsdm_client/features/moderate/repository/modcp_pages_repository.dart';
import 'package:tsdm_client/features/moderate/repository/modcp_repository.dart';
import 'package:tsdm_client/features/moderate/view/modcp_forum_access_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';

Map<String, dynamic> _fixture(String name, {int uid = 33}) => {
  ...jsonDecode(File('test/data/tsdmapp_390/$name.json').readAsStringSync()) as Map<String, dynamic>,
  'uid': uid,
};

Map<String, dynamic> _entry(int uid, String name, {int view = 0, int post = 0, int reply = 0, int getattach = 0}) => {
  'uid': uid,
  'username': name,
  'fid': 2,
  'forum': '公告与新手报到',
  'view': view,
  'post': post,
  'reply': reply,
  'getattach': getattach,
  'getimage': 0,
  'postattach': 0,
  'postimage': 0,
  'adminuid': 33,
  'admin': 'ag_mid',
  'dateline': 1700000000,
};

/// Forum 2 listing [entries], with the result of a form sent ([done], [errorKey]).
Map<String, dynamic> _page({
  List<Map<String, dynamic>> entries = const [],
  int done = 0,
  String errorKey = '',
  String keyword = '',
}) => {
  ..._fixture('modcp_access_fid2'),
  'list': entries,
  'count': entries.length,
  'keyword': keyword,
  'result': {
    'done': done,
    'error': const {'': 0, 'nouser': 1, 'staff': 2, 'whitelist': 3}[errorKey] ?? 9,
    'error_key': errorKey,
  },
  'message_key': '',
};

ModcpAccessPage _read(Map<String, dynamic> json) => modcpAccessFromApi(json)!;

ModcpPagesRepository _repo({
  Object? Function(String url)? answer,
  Object? reply,
  List<String>? asked,
  List<(String, Map<String, String>)>? posted,
}) {
  Future<Either<AppException, ({int statusCode, Object? data})>> get(String url) async {
    asked?.add(url);
    return right((statusCode: 200, data: answer?.call(url) ?? _page(entries: [_entry(35, 'ag_low2', post: -1)])));
  }

  Future<Either<AppException, ({int statusCode, Object? data})>> post(String url, Map<String, String> body) async {
    posted?.add((url, body));
    return right((statusCode: 200, data: reply ?? _page(done: 1)));
  }

  return ModcpPagesRepository(
    panel: ModcpRepository(get: get, post: post, currentUid: () => 33),
    get: get,
    post: post,
    currentUid: () => 33,
  );
}

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
  });

  group('answer', () {
    test('without a forum: the forums only, nothing to set', () {
      final page = _read(_fixture('modcp_access_nofid'));
      expect((page.needForum, page.canAdd, page.canSet), (true, false, false));
      expect(page.forums.map((f) => f.fid), [2, 6, 12, 25]);
      expect((page.addForm, page.searchForm), (null, null));
    });

    test('a forum moderated: the forms, nothing sent', () {
      final page = _read(_fixture('modcp_access_fid2'));
      expect((page.fid, page.forum, page.canSet, page.result), (2, '公告与新手报到', true, ModcpAccessResult.none));
      expect((page.page, page.pages, page.count), (1, 1, 0));
      final add = page.addForm!;
      expect(add.form.url, '$baseUrl/forum.php?mod=modcp&action=forumaccess');
      expect(add.form.fields, {'formhash': 'f1f2f3f4', 'op': '', 'addsubmit': 'true'});
      expect(add.denyFields[ModcpAccessRight.postimage], 'new_postimage');
      expect(page.searchForm!.form.fields, {'formhash': 'f1f2f3f4', 'searchsubmit': 'true'});
    });

    test('the members: denied, allowed by the admin centre, the user group otherwise', () {
      final page = _read(_page(entries: [_entry(35, 'ag_low2', post: -1, reply: -1, getattach: 1)]));
      final entry = page.entries.single;
      expect((entry.uid, entry.username, entry.admin), (35, 'ag_low2', 'ag_mid'));
      expect(entry.denied, {ModcpAccessRight.post, ModcpAccessRight.reply});
      expect(entry.allowed, {ModcpAccessRight.getattach});
    });

    test("the panel's verdicts", () {
      expect(_read(_page(done: 1)).result, ModcpAccessResult.done);
      expect(_read(_page(errorKey: 'nouser')).result, ModcpAccessResult.nouser);
      expect(_read(_page(errorKey: 'staff')).result, ModcpAccessResult.staff);
      expect(_read(_page(errorKey: 'whitelist')).result, ModcpAccessResult.whitelist);
      expect(_read(_page(errorKey: 'later')).result, ModcpAccessResult.unknown);
    });

    test('a form sent elsewhere, or missing a permission, is never used', () {
      final add = _fixture('modcp_access_fid2')['add'] as Map<String, dynamic>;
      expect(ModcpAccessForm.parse(add), isNotNull);
      final deny = add['deny_fields'] as Map<String, dynamic>;
      for (final bad in [
        {'url': 'forum.php?mod=modcp&action=member&op=edit'},
        {'url': 'https://evil.test/forum.php?mod=modcp&action=forumaccess'},
        {'url': 'forum.php?mod=modcp&action=forumaccess&op=delete'},
        {'user_field': 'new user'},
        {
          'fields': {'formhash': 'f', 'op': 'delete', 'addsubmit': 'true'},
        },
        {
          'fields': {'formhash': 'f', 'addsubmit': 'true'},
        },
        {
          'fields': {'formhash': 'f', 'op': '', 'addsubmit': 'true', 'mod': 'member'},
        },
        {
          'deny_fields': {...deny}..remove('postimage'),
        },
        {
          'deny_fields': {...deny, 'view': 'new_view[]x'},
        },
      ]) {
        expect(ModcpAccessForm.parse({...add, ...bad}), isNull, reason: '$bad');
      }
    });

    test('the bodies: the whole set denied, viewing denies all, nothing denied restores', () {
      final form = _read(_fixture('modcp_access_fid2')).addForm!;
      expect(form.body(2, ' ag_low2 ', {ModcpAccessRight.post, ModcpAccessRight.getimage}), {
        'formhash': 'f1f2f3f4',
        'op': '',
        'addsubmit': 'true',
        'fid': '2',
        'new_user': 'ag_low2',
        'new_post': '-1',
        'new_getimage': '-1',
      });
      expect(
        form.body(2, 'ag_low2', {ModcpAccessRight.view}).keys.where((k) => k.startsWith('new_') && k != 'new_user'),
        ['new_view', 'new_post', 'new_reply', 'new_getattach', 'new_getimage', 'new_postattach', 'new_postimage'],
      );
      expect(form.restoreBody(2, 'ag_low2'), {
        'formhash': 'f1f2f3f4',
        'op': '',
        'addsubmit': 'true',
        'fid': '2',
        'new_user': 'ag_low2',
        'deleteaccess': '1',
      });
    });
  });

  group('repository', () {
    test('the forum and its pages; a member looked up with the form', () async {
      final asked = <String>[];
      final posted = <(String, Map<String, String>)>[];
      final repo = _repo(
        asked: asked,
        posted: posted,
        reply: _page(keyword: 'ag_low2'),
      );
      await repo.fetchAccess(fid: 2, page: 2).run();
      expect(asked.last, '$baseUrl/forum.php?mod=modcp&action=forumaccess&fid=2&page=2&tsdmapp=json&nodoc=1');
      final found = await repo.searchAccess(_read(_page()), 'ag_low2').run();
      expect(posted.single.$1, '$baseUrl/forum.php?mod=modcp&action=forumaccess&tsdmapp=json');
      expect(posted.single.$2, {'formhash': 'f1f2f3f4', 'searchsubmit': 'true', 'fid': '2', 'suser': 'ag_low2'});
      expect((((found as Right).value as ModcpReady).value as ModcpAccessPage).keyword, 'ag_low2');
    });

    test("the panel's \"no permission\" in its words", () async {
      final answer = await _repo(answer: (_) => _fixture('modcp_access_noperm')).fetchAccess(fid: 2).run();
      expect(((answer as Right).value as ModcpRefused).message, contains('抱歉，您无此权限'));
    });

    test('done only when the panel says so; its reasons; nothing said is not done', () async {
      final shown = _read(_page());
      final posted = <(String, Map<String, String>)>[];
      final done = await _repo(posted: posted).setAccess(shown, 'ag_low2', {ModcpAccessRight.post}).run();
      expect(posted.single.$2['new_post'], '-1');
      expect(((done as Right).value as ModcpPosted<ModcpAccessPage>).outcome, isA<ModcpWriteDone>());

      for (final key in ['nouser', 'staff', 'whitelist']) {
        final refused = await _repo(reply: _page(errorKey: key)).setAccess(shown, 'x', {ModcpAccessRight.post}).run();
        final value = (refused as Right).value as ModcpPosted<ModcpAccessPage>;
        expect(value.outcome, isA<ModcpWriteRefused>(), reason: key);
        expect(value.page!.result.name, key);
      }

      final silent = await _repo(reply: _page()).setAccess(shown, 'x', {ModcpAccessRight.post}).run();
      expect(((silent as Right).value as ModcpPosted<ModcpAccessPage>).outcome, isA<ModcpWriteUnknown>());

      final restored = <(String, Map<String, String>)>[];
      await _repo(posted: restored).setAccess(shown, 'ag_low2', {}).run();
      expect(restored.single.$2['deleteaccess'], '1');
      expect(restored.single.$2.keys.where((k) => k.startsWith('new_') && k != 'new_user'), isEmpty);
    });

    test('nothing sent without a name, the form, or a forum moderated', () async {
      final posted = <(String, Map<String, String>)>[];
      final repo = _repo(posted: posted);
      await repo.setAccess(_read(_page()), ' ', {ModcpAccessRight.post}).run();
      await repo.setAccess(_read({..._page(), 'can_add': 0}), 'x', {ModcpAccessRight.post}).run();
      await repo.setAccess(_read(_fixture('modcp_access_nofid')), 'x', {ModcpAccessRight.post}).run();
      expect(posted, isEmpty);
    });
  });

  group('page', () {
    Future<void> pump(WidgetTester tester, ModcpPagesRepository repo) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            scaffoldMessengerKey: snackbarKey,
            home: ModcpForumAccessPage(repository: repo),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('a member denied posting once confirmed; the panel says it is done', (tester) async {
      final posted = <(String, Map<String, String>)>[];
      await pump(
        tester,
        _repo(
          posted: posted,
          answer: (url) => url.contains('fid=2') ? _page() : _fixture('modcp_access_nofid'),
          reply: _page(done: 1, entries: [_entry(35, 'ag_low2', post: -1)]),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('modcp-forum-2')));
      await tester.pumpAndSettle();
      expect(find.text('No members with special permissions'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('modcp-access-add')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('modcp-access-name')), 'ag_low2');
      await tester.tap(find.byKey(const ValueKey('modcp-access-deny-post')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('modcp-access-save')));
      await tester.pumpAndSettle();
      expect(posted, isEmpty);
      expect(find.text('ag_low2 · 公告与新手报到'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(posted.single.$2, containsPair('new_post', '-1'));
      expect(find.text('Saved'), findsOneWidget);
      expect(find.byKey(const ValueKey('modcp-access-35-post')), findsOneWidget);
    });

    testWidgets("a member's permissions given back; the panel's reason worded by the app", (tester) async {
      final posted = <(String, Map<String, String>)>[];
      await pump(
        tester,
        _repo(
          posted: posted,
          reply: _page(errorKey: 'whitelist'),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('modcp-access-35')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('modcp-access-restore')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Restore defaults'));
      await tester.pumpAndSettle();
      expect(posted.single.$2, containsPair('deleteaccess', '1'));
      expect(posted.single.$2['new_user'], 'ag_low2');
      expect(find.text('Set in the admin centre: moderators can not change it'), findsOneWidget);
    });

    testWidgets('a permission the admin centre allowed can not be ticked', (tester) async {
      await pump(tester, _repo(answer: (_) => _page(entries: [_entry(35, 'ag_low2', getattach: 1)])));
      await tester.tap(find.byKey(const ValueKey('modcp-access-35')));
      await tester.pumpAndSettle();
      final tile = tester.widget<CheckboxListTile>(find.byKey(const ValueKey('modcp-access-deny-getattach')));
      expect(tile.onChanged, isNull);
    });

    testWidgets("the panel's \"no permission\" shown in its words", (tester) async {
      await pump(tester, _repo(answer: (_) => _fixture('modcp_access_noperm')));
      expect(find.textContaining('抱歉，您无此权限'), findsOneWidget);
    });
  });
}
