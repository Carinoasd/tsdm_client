/// The panel's first page and the moderators' notes (tsdmapp 3.9.0 `modcp_home`, `schema` 39): what waits (`counts`,
/// the moderation count null when the forum does not count it), the notes and their forms (sent only to the panel's
/// own page, the ids indexed), a note added told done only when the page drawn again lists a new one, deleted notes
/// still listed not done, the panel's login and refusals, and an answer served to another account dropped.
///
/// The GET answers are the test forum's (scrubbed); the answers to the forms (the same page with `message_key`) are
/// shaped as the spec gives them: writing is left to the emulator check.
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
import 'package:tsdm_client/features/moderate/view/modcp_notes_page.dart';
import 'package:tsdm_client/features/moderate/widgets/moderate_panel_login.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';

Map<String, dynamic> _fixture(String name) =>
    jsonDecode(File('test/data/tsdmapp_390/$name.json').readAsStringSync()) as Map<String, dynamic>;

/// The panel's login form (the panel's report page's, the same for every page) served to account 33.
Map<String, dynamic> _login() =>
    jsonDecode(
          File(
                'test/data/tsdmapp_390/modcp_report_login.json',
              )
              .readAsStringSync()
              .replaceAll('"uid": 34', '"uid": 33')
              .replaceAll("discuz_uid = '34'", "discuz_uid = '33'"),
        )
        as Map<String, dynamic>;

Map<String, dynamic> _note(int id, {String admin = 'ag_mid', int canDelete = 1, int toModerator = 1}) => {
  'id': id,
  'admin': admin,
  'adminid': 2,
  'dateline': 1700000000,
  'expiration': 1702592000,
  'days': 30,
  'message': '第 $id 则\n第二行',
  'message_html': '第 $id 则<br />第二行',
  'to_supermod': 1,
  'to_moderator': toModerator,
  'can_delete': canDelete,
};

/// The first page with [notes], waiting [moderate] (null: not counted), served to [uid].
Map<String, dynamic> _home({
  List<Map<String, dynamic>> notes = const [],
  int? moderate,
  int uid = 33,
  String key = '',
}) {
  final json = _fixture('modcp_home');
  return {
    ...json,
    'uid': uid,
    'counts': {'moderate': moderate, 'notes': notes.length, 'forums': 20},
    'notes': notes,
    if (key.isNotEmpty || notes.isNotEmpty) 'message_key': key,
  };
}

ModcpHome _read(Map<String, dynamic> json) => modcpHomeFromApi(json)!;

/// A repository answering [answer] for each GET and [reply] for a POST, recording both.
ModcpPagesRepository _repo({
  Object? Function(String url)? answer,
  Object? reply,
  List<String>? asked,
  List<(String, Map<String, String>)>? posted,
  int Function()? uid,
}) {
  Future<Either<AppException, ({int statusCode, Object? data})>> get(String url) async {
    asked?.add(url);
    return right((statusCode: 200, data: answer == null ? _home() : answer(url)));
  }

  Future<Either<AppException, ({int statusCode, Object? data})>> post(String url, Map<String, String> body) async {
    posted?.add((url, body));
    return right((statusCode: 200, data: reply));
  }

  return ModcpPagesRepository(
    panel: ModcpRepository(get: get, post: post, currentUid: uid ?? () => 33),
    get: get,
    post: post,
    currentUid: uid ?? () => 33,
  );
}

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
  });

  group('answer', () {
    test('the test forum: nothing counted for moderation, no notes, both forms', () {
      final home = _read(_fixture('modcp_home'));
      expect(home.uid, 33);
      expect((home.moderateCount, home.noteCount, home.forumCount), (null, 0, 20));
      expect(home.notes, isEmpty);
      expect(home.forums.map((f) => f.fid), [2, 6, 12, 25]);
      final add = home.addForm!;
      expect(add.form.url, '$baseUrl/forum.php?mod=modcp&action=home');
      expect(add.form.fields, {'formhash': 'f1f2f3f4', 'op': 'addnote', 'submit': 'true'});
      expect(add.daysDefault, 30);
      expect(home.deleteForm!.form.fields, {'formhash': 'f1f2f3f4', 'op': 'delete', 'notlistsubmit': 'yes'});
    });

    test('the notes and what waits', () {
      final home = _read(
        _home(
          moderate: 7,
          notes: [
            _note(3),
            _note(4, admin: 'ag_admin', canDelete: 0, toModerator: 0),
          ],
        ),
      );
      expect(home.moderateCount, 7);
      expect(home.noteCount, 2);
      final [a, b] = home.notes;
      expect(
        (a.id, a.admin, a.message, a.toSupermod, a.toModerator, a.canDelete),
        (
          3,
          'ag_mid',
          '第 3 则\n第二行',
          true,
          true,
          true,
        ),
      );
      expect((b.toModerator, b.canDelete), (false, false));
      expect((a.dateline, a.expiration), (1700000000, 1702592000));
    });

    test('not the page: older plugins, another type, an older schema', () {
      expect(modcpHomeFromApi({..._fixture('modcp_home'), 'schema': 38}), isNull);
      expect(modcpHomeFromApi({..._fixture('modcp_home'), 'type': 'modcp_thread'}), isNull);
      expect(modcpHomeFromApi({..._fixture('modcp_home'), 'ok': 0}), isNull);
    });

    test('a form sent anywhere else, or of another shape, is never used', () {
      final add = _fixture('modcp_home')['add'] as Map<String, dynamic>;
      expect(ModcpNoteAddForm.parse(add), isNotNull);
      for (final bad in [
        {'url': 'https://evil.test/forum.php?mod=modcp&action=home'},
        {'url': 'forum.php?mod=modcp&action=report'},
        {'url': 'forum.php?mod=modcp&action=home&op=delete'},
        {'url': 'plugin.php?mod=modcp&action=home'},
        {'url': '//evil.test/forum.php?mod=modcp&action=home'},
        {'message_field': 'new message'},
        {'supermod_field': 'newaccess[2][x]'},
        {'fields': 'formhash'},
        {
          'fields': {'a b': '1'},
        },
      ]) {
        expect(ModcpNoteAddForm.parse({...add, ...bad}), isNull, reason: '$bad');
      }
      // The fixed fields never choose the page nor the operation: the panel reads them over the URL's.
      for (final fields in [
        {'formhash': 'f', 'op': 'addnote', 'submit': 'true', 'mod': 'post'},
        {'formhash': 'f', 'op': 'addnote', 'submit': 'true', 'action': 'member'},
        {'formhash': 'f', 'op': 'delete', 'submit': 'true'},
        {'formhash': 'f', 'submit': 'true'},
        {'formhash': 'f', 'op': 'addnote', 'do': 'x'},
      ]) {
        expect(ModcpNoteAddForm.parse({...add, 'fields': fields}), isNull, reason: '$fields');
      }
      final delete = _fixture('modcp_home')['delete'] as Map<String, dynamic>;
      expect(
        ModcpIdsForm.parse(
          {
            ...delete,
            'fields': {'formhash': 'f', 'op': 'addnote', 'notlistsubmit': 'yes'},
          },
          action: 'home',
          expect: const {'op': 'delete'},
        ),
        isNull,
      );
      expect(
        ModcpIdsForm.parse({...delete, 'ids_field': 'delete'}, action: 'home', expect: const {'op': 'delete'}),
        isNull,
      );
      expect(ModcpIdsForm.parse(delete, action: 'forumaccess', expect: const {'op': 'delete'}), isNull);
    });

    test('the fixed fields never carry those the app fills', () {
      final add = _fixture('modcp_home')['add'] as Map<String, dynamic>;
      final form = ModcpNoteAddForm.parse({
        ...add,
        'fields': {
          ...add['fields'] as Map<String, dynamic>,
          'newmessage': 'x',
          'newaccess[2]': '1',
          'newexpiration': '999',
        },
      })!;
      expect(form.form.fields, {'formhash': 'f1f2f3f4', 'op': 'addnote', 'submit': 'true'});
    });

    test('the bodies: who sees the note, its days; the ids indexed', () {
      final home = _read(_fixture('modcp_home'));
      expect(home.addForm!.body(message: ' 交接 ', toSupermod: true, toModerator: false, days: 7), {
        'formhash': 'f1f2f3f4',
        'op': 'addnote',
        'submit': 'true',
        'newmessage': '交接',
        'newaccess[2]': '1',
        'newexpiration': '7',
      });
      expect(home.addForm!.body(message: 'x', toSupermod: false, toModerator: true, days: 0)['newexpiration'], '30');
      expect(home.deleteForm!.body(['3', '9']), {
        'formhash': 'f1f2f3f4',
        'op': 'delete',
        'notlistsubmit': 'yes',
        'delete[0]': '3',
        'delete[1]': '9',
      });
    });
  });

  group('repository', () {
    test('the first page in the JSON mode; the login, the refusals, another account', () async {
      final asked = <String>[];
      final ok = await _repo(asked: asked).fetchHome().run();
      expect(asked.single, '$baseUrl/forum.php?mod=modcp&action=home&tsdmapp=json&nodoc=1');
      expect(ok, isA<Right<AppException, ModcpAnswer<ModcpHome>>>());

      final login = await _repo(answer: (_) => _login()).fetchHome().run();
      expect(login, isA<Right<AppException, ModcpAnswer<ModcpHome>>>());
      expect((login as Right).value, isA<ModcpNeedsLogin<ModcpHome>>());
      expect(((login as Right).value as ModcpNeedsLogin).formHash, 'f1f2f3f4');

      final noAccess = await _repo(answer: (_) => _fixture('modcp_report_noaccess'), uid: () => 31).fetchHome().run();
      expect(((noAccess as Right).value as ModcpRefused).message, isNotEmpty);

      final guest = await _repo(answer: (_) => _fixture('modcp_report_guest')).fetchHome().run();
      expect((guest as Right).value, isA<ModcpRefused<ModcpHome>>());

      final other = await _repo(answer: (_) => _home(uid: 70)).fetchHome().run();
      expect(other, isA<Left<AppException, ModcpAnswer<ModcpHome>>>());
      expect((other as Left).value, isA<IdentityChangedException>());
    });

    test('a note added: done when a new one is listed, not told when none is', () async {
      final home = _read(_home(notes: [_note(3)]));
      final posted = <(String, Map<String, String>)>[];
      final done = await _repo(
        posted: posted,
        reply: _home(notes: [_note(5), _note(3)]),
      ).addNote(home, message: '交接', toSupermod: true, toModerator: true, days: 30).run();
      expect(posted.single.$1, '$baseUrl/forum.php?mod=modcp&action=home&tsdmapp=json');
      expect(posted.single.$2['newmessage'], '交接');
      expect(posted.single.$2['newaccess[3]'], '1');
      final value = (done as Right).value as ModcpPosted<ModcpHome>;
      expect(value.outcome, isA<ModcpWriteDone>());
      expect(value.page!.notes.length, 2);

      final unseen = await _repo(
        reply: _home(notes: [_note(3)]),
      ).addNote(home, message: '只给超版', toSupermod: true, toModerator: false, days: 30).run();
      expect(((unseen as Right).value as ModcpPosted<ModcpHome>).outcome, isA<ModcpWriteUnknown>());
    });

    test('an empty note, or no form, is never sent', () async {
      final posted = <(String, Map<String, String>)>[];
      final home = _read(_home());
      final empty = await _repo(
        posted: posted,
      ).addNote(home, message: '  ', toSupermod: true, toModerator: true, days: 30).run();
      expect(((empty as Right).value as ModcpPosted<ModcpHome>).outcome, isA<ModcpWriteRefused>());
      final noForm = await _repo(
        posted: posted,
      ).addNote(_read({..._home(), 'add': null}), message: 'x', toSupermod: true, toModerator: true, days: 1).run();
      expect(((noForm as Right).value as ModcpPosted<ModcpHome>).outcome, isA<ModcpWriteRefused>());
      expect(posted, isEmpty);
    });

    test('notes deleted: those still listed were not', () async {
      final home = _read(_home(notes: [_note(3), _note(4), _note(6)]));
      final posted = <(String, Map<String, String>)>[];
      final all = await _repo(
        posted: posted,
        reply: _home(notes: [_note(6)]),
      ).deleteNotes(home, [3, 4]).run();
      expect(posted.single.$2, containsPair('delete[1]', '4'));
      expect(((all as Right).value as ModcpPosted<ModcpHome>).outcome, isA<ModcpWriteDone>());
      final some = await _repo(reply: _home(notes: [_note(4), _note(6)])).deleteNotes(home, [3, 4]).run();
      final outcome = ((some as Right).value as ModcpPosted<ModcpHome>).outcome as ModcpWriteNotDone;
      expect(outcome.done, 1);
      expect(outcome.remaining, ['4']);
    });

    test("the panel's login, the forum's message, another account: nothing read as done", () async {
      final home = _read(_home(notes: [_note(3)]));
      final login = await _repo(reply: _login()).deleteNotes(home, [3]).run();
      expect(((login as Right).value as ModcpPosted<ModcpHome>).outcome, isA<ModcpWriteSessionEnded>());

      final message = await _repo(
        reply: {
          'ok': 1,
          'type': 'result',
          'schema': 13,
          'uid': 33,
          'kind': 'message',
          'message': '您的请求来路不正确或表单验证串不符，无法提交',
          'message_key': 'submit_invalid',
          'alert': 'error',
        },
      ).deleteNotes(home, [3]).run();
      final refused = ((message as Right).value as ModcpPosted<ModcpHome>).outcome as ModcpWriteRefused;
      expect(refused.message, contains('表单验证串不符'));

      final other = await _repo(reply: _home(uid: 70)).deleteNotes(home, [3]).run();
      expect((other as Left).value, isA<IdentityChangedException>());

      // The account changed since the page was served: nothing is sent.
      final posted = <(String, Map<String, String>)>[];
      final changed = await _repo(posted: posted, uid: () => 70).deleteNotes(home, [3]).run();
      expect((changed as Left).value, isA<IdentityChangedException>());
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
            home: ModcpNotesPage(repository: repo),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('a note left for both levels, then the list drawn again', (tester) async {
      final posted = <(String, Map<String, String>)>[];
      await pump(
        tester,
        _repo(
          posted: posted,
          reply: _home(notes: [_note(5)]),
        ),
      );
      expect(find.text('No notes'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('modcp-note-message')), '交接');
      await tester.enterText(find.byKey(const ValueKey('modcp-note-days')), '7');
      await tester.tap(find.byKey(const ValueKey('modcp-note-moderator')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('modcp-note-add')));
      await tester.pumpAndSettle();
      expect(posted.single.$2, {
        'formhash': 'f1f2f3f4',
        'op': 'addnote',
        'submit': 'true',
        'newmessage': '交接',
        'newaccess[2]': '1',
        'newexpiration': '7',
      });
      expect(find.text('Note added'), findsOneWidget);
      expect(find.byKey(const ValueKey('modcp-note-5')), findsOneWidget);
    });

    testWidgets('only the notes the account may delete are picked, deleted once confirmed', (tester) async {
      final posted = <(String, Map<String, String>)>[];
      await pump(
        tester,
        _repo(
          posted: posted,
          answer: (_) => _home(
            notes: [
              _note(3),
              _note(4, admin: 'ag_admin', canDelete: 0),
            ],
          ),
          reply: _home(notes: [_note(4, admin: 'ag_admin', canDelete: 0)]),
        ),
      );
      expect(
        find.descendant(of: find.byKey(const ValueKey('modcp-note-4')), matching: find.byType(Checkbox)),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('modcp-pick-all')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('modcp-notes-delete')));
      await tester.pumpAndSettle();
      expect(posted, isEmpty);
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(posted.single.$2, containsPair('delete[0]', '3'));
      expect(posted.single.$2.keys.where((k) => k.startsWith('delete[')), ['delete[0]']);
      expect(find.byKey(const ValueKey('modcp-note-3')), findsNothing);
    });

    testWidgets("the panel's password asked first", (tester) async {
      await pump(tester, _repo(answer: (_) => _login()));
      expect(find.byType(ModeratePanelLoginView), findsOneWidget);
    });
  });
}
