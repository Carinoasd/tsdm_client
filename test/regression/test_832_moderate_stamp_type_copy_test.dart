/// Thread management: stamp, icon, category, copy and repair from the thread page.
///
/// The fixtures under `test/data/moderate` are the test forum's answers to a moderator of forum 13 (Discuz! X5 with
/// plugin tsdmapp 3.6.0), scrubbed as the other fixtures there (account 31, thread 1234567, form hash `f1f2f3f4`):
///
/// * `window_stamp.json`: the window of `action=stamp` (`form#topicadminform`), the thread without a stamp;
///   `window_stamp_set.json` once stamped 热帖 (1); `window_stamp_ajax.xml` the AJAX fragment without the plugin;
/// * `window_stamplist.json`: the window of `action=stamplist`; `window_stamplist_set.json` once the icon is 热帖 (10):
///   the forum lists the icon first as 当前图标, then among the others;
/// * `window_stamp_nopermission.json` (and `_ajax.xml`): the answer to a moderator whose group may not stamp;
/// * `window_type.json`: the window of group 2 asked for `type`, the thread in category 3 of a forum requiring one;
///   `batch_window_type.json` the same for threads 1234567 and 1234568; `window_type_none.json` asked in forum 10,
///   which has no categories (the window without the operation); `result_type_invalid.json` the answer to `typeid` 0
///   there (`admin_type_invalid`);
/// * `window_copy.json`: the window of `action=copy` (every forum, the thread's own among them);
///   `thread_types_required.json` (and `_ajax.xml`) the categories of forum 13 for a copy (`getthreadtypes`, no 0:
///   one is required), `thread_types_none.json` those of a forum without categories; `result_copy_invalid.json` the
///   answer to a forum that does not exist (an untranslated language key);
/// * `result_repair.json` (and `_ajax.xml`, where the forum calls the error handler in its success box): the answer to
///   `action=repair`, which has no window; `result_repair_nopermission.json` to a group that may not repair,
///   `result_repair_nothread.json` to a thread not in the forum.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/moderate/models/moderate_form.dart';
import 'package:tsdm_client/features/moderate/repository/moderate_repository.dart';
import 'package:tsdm_client/features/moderate/widgets/moderate_sheet.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:universal_html/parsing.dart';

Translations get t => LocaleSettings.instance.currentTranslations;

const _dir = 'test/data/moderate';
const _tid = '1234567';
const _fid = 13;
const _uid = 31;

Object? _data(String name) {
  final text = File('$_dir/$name').readAsStringSync();
  return name.endsWith('.json') ? jsonDecode(text) : text;
}

Either<AppException, ModerateWindow> _windowOf(Object? data, ModerateOperation operation, {int fid = _fid}) =>
    ModerateRepository.windowOf(data, operation, tid: _tid, fid: fid, uid: _uid);

ModerateForm _window(Object? data, ModerateOperation operation) => switch (_windowOf(data, operation)) {
  Right(value: ModerateWindowReady(:final form)) => form,
  final other => throw StateError('no window: $other'),
};

/// A repository serving window [window] (the categories of forum N as [types] N gives them), answering every post
/// with [result]; the urls asked kept in [gets], the posts in [posts].
ModerateRepository _repo(
  Object? window, {
  List<String>? gets,
  List<(String, Map<String, String>)>? posts,
  String result = 'result_succeed.json',
  Map<int, String> types = const {},
}) => ModerateRepository(
  get: (url) async {
    gets?.add(url);
    final fid = RegExp(r'action=getthreadtypes&fid=(\d+)').firstMatch(url)?.group(1);
    if (fid != null) {
      return right((statusCode: 200, data: _data(types[int.parse(fid)] ?? 'thread_types_none.json')));
    }
    return right((statusCode: 200, data: window));
  },
  post: (url, body) async {
    posts?.add((url, body));
    return right((statusCode: 200, data: _data(result)));
  },
  currentUid: () => _uid,
);

Future<void> _open(WidgetTester tester, ModerateOperation operation, ModerateRepository repo) async {
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<bool>(
                context: context,
                builder: (_) => ModerateDialog(
                  operation: operation,
                  tid: _tid,
                  fid: _fid,
                  repository: repo,
                  imageBuilder: (url) => SizedBox(key: ValueKey(url)),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
  });

  group('window', () {
    test('asked as the thread page asks it', () {
      for (final op in [ModerateOperation.stamp, ModerateOperation.stamplist, ModerateOperation.copy]) {
        expect(op.group, 0);
        expect(op.action, op.name);
        expect(
          ModerateForm.windowUrl(op, tid: _tid, fid: _fid),
          '$baseUrl/forum.php?mod=topicadmin&action=${op.name}&fid=13&tid=1234567&handlekey=mods&infloat=yes'
          '&nopost=yes&inajax=1',
        );
      }
      expect(ModerateOperation.type.action, 'moderate');
      expect(
        ModerateForm.windowUrl(ModerateOperation.type, tid: _tid, fid: _fid),
        allOf(contains('action=moderate'), contains('optgroup=2'), contains('&operation=type')),
      );
      // Move is still asked as it was.
      expect(ModerateForm.windowUrl(ModerateOperation.move, tid: _tid, fid: _fid), isNot(contains('operation=')));
    });

    test('stamp: the stamps of the window, none first, with their pictures', () {
      final form = _window(_data('window_stamp.json'), ModerateOperation.stamp);
      expect(form.fields, {'formhash': 'f1f2f3f4', 'fid': '13', 'tid': _tid, 'handlekey': 'mods'});
      expect(form.choices.first, const ModerateChoice(value: '', label: '无图章'));
      expect(form.choices.map((e) => e.value), ['', '0', '1', '2', '3', '4', '5', '6', '7', '8', '19']);
      expect(form.choices[2].label, '热帖');
      expect(form.choices[2].image, '$baseUrl/static/image/stamp/002.gif');
      expect(form.choices.last.image, '$baseUrl/static/image/stamp/010.gif');
      expect(form.currentChoice, isNull);
      expect(form.reasons, contains('广告/SPAM'));
      expect(form.canNotify, isTrue);
      expect(
        form.submitUrl,
        '$baseUrl/forum.php?mod=topicadmin&action=stamp&modsubmit=yes&infloat=yes&modclick=yes&inajax=1',
      );

      expect(_window(_data('window_stamp_set.json'), ModerateOperation.stamp).currentChoice?.value, '1');
      final ajax = _window(_data('window_stamp_ajax.xml'), ModerateOperation.stamp);
      expect(ajax.choices, form.choices);
    });

    test('icon: the icon of the thread listed once, where it has its name', () {
      final none = _window(_data('window_stamplist.json'), ModerateOperation.stamplist);
      expect(none.choices.first.value, '');
      expect(none.choices.first.label, '无图标');
      expect(none.choices[2].image, '$baseUrl/static/image/stamp/002.small.gif');

      final set = _window(_data('window_stamplist_set.json'), ModerateOperation.stamplist);
      expect(set.choices.where((e) => e.value == '10'), [
        const ModerateChoice(
          value: '10',
          label: '热帖',
          selected: true,
          image: '$baseUrl/static/image/stamp/002.small.gif',
        ),
      ]);
      expect(set.choices.map((e) => e.label), isNot(contains('当前图标')));
      expect(set.choices.first.value, '');
      expect(set.currentChoice?.value, '10');
    });

    test('a window of another action, thread or forum is no window', () {
      expect(_windowOf(_data('window_stamp.json'), ModerateOperation.stamplist).isLeft(), isTrue);
      expect(_windowOf(_data('window_stamp.json'), ModerateOperation.copy).isLeft(), isTrue);
      expect(_windowOf(_data('window_copy.json'), ModerateOperation.stamp).isLeft(), isTrue);
      expect(_windowOf(_data('window_stamp.json'), ModerateOperation.stamp, fid: 10).isLeft(), isTrue);
      expect(
        ModerateRepository.windowOf(
          _data('window_stamp.json'),
          ModerateOperation.stamp,
          tid: '1',
          fid: _fid,
          uid: _uid,
        ).isLeft(),
        isTrue,
      );
      // The window of group 1 is no window of a stamp.
      expect(_windowOf(_data('window_highlight.json'), ModerateOperation.stamp).isLeft(), isTrue);
    });

    test("no permission: the forum's words, nothing to retry", () {
      expect(
        _windowOf(_data('window_stamp_nopermission.json'), ModerateOperation.stamp).getRight().toNullable(),
        isA<ModerateWindowRefused>()
            .having((e) => e.message, 'message', '抱歉，您没有权限给主题添加图章')
            .having((e) => e.unavailable, 'unavailable', isTrue),
      );
      expect(
        _windowOf(_data('window_stamp_nopermission_ajax.xml'), ModerateOperation.stamp).getRight().toNullable(),
        isA<ModerateWindowRefused>().having((e) => e.message, 'message', '抱歉，您没有权限给主题添加图章'),
      );
      // Not a moderator of the forum: may change, asked again.
      expect(
        (_windowOf(_data('window_nopermission.json'), ModerateOperation.stamp).getRight().toNullable()!
                as ModerateWindowRefused)
            .unavailable,
        isFalse,
      );
    });

    test('category: the categories of the forum, the thread in its own', () {
      final form = _window(_data('window_type.json'), ModerateOperation.type);
      expect(form.choices.map((e) => (e.value, e.label)), [('0', ''), ('3', '年度分享'), ('4', '版主公告'), ('5', '其他')]);
      expect(form.currentChoice?.value, '3');
      expect(form.fields['moderate[]'], _tid);
      expect(form.submitUrl, contains('optgroup=2&modsubmit=yes'));
      // The move window of the same group is no window of a category.
      expect(
        (_windowOf(_data('window_move.json'), ModerateOperation.type, fid: 10).getRight().toNullable()!
                as ModerateWindowRefused)
            .unavailable,
        isTrue,
      );
    });

    test('category where the forum has none: the window without the operation', () {
      expect(
        _windowOf(_data('window_type_none.json'), ModerateOperation.type, fid: 10).getRight().toNullable(),
        isA<ModerateWindowRefused>()
            .having((e) => e.unavailable, 'unavailable', isTrue)
            .having((e) => e.message, 'message', isEmpty),
      );
    });

    test('category of several threads: none selected', () {
      final batch =
          (ModerateRepository.batchWindowOf(
                    _data('batch_window_type.json'),
                    ModerateOperation.type,
                    tids: ['1234567', '1234568'],
                    fid: _fid,
                    uid: _uid,
                  ).getRight().toNullable()!
                  as ModerateBatchWindowReady)
              .form;
      expect(batch.tids, ['1234567', '1234568']);
      expect(batch.window.choices, hasLength(4));
      expect(batch.window.currentChoice, isNull);
      final body = batch.body(const ModerateRequest(operation: ModerateOperation.type, choice: '4'));
      expect(body['moderate[0]'], '1234567');
      expect(body['moderate[1]'], '1234568');
      expect(body['operations[]'], 'type');
      expect(body['typeid'], '4');
      // An action of its own is never a window of several threads.
      expect(
        ModerateForm.parseBatch(
          parseHtmlDocument((_data('window_stamp.json')! as Map<String, dynamic>)['document'] as String),
          ModerateOperation.stamp,
          tids: [_tid],
          fid: _fid,
        ),
        isNull,
      );
    });

    test('copy: every forum, the one of the thread among them', () {
      final form = _window(_data('window_copy.json'), ModerateOperation.copy);
      expect(form.forums.map((e) => e.value), containsAll(['2', '10', '13', '34']));
      expect(form.forums.firstWhere((e) => e.value == '13').label, 'COS・攝影');
      expect(form.forums.first.group, '🏠 論壇大廳');
      expect(form.choices, isEmpty);
      expect(form.submitUrl, contains('action=copy&modsubmit=yes'));
    });

    test('repair: no window asked, the url asked once is the repair', () async {
      final gets = <String>[];
      final answer = await _repo(null, gets: gets).fetchWindow(ModerateOperation.repair, tid: _tid, fid: _fid).run();
      expect(gets, isEmpty);
      final form = (answer.getRight().toNullable()! as ModerateWindowReady).form;
      expect(form.operation, ModerateOperation.repair);
      expect(form.uid, _uid);
      expect(
        form.submitUrl,
        '$baseUrl/forum.php?mod=topicadmin&action=repair&fid=13&tid=1234567&handlekey=mods&infloat=yes&nopost=yes'
        '&inajax=1',
      );
      expect(const ModerateRequest(operation: ModerateOperation.repair, reason: 'x', notify: true).body(form), isEmpty);
      // Never a window read for it.
      expect(_windowOf(_data('window_stamp.json'), ModerateOperation.repair).isLeft(), isTrue);
      // Logged out: nothing.
      final out = ModerateRepository(
        get: (url) async => right((statusCode: 200, data: null)),
        post: (url, body) async => right((statusCode: 200, data: null)),
        currentUid: () => 0,
      );
      expect(
        (await out.fetchWindow(ModerateOperation.repair, tid: _tid, fid: _fid).run()).getLeft().toNullable(),
        isA<IdentityChangedException>(),
      );
    });
  });

  group('request body', () {
    test('stamp and icon: none is sent empty', () {
      final stamp = _window(_data('window_stamp_set.json'), ModerateOperation.stamp);
      expect(const ModerateRequest(operation: ModerateOperation.stamp, choice: '19', reason: ' 好 ').body(stamp), {
        'formhash': 'f1f2f3f4',
        'fid': '13',
        'tid': _tid,
        'handlekey': 'mods',
        'stamp': '19',
        'reason': '好',
      });
      expect(const ModerateRequest(operation: ModerateOperation.stamp, choice: '').body(stamp)['stamp'], '');
      expect(const ModerateRequest(operation: ModerateOperation.stamp).body(stamp)['stamp'], '');
      final icon = _window(_data('window_stamplist.json'), ModerateOperation.stamplist);
      final body = const ModerateRequest(operation: ModerateOperation.stamplist, notify: true).body(icon);
      expect(body['stamplist'], '');
      expect(body['sendreasonpm'], 'on');
      expect(body.containsKey('operations[]'), isFalse);
    });

    test('category', () {
      final form = _window(_data('window_type.json'), ModerateOperation.type);
      expect(const ModerateRequest(operation: ModerateOperation.type, choice: '5').body(form), {
        ...form.fields,
        'operations[]': 'type',
        'typeid': '5',
        'reason': '',
      });
    });

    test('copy: the forum and its category, none when not chosen', () {
      final form = _window(_data('window_copy.json'), ModerateOperation.copy);
      expect(const ModerateRequest(operation: ModerateOperation.copy, moveTo: '13', threadType: '5').body(form), {
        ...form.fields,
        'copyto': '13',
        'threadtypeid': '5',
        'reason': '',
      });
      expect(const ModerateRequest(operation: ModerateOperation.copy, moveTo: '34').body(form)['threadtypeid'], '0');
    });
  });

  group('categories to copy to', () {
    test('required, without the plugin, none', () {
      List<ModerateChoice> types(String name) =>
          ModerateRepository.threadTypesOf(_data(name), uid: _uid).getRight().toNullable()!;
      expect(types('thread_types_required.json').map((e) => (e.value, e.label)), [
        ('3', '年度分享'),
        ('4', '版主公告'),
        ('5', '其他'),
      ]);
      expect(types('thread_types_required_ajax.xml'), types('thread_types_required.json'));
      expect(types('thread_types_none.json'), [const ModerateChoice(value: '0', label: '')]);
      expect(
        ModerateRepository.threadTypesOf(_data('thread_types_none.json'), uid: 32).getLeft().toNullable(),
        isA<IdentityChangedException>(),
      );
      expect(ModerateRepository.threadTypesOf(_data('result_succeed.json'), uid: _uid).isLeft(), isTrue);
    });
  });

  group('outcome', () {
    test('repair: its own success, with the plugin and without', () {
      expect(
        ModerateRepository.outcomeOf(_data('result_repair.json'), successKey: 'admin_repair_succeed'),
        isA<ModerateSucceeded>().having((e) => e.message, 'message', '主题修复成功'),
      );
      expect(ModerateRepository.outcomeOf(_data('result_repair.json')), isA<ModerateRefused>());
      expect(
        ModerateRepository.outcomeOf(
          _data('result_repair_ajax.xml'),
          successKey: 'admin_repair_succeed',
          successBox: true,
        ),
        isA<ModerateSucceeded>().having((e) => e.message, 'message', '主题修复成功'),
      );
      // The error handler is a refusal for any other request, and outside the success box.
      expect(ModerateRepository.outcomeOf(_data('result_repair_ajax.xml')), isA<ModerateRefused>());
      expect(
        ModerateRepository.outcomeOf(
          _data('window_stamp_nopermission_ajax.xml'),
          successKey: 'admin_repair_succeed',
          successBox: true,
        ),
        isA<ModerateRefused>().having((e) => e.message, 'message', '抱歉，您没有权限给主题添加图章'),
      );
      for (final (name, message) in [
        ('result_repair_nopermission.json', '抱歉，您没有权限修复此主题'),
        ('result_repair_nothread.json', '抱歉，您没有权限使用管理功能'),
      ]) {
        expect(
          ModerateRepository.outcomeOf(_data(name), successKey: 'admin_repair_succeed', successBox: true),
          isA<ModerateRefused>().having((e) => e.message, 'message', message),
        );
      }
    });

    test("category and copy refused: the forum's words", () {
      expect(
        ModerateRepository.outcomeOf(_data('result_type_invalid.json')),
        isA<ModerateRefused>().having((e) => e.message, 'message', '抱歉，目标分类无效'),
      );
      expect(
        ModerateRepository.outcomeOf(_data('result_copy_invalid.json')),
        isA<ModerateRefused>().having((e) => e.message, 'message', 'admin_copy_invalid'),
      );
    });
  });

  group('sheet', () {
    test('one thread: stamp and icon after recommend, category before move, copy and repair before delete', () {
      final ops = moderateOperationsFor(closed: false);
      expect(ops.indexOf(ModerateOperation.stamp), ops.indexOf(ModerateOperation.recommend) + 1);
      expect(ops.indexOf(ModerateOperation.stamplist), ops.indexOf(ModerateOperation.stamp) + 1);
      expect(ops.indexOf(ModerateOperation.type), ops.indexOf(ModerateOperation.move) - 1);
      expect(ops.sublist(ops.indexOf(ModerateOperation.move)), [
        ModerateOperation.move,
        ModerateOperation.copy,
        ModerateOperation.repair,
        ModerateOperation.delete,
      ]);
      expect(moderateBatchOperations, contains(ModerateOperation.type));
      for (final op in [
        ModerateOperation.stamp,
        ModerateOperation.stamplist,
        ModerateOperation.copy,
        ModerateOperation.repair,
      ]) {
        expect(moderateBatchOperations, isNot(contains(op)));
      }
      expect(moderateBatchOperations.last, ModerateOperation.delete);
    });

    testWidgets('stamp: the stamps with their pictures, the one picked sent once', (tester) async {
      final posts = <(String, Map<String, String>)>[];
      await _open(tester, ModerateOperation.stamp, _repo(_data('window_stamp.json'), posts: posts));
      expect(find.text(t.moderate.stamp), findsOneWidget);
      expect(find.byKey(const ValueKey('$baseUrl/static/image/stamp/002.gif')), findsOneWidget);
      // None, as the website's select, until another is picked.
      expect(tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '无图章')).selected, isTrue);
      await tester.tap(find.widgetWithText(ChoiceChip, '热帖'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, t.general.ok));
      await tester.pumpAndSettle();
      expect(posts, hasLength(1));
      expect(posts.single.$1, contains('action=stamp&modsubmit=yes'));
      expect(posts.single.$2, containsPair('stamp', '1'));
      expect(posts.single.$2, containsPair('tid', _tid));
      expect(find.byType(ModerateDialog), findsNothing);
    });

    testWidgets('stamp taken off: none sent empty', (tester) async {
      final posts = <(String, Map<String, String>)>[];
      await _open(tester, ModerateOperation.stamp, _repo(_data('window_stamp_set.json'), posts: posts));
      expect(tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '热帖')).selected, isTrue);
      await tester.tap(find.widgetWithText(ChoiceChip, '无图章'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, t.general.ok));
      await tester.pumpAndSettle();
      expect(posts.single.$2, containsPair('stamp', ''));
    });

    testWidgets("stamp without permission: the forum's words, nothing to retry or send", (tester) async {
      final posts = <(String, Map<String, String>)>[];
      await _open(tester, ModerateOperation.stamp, _repo(_data('window_stamp_nopermission.json'), posts: posts));
      expect(find.text('抱歉，您没有权限给主题添加图章'), findsOneWidget);
      expect(find.widgetWithText(TextButton, t.general.retry), findsNothing);
      expect(find.widgetWithText(TextButton, t.general.ok), findsNothing);
      expect(posts, isEmpty);
    });

    testWidgets('category: none named, the one picked sent', (tester) async {
      final posts = <(String, Map<String, String>)>[];
      await _open(tester, ModerateOperation.type, _repo(_data('window_type.json'), posts: posts));
      expect(find.widgetWithText(ChoiceChip, t.moderate.noType), findsOneWidget);
      expect(tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '年度分享')).selected, isTrue);
      await tester.tap(find.widgetWithText(ChoiceChip, '其他'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, t.general.ok));
      await tester.pumpAndSettle();
      expect(posts.single.$1, contains('optgroup=2&modsubmit=yes'));
      expect(posts.single.$2, containsPair('operations[]', 'type'));
      expect(posts.single.$2, containsPair('typeid', '5'));
    });

    testWidgets("category refused: the forum's words, the dialog stays", (tester) async {
      final posts = <(String, Map<String, String>)>[];
      await _open(
        tester,
        ModerateOperation.type,
        _repo(_data('window_type.json'), posts: posts, result: 'result_type_invalid.json'),
      );
      await tester.tap(find.widgetWithText(ChoiceChip, t.moderate.noType));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, t.general.ok));
      await tester.pumpAndSettle();
      expect(posts.single.$2, containsPair('typeid', '0'));
      expect(find.text('抱歉，目标分类无效'), findsOneWidget);
      expect(find.byType(ModerateDialog), findsOneWidget);
    });

    testWidgets('category where the forum has none: said so, nothing to send', (tester) async {
      final posts = <(String, Map<String, String>)>[];
      final repo = _repo(_data('window_type_none.json'), posts: posts);
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showDialog<bool>(
                    context: context,
                    builder: (_) =>
                        ModerateDialog(operation: ModerateOperation.type, tid: _tid, fid: 10, repository: repo),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text(t.moderate.unavailable), findsOneWidget);
      expect(find.widgetWithText(TextButton, t.general.ok), findsNothing);
      expect(posts, isEmpty);
    });

    testWidgets('copy: the categories of the forum picked, the first chosen', (tester) async {
      final gets = <String>[];
      final posts = <(String, Map<String, String>)>[];
      await _open(
        tester,
        ModerateOperation.copy,
        _repo(_data('window_copy.json'), gets: gets, posts: posts, types: {2: 'thread_types_required.json'}),
      );
      expect(find.text(t.moderate.copyTo), findsOneWidget);
      expect(find.text(t.moderate.threadType), findsNothing);
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('📢 公告 & 新手報到').last);
      await tester.pumpAndSettle();
      expect(gets.last, contains('action=getthreadtypes&fid=2'));
      expect(find.text(t.moderate.threadType), findsOneWidget);
      expect(find.text('年度分享'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, t.general.ok));
      await tester.pumpAndSettle();
      expect(posts.single.$1, contains('action=copy&modsubmit=yes'));
      expect(posts.single.$2, containsPair('copyto', '2'));
      expect(posts.single.$2, containsPair('threadtypeid', '3'));
    });

    testWidgets('copy to a forum without categories: none sent', (tester) async {
      final posts = <(String, Map<String, String>)>[];
      await _open(tester, ModerateOperation.copy, _repo(_data('window_copy.json'), posts: posts));
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('GLTEST 子版塊（型別 sub）').last);
      await tester.pumpAndSettle();
      expect(find.text(t.moderate.threadType), findsNothing);
      await tester.tap(find.widgetWithText(TextButton, t.general.ok));
      await tester.pumpAndSettle();
      expect(posts.single.$2, containsPair('copyto', '15'));
      expect(posts.single.$2, containsPair('threadtypeid', '0'));
    });

    testWidgets('repair: confirmed, asked once, nothing else', (tester) async {
      final gets = <String>[];
      final posts = <(String, Map<String, String>)>[];
      await _open(
        tester,
        ModerateOperation.repair,
        _repo(null, gets: gets, posts: posts, result: 'result_repair.json'),
      );
      expect(find.text(t.moderate.repair), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(find.byType(CheckboxListTile), findsNothing);
      await tester.tap(find.widgetWithText(TextButton, t.general.ok));
      await tester.pump();
      expect(gets, isEmpty);
      expect(posts, hasLength(1));
      expect(posts.single.$1, contains('action=repair&fid=13&tid=1234567'));
      expect(posts.single.$2, isEmpty);
      await tester.pumpAndSettle();
      // Closed on the forum's success only.
      expect(find.byType(ModerateDialog), findsNothing);
    });
  });
}
