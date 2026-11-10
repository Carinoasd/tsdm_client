/// Thread management: merge another thread into this one, split floors off as a new thread.
///
/// The fixtures under `test/data/moderate` are the test forum's answers to a moderator of forum 13 (Discuz! X5 with
/// plugin tsdmapp 3.7.0), scrubbed as the other fixtures there (account 31, thread 1234567, form hash `f1f2f3f4`):
///
/// * `window_merge.json` (and `_ajax.xml` without the plugin): the window of `action=merge` (`form#topicadminform`,
///   the text field `othertid`); `window_merge_nopermission.json` (and `_ajax.xml`) the answer to a moderator whose
///   group may not merge (`no_privilege_mergethread`); `window_merge_special.json` the answer for a special thread
///   (`special_noaction`);
/// * `window_split.json` (and `_ajax.xml`): the window of `action=split` (the title `subject`, the textarea `split`
///   of the floors' numbers joined by `,`); `window_split_noreply.json` the answer for a thread without replies
///   (`admin_split_invalid`), `window_split_nopermission.json` to a group that may not split;
/// * `result_merge.json`: the answer to a merge done (`admin_succeed`, sent on to the forum);
///   `result_merge_nothread.json` to a thread that does not exist, `result_merge_invalid.json` to the thread itself,
///   `result_merge_special.json` to a special thread;
/// * `result_split.json` (and `_ajax.xml`): the answer to a split done, naming no thread; `result_split_nosubject.json`
///   to a split without a title, `result_split_nofloor.json` to floors the thread does not have.
///
/// The thread pages the floors are picked from are built in the test from the app API's fields
/// ([threadPageFromApi]).
library;

import 'dart:async';
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
import 'package:tsdm_client/features/moderate/view/split_thread_page.dart';
import 'package:tsdm_client/features/moderate/widgets/moderate_sheet.dart';
import 'package:tsdm_client/features/thread/v1/utils/parse_thread_document.dart';
import 'package:tsdm_client/features/thread/v1/utils/thread_page_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';

Translations get t => LocaleSettings.instance.currentTranslations;

const _dir = 'test/data/moderate';
const _tid = '1234567';
const _fid = 13;
const _uid = 31;

Object? _data(String name) {
  final text = File('$_dir/$name').readAsStringSync();
  return name.endsWith('.json') ? jsonDecode(text) : text;
}

Either<AppException, ModerateWindow> _windowOf(Object? data, ModerateOperation operation) =>
    ModerateRepository.windowOf(data, operation, tid: _tid, fid: _fid, uid: _uid);

ModerateForm _window(Object? data, ModerateOperation operation) => switch (_windowOf(data, operation)) {
  Right(value: ModerateWindowReady(:final form)) => form,
  final other => throw StateError('no window: $other'),
};

/// Page [page] of [pages] of thread [tid] titled [subject], holding [floors] (number, pid, author, content), as the
/// app API answers it.
ThreadPageInfo _threadPage(
  List<(int, int, String, String)> floors, {
  String tid = _tid,
  String subject = '测试主题',
  int page = 1,
  int pages = 1,
}) => threadPageFromApi({
  'ok': 1,
  'api': 1,
  'uid': _uid,
  'formhash': 'f1f2f3f4',
  'type': 'thread',
  'schema': 13,
  'thread': {'tid': int.parse(tid), 'fid': _fid, 'subject': subject, 'replies': floors.length - 1},
  'forum': {'fid': _fid, 'name': '测试版块'},
  'page': page,
  'pages': pages,
  'ppp': 10,
  'posts': [
    for (final (floor, pid, author, message) in floors)
      {
        'pid': pid,
        'position': floor,
        'first': floor == 1 ? 1 : 0,
        'authorid': 40 + floor,
        'author': author,
        'dateline': 1700000000 + floor,
        'message': message,
        'body_html': '<div class="t_fsz">$message</div>',
      },
  ],
}, page);

/// The forum's message page of the app API for a thread it does not serve.
ThreadPageInfo _threadRefused(String message) =>
    threadPageFromApi({'ok': 0, 'error': 'message', 'message': message, 'login': 0, 'uid': _uid}, 1);

/// A repository serving window [window], the thread pages of [pages] by tid and page, answering every post with
/// [result]; the posts kept in [posts], the thread pages asked in [asked].
ModerateRepository _repo(
  Object? window, {
  List<(String, Map<String, String>)>? posts,
  String result = 'result_succeed.json',
  Future<Either<AppException, ThreadPageInfo>> Function(String tid, int page)? pages,
  List<(String, int)>? asked,
  int Function()? currentUid,
}) => ModerateRepository(
  get: (url) async => right((statusCode: 200, data: window)),
  post: (url, body) async {
    posts?.add((url, body));
    return right((statusCode: 200, data: _data(result)));
  },
  threadPage: (tid, page) async {
    asked?.add((tid, page));
    if (pages == null) {
      return left(HttpRequestFailedException(null));
    }
    return pages(tid, page);
  },
  currentUid: currentUid ?? () => _uid,
);

Widget _app(void Function(BuildContext context) open) => TranslationProvider(
  child: MaterialApp(
    scaffoldMessengerKey: snackbarKey,
    home: Builder(
      builder: (context) => Scaffold(
        body: TextButton(onPressed: () => open(context), child: const Text('open')),
      ),
    ),
  ),
);

Future<void> _openDialog(WidgetTester tester, ModerateOperation operation, ModerateRepository repo) async {
  await tester.pumpWidget(
    _app(
      (context) => showDialog<bool>(
        context: context,
        builder: (_) => ModerateDialog(operation: operation, tid: _tid, fid: _fid, repository: repo),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

/// The floors of a thread of two pages: 1 to 3, then 4 and 5.
Future<Either<AppException, ThreadPageInfo>> _twoPages(String tid, int page) async => right(
  page == 1
      ? _threadPage(
          [(1, 101, '甲', '首楼[b]内容[/b]'), (2, 102, '乙', '第二楼'), (3, 103, '丙', '第三楼')],
          pages: 2,
        )
      : _threadPage([(4, 104, '丁', '第四楼'), (5, 105, '戊', '第五楼')], page: 2, pages: 2),
);

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
  });

  group('window', () {
    test('asked as the thread page asks it, an action of its own', () {
      for (final op in [ModerateOperation.merge, ModerateOperation.split]) {
        expect(op.group, 0);
        expect(op.action, op.name);
        expect(
          ModerateForm.windowUrl(op, tid: _tid, fid: _fid),
          '$baseUrl/forum.php?mod=topicadmin&action=${op.name}&fid=13&tid=1234567&handlekey=mods&infloat=yes'
          '&nopost=yes&inajax=1',
        );
      }
    });

    test('merge: the window of the thread, with and without the plugin', () {
      final form = _window(_data('window_merge.json'), ModerateOperation.merge);
      expect(form.operation, ModerateOperation.merge);
      expect(form.fields, {'formhash': 'f1f2f3f4', 'fid': '13', 'tid': _tid, 'handlekey': 'mods'});
      expect(form.reasons, contains('广告/SPAM'));
      expect(form.canNotify, isTrue);
      expect(form.notifyForced, isFalse);
      expect(
        form.submitUrl,
        '$baseUrl/forum.php?mod=topicadmin&action=merge&modsubmit=yes&infloat=yes&modclick=yes&inajax=1',
      );
      final ajax = _window(_data('window_merge_ajax.xml'), ModerateOperation.merge);
      expect(ajax.fields, form.fields);
      expect(ajax.reasons, form.reasons);
    });

    test('split: the window of the thread, with and without the plugin', () {
      final form = _window(_data('window_split.json'), ModerateOperation.split);
      expect(form.operation, ModerateOperation.split);
      expect(form.fields, {'formhash': 'f1f2f3f4', 'fid': '13', 'tid': _tid, 'handlekey': 'mods'});
      expect(form.canNotify, isTrue);
      expect(form.submitUrl, contains('action=split&modsubmit=yes'));
      expect(_window(_data('window_split_ajax.xml'), ModerateOperation.split).fields, form.fields);
    });

    test('the window of the other action, or of another thread, is no window', () {
      expect(_windowOf(_data('window_merge.json'), ModerateOperation.split).isLeft(), isTrue);
      expect(_windowOf(_data('window_split.json'), ModerateOperation.merge).isLeft(), isTrue);
      expect(_windowOf(_data('window_split.json'), ModerateOperation.copy).isLeft(), isTrue);
      expect(
        ModerateRepository.windowOf(
          _data('window_merge.json'),
          ModerateOperation.merge,
          tid: '7654321',
          fid: _fid,
          uid: _uid,
        ).isLeft(),
        isTrue,
      );
      // Served to another account.
      expect(
        ModerateRepository.windowOf(
          _data('window_merge.json'),
          ModerateOperation.merge,
          tid: _tid,
          fid: _fid,
          uid: 32,
        ).getLeft().toNullable(),
        isA<IdentityChangedException>(),
      );
    });

    test("refused for good in the forum's words: no permission, a special thread, a thread without replies", () {
      for (final (name, op, words) in [
        ('window_merge_nopermission.json', ModerateOperation.merge, '抱歉，您没有权限合并主题'),
        ('window_split_nopermission.json', ModerateOperation.split, '抱歉，您没有权限分割此主题'),
        ('window_merge_special.json', ModerateOperation.merge, '无法操作特殊主题'),
        ('window_split_noreply.json', ModerateOperation.split, '抱歉，主题没有回复，无法分割'),
      ]) {
        final answer = _windowOf(_data(name), op).toNullable();
        expect(answer, isA<ModerateWindowRefused>(), reason: name);
        final refused = answer! as ModerateWindowRefused;
        expect(refused.message, words, reason: name);
        expect(refused.unavailable, isTrue, reason: name);
      }
      // Without the plugin the refusal has no language key: offered to ask again, as before.
      final ajax = _windowOf(_data('window_merge_nopermission_ajax.xml'), ModerateOperation.merge).toNullable();
      expect(ajax, isA<ModerateWindowRefused>());
      expect((ajax! as ModerateWindowRefused).message, '抱歉，您没有权限合并主题');
      expect((ajax as ModerateWindowRefused).unavailable, isFalse);
    });
  });

  group('request', () {
    test('merge: the thread to merge, the reason and the notice', () {
      final form = _window(_data('window_merge.json'), ModerateOperation.merge);
      expect(
        const ModerateRequest(
          operation: ModerateOperation.merge,
          otherTid: '7654321',
          reason: ' 重复 ',
          notify: true,
        ).body(
          form,
        ),
        {
          'formhash': 'f1f2f3f4',
          'fid': '13',
          'tid': _tid,
          'handlekey': 'mods',
          'othertid': '7654321',
          'reason': '重复',
          'sendreasonpm': 'on',
        },
      );
    });

    test('split: the title, and the floors in order, each once', () {
      final form = _window(_data('window_split.json'), ModerateOperation.split);
      final body = const ModerateRequest(
        operation: ModerateOperation.split,
        subject: ' 新的主题 ',
        floors: [5, 3, 5],
      ).body(form);
      expect(body, containsPair('subject', '新的主题'));
      expect(body, containsPair('split', '3,5'));
      expect(body, containsPair('tid', _tid));
      expect(body, isNot(contains('operations[]')));
      expect(body, isNot(contains('sendreasonpm')));
    });

    test("the forum's verdict: done, or refused in its words", () {
      expect(ModerateRepository.outcomeOf(_data('result_merge.json')), isA<ModerateSucceeded>());
      expect(
        (ModerateRepository.outcomeOf(_data('result_split.json')) as ModerateSucceeded).message,
        '管理操作成功',
      );
      expect(
        (ModerateRepository.outcomeOf(_data('result_split_ajax.xml')) as ModerateSucceeded).message,
        '管理操作成功',
      );
      for (final (name, words) in [
        ('result_merge_nothread.json', '抱歉，主题 ID (tid) 不存在'),
        ('result_merge_invalid.json', '抱歉，请选择其他主题进行合并'),
        ('result_merge_special.json', '无法操作特殊主题'),
        ('result_split_nosubject.json', '抱歉，您尚未输入标题'),
        ('result_split_nofloor.json', '抱歉，您尚未选择要分割入新主题的帖子'),
      ]) {
        final outcome = ModerateRepository.outcomeOf(_data(name));
        expect(outcome, isA<ModerateRefused>(), reason: name);
        expect((outcome as ModerateRefused).message, words, reason: name);
      }
    });

    test('the thread to merge: an id, or a link to a thread of the forum', () {
      expect(moderateMergeTidOf('7654321'), '7654321');
      expect(moderateMergeTidOf(' 7654321 '), '7654321');
      expect(moderateMergeTidOf('007654321'), '7654321');
      expect(moderateMergeTidOf('0'), isNull);
      expect(moderateMergeTidOf(''), isNull);
      expect(moderateMergeTidOf('abc'), isNull);
      expect(moderateMergeTidOf('$baseUrl/forum.php?mod=viewthread&tid=7654321&page=2'), '7654321');
      expect(moderateMergeTidOf('$baseUrl/thread-7654321-3-1.html'), '7654321');
      expect(moderateMergeTidOf('$baseUrl/forum.php?mod=redirect&goto=findpost&ptid=7654321&pid=9'), '7654321');
      expect(moderateMergeTidOf('https://example.com/forum.php?mod=viewthread&tid=7654321'), isNull);
      expect(moderateMergeTidOf('$baseUrl/forum.php?mod=forumdisplay&fid=13'), isNull);
    });

    test('the thread page is read for the account that asked', () async {
      var uid = _uid;
      final repo = _repo(
        null,
        currentUid: () => uid,
        pages: (tid, page) async {
          uid = 32;
          return right(_threadPage([(1, 101, '甲', '首楼')]));
        },
      );
      expect((await repo.fetchThreadPage(_tid).run()).getLeft().toNullable(), isA<IdentityChangedException>());
      uid = 0;
      expect((await repo.fetchThreadPage(_tid).run()).getLeft().toNullable(), isA<IdentityChangedException>());
    });

    test('the floor shown without its markup', () {
      final page = _threadPage([(1, 101, '甲', '首楼[b]加粗[/b]\n[url=https://forum.test]链接[/url]  文字')]);
      expect(splitFloorExcerpt(page.postList.single), '首楼 加粗 链接 文字');
    });
  });

  group('menu', () {
    test('offered on one thread, after copy, before repair; never on several', () {
      final ops = moderateOperationsFor(closed: false);
      final copy = ops.indexOf(ModerateOperation.copy);
      expect(ops.sublist(copy, copy + 4), [
        ModerateOperation.copy,
        ModerateOperation.merge,
        ModerateOperation.split,
        ModerateOperation.repair,
      ]);
      expect(moderateBatchOperations, isNot(contains(ModerateOperation.merge)));
      expect(moderateBatchOperations, isNot(contains(ModerateOperation.split)));
    });
  });

  group('merge dialog', () {
    testWidgets('the thread typed is looked up, its title shown, then merged once', (tester) async {
      final posts = <(String, Map<String, String>)>[];
      final asked = <(String, int)>[];
      final repo = _repo(
        _data('window_merge.json'),
        posts: posts,
        asked: asked,
        result: 'result_merge.json',
        pages: (tid, page) async => right(_threadPage([(1, 201, '乙', '另一帖')], tid: tid, subject: '要合并的主题')),
      );
      await _openDialog(tester, ModerateOperation.merge, repo);
      expect(find.text(t.moderate.merge), findsOneWidget);
      final ok = find.widgetWithText(TextButton, t.general.ok);
      expect(tester.widget<TextButton>(ok).onPressed, isNull);

      await tester.enterText(find.byType(TextField).first, '$baseUrl/thread-7654321-1-1.html');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(asked, [('7654321', 1)]);
      expect(find.text('要合并的主题'), findsOneWidget);
      expect(find.text('乙 · 测试版块'), findsOneWidget);
      expect(tester.widget<TextButton>(ok).onPressed, isNotNull);

      await tester.tap(ok);
      await tester.pumpAndSettle();
      expect(posts, hasLength(1));
      expect(posts.single.$1, contains('action=merge&modsubmit=yes'));
      expect(posts.single.$2, containsPair('othertid', '7654321'));
      expect(posts.single.$2, containsPair('tid', _tid));
      expect(find.byType(ModerateDialog), findsNothing);
    });

    testWidgets('an earlier lookup answering late is dropped', (tester) async {
      final slow = Completer<Either<AppException, ThreadPageInfo>>();
      final repo = _repo(
        _data('window_merge.json'),
        pages: (tid, page) => tid == '111'
            ? slow.future
            : Future.value(right(_threadPage([(1, 201, '乙', '另一帖')], tid: tid, subject: '后来的主题'))),
      );
      await _openDialog(tester, ModerateOperation.merge, repo);
      await tester.enterText(find.byType(TextField).first, '111');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.enterText(find.byType(TextField).first, '222');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(find.text('后来的主题'), findsOneWidget);
      slow.complete(right(_threadPage([(1, 301, '丙', '先前的')], tid: '111', subject: '先前的主题')));
      await tester.pumpAndSettle();
      expect(find.text('先前的主题'), findsNothing);
      expect(find.text('后来的主题'), findsOneWidget);
    });

    testWidgets('a thread the forum does not serve: its words, nothing to send', (tester) async {
      final posts = <(String, Map<String, String>)>[];
      final repo = _repo(
        _data('window_merge.json'),
        posts: posts,
        pages: (tid, page) async => right(_threadRefused('没有找到帖子')),
      );
      await _openDialog(tester, ModerateOperation.merge, repo);
      await tester.enterText(find.byType(TextField).first, '7654321');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(find.text('没有找到帖子'), findsOneWidget);
      expect(tester.widget<TextButton>(find.widgetWithText(TextButton, t.general.ok)).onPressed, isNull);
      expect(posts, isEmpty);
    });

    testWidgets('refused by the forum: its words, the dialog stays', (tester) async {
      final posts = <(String, Map<String, String>)>[];
      final repo = _repo(
        _data('window_merge.json'),
        posts: posts,
        result: 'result_merge_special.json',
        pages: (tid, page) async => right(_threadPage([(1, 201, '乙', '投票')], tid: tid, subject: '投票主题')),
      );
      await _openDialog(tester, ModerateOperation.merge, repo);
      await tester.enterText(find.byType(TextField).first, '7654321');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, t.general.ok));
      await tester.pumpAndSettle();
      expect(posts, hasLength(1));
      expect(find.text('无法操作特殊主题'), findsOneWidget);
      expect(find.byType(ModerateDialog), findsOneWidget);
    });

    testWidgets("a group that may not merge: the forum's words, nothing to retry or send", (tester) async {
      await _openDialog(tester, ModerateOperation.merge, _repo(_data('window_merge_nopermission.json')));
      expect(find.text('抱歉，您没有权限合并主题'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(find.widgetWithText(TextButton, t.general.retry), findsNothing);
      expect(find.widgetWithText(TextButton, t.general.ok), findsNothing);
    });
  });

  group('split page', () {
    Future<void> open(WidgetTester tester, ModerateRepository repo) async {
      await tester.pumpWidget(
        _app((context) => openSplitThreadPage(context, tid: _tid, fid: _fid, repository: repo)),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('the floors of every page picked by number, the title given, split once', (tester) async {
      final posts = <(String, Map<String, String>)>[];
      final asked = <(String, int)>[];
      ModerateSplitDone? done;
      final repo = _repo(
        _data('window_split.json'),
        posts: posts,
        asked: asked,
        result: 'result_split.json',
        pages: _twoPages,
      );
      await tester.pumpWidget(
        _app((context) async {
          done = await openSplitThreadPage(context, tid: _tid, fid: _fid, repository: repo);
        }),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byType(SplitThreadPage), findsOneWidget);
      // The page after the first is loaded once the list reaches its end.
      expect(asked, [(_tid, 1), (_tid, 2)]);
      expect(find.byType(CheckboxListTile), findsNWidgets(5));
      expect(find.text('首楼 内容'), findsOneWidget);
      expect(find.text('#5'), findsOneWidget);
      final ok = find.widgetWithText(TextButton, t.general.ok);
      expect(tester.widget<TextButton>(ok).onPressed, isNull);

      await tester.tap(find.widgetWithText(CheckboxListTile, '戊'));
      await tester.tap(find.widgetWithText(CheckboxListTile, '丙'));
      await tester.pumpAndSettle();
      expect(find.text('${t.moderate.split} (2)'), findsOneWidget);
      await tester.tap(ok);
      await tester.pumpAndSettle();
      expect(find.text('#3  #5'), findsOneWidget);
      final send = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(TextButton, t.general.ok),
      );
      // No title, nothing to send.
      expect(tester.widget<TextButton>(send).onPressed, isNull);
      await tester.enterText(find.widgetWithText(TextField, t.moderate.splitSubject), ' 新主题 ');
      await tester.pumpAndSettle();
      await tester.tap(send);
      await tester.pumpAndSettle();

      expect(posts, hasLength(1));
      expect(posts.single.$1, contains('action=split&modsubmit=yes'));
      expect(posts.single.$2, containsPair('split', '3,5'));
      expect(posts.single.$2, containsPair('subject', '新主题'));
      expect(find.byType(SplitThreadPage), findsNothing);
      // The new thread is opened by its earliest floor.
      expect(done, (subject: '新主题', pid: '103', message: '管理操作成功'));
    });

    testWidgets('every floor picked: not sent, the thread would be left without a floor', (tester) async {
      final repo = _repo(_data('window_split.json'), pages: _twoPages);
      await open(tester, repo);
      for (final name in ['甲', '乙', '丙', '丁', '戊']) {
        await tester.tap(find.widgetWithText(CheckboxListTile, name));
      }
      await tester.pumpAndSettle();
      final ok = find.widgetWithText(TextButton, t.general.ok);
      expect(tester.widget<TextButton>(ok).onPressed, isNull);
      // The first floor may go: one floor is left.
      await tester.tap(find.widgetWithText(CheckboxListTile, '乙'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextButton>(ok).onPressed, isNotNull);
    });

    testWidgets('refused by the forum: its words, the title kept', (tester) async {
      final posts = <(String, Map<String, String>)>[];
      final repo = _repo(
        _data('window_split.json'),
        posts: posts,
        result: 'result_split_nofloor.json',
        pages: _twoPages,
      );
      await open(tester, repo);
      await tester.tap(find.widgetWithText(CheckboxListTile, '乙'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, t.general.ok));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, t.moderate.splitSubject), '新主题');
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(of: find.byType(AlertDialog), matching: find.widgetWithText(TextButton, t.general.ok)),
      );
      await tester.pumpAndSettle();
      expect(posts, hasLength(1));
      expect(find.text('抱歉，您尚未选择要分割入新主题的帖子'), findsOneWidget);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.byType(SplitThreadPage), findsOneWidget);
    });

    testWidgets("a thread without replies: the forum's words, no floor asked, nothing to retry", (tester) async {
      final asked = <(String, int)>[];
      await open(tester, _repo(_data('window_split_noreply.json'), asked: asked, pages: _twoPages));
      expect(find.text('抱歉，主题没有回复，无法分割'), findsOneWidget);
      expect(find.byType(CheckboxListTile), findsNothing);
      expect(find.widgetWithText(TextButton, t.general.retry), findsNothing);
      expect(asked, isEmpty);
    });

    testWidgets('from the thread menu: changed, the new thread offered to open', (tester) async {
      final repo = _repo(_data('window_split.json'), result: 'result_split.json', pages: _twoPages);
      ModerateDone? done;
      await tester.pumpWidget(
        _app((context) async {
          done = await showThreadModerateSheet(context, tid: _tid, fid: _fid, closed: false, repository: repo);
        }),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text(t.moderate.split), 100, scrollable: find.byType(Scrollable).last);
      await tester.tap(find.text(t.moderate.split));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(CheckboxListTile, '乙'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, t.general.ok));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, t.moderate.splitSubject), '新主题');
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(of: find.byType(AlertDialog), matching: find.widgetWithText(TextButton, t.general.ok)),
      );
      await tester.pumpAndSettle();
      expect(done, ModerateDone.changed);
      expect(find.widgetWithText(SnackBarAction, t.moderate.openNewThread), findsOneWidget);
    });
  });
}
