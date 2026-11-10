/// Floor operations of a moderator, second part: a reply stuck under the first floor, rates taken back, an attachment
/// deleted from the edit page, and another member's floor edited.
///
/// The fixtures `test/data/moderate/floor_stick_*`, `removerate_*`, `deleteattach_*`, `edit_attach_moderator.json`,
/// `thread_stuck*` and `thread_moderator_edit_api.json` are the test forum's answers (Discuz! X5 with plugin tsdmapp
/// 3.7.0), scrubbed: the window `forum.php?mod=topicadmin&action=stickreply&topiclist[]=PID` asked by an administrator
/// with `tsdmapp=json` and, with `undo=1`, as the AJAX fragment; its refusal to a super moderator whose group may not
/// stick replies; its results. The window `forum.php?mod=misc&action=removerate` of a floor rated twice asked by a
/// super moderator (JSON and AJAX), its refusal to a member, its results. The answers of
/// `forum.php?mod=ajax&action=deleteattach` to a moderator of the forum (one deleted) and to a moderator of another
/// forum (none). The edit form a super moderator was served for a member's floor with two attachments. The thread page
/// (JSON, cut to its floors; the web page, cut to the first floor and the stuck reply) with the fourth floor stuck,
/// and as a super moderator saw it once he edited a member's floor.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/moderate/models/moderate_form.dart';
import 'package:tsdm_client/features/moderate/models/moderate_posts.dart';
import 'package:tsdm_client/features/moderate/models/remove_rate.dart';
import 'package:tsdm_client/features/moderate/repository/floor_ops_repository.dart';
import 'package:tsdm_client/features/moderate/repository/moderate_repository.dart';
import 'package:tsdm_client/features/moderate/widgets/floor_moderate_dialog.dart';
import 'package:tsdm_client/features/moderate/widgets/remove_rate_dialog.dart';
import 'package:tsdm_client/features/post/models/post_form.dart';
import 'package:tsdm_client/features/post/utils/edit_attachments.dart';
import 'package:tsdm_client/features/post/widgets/edit_attachments_button.dart';
import 'package:tsdm_client/features/thread/v1/utils/thread_page_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:universal_html/parsing.dart';

const _dir = 'test/data/moderate';
const _tid = '1234567';
const _pid = '7654321';
const _fid = 10;

/// The administrator the stick window was served to.
const _admin = 30;

/// The super moderator of the other answers.
const _moderator = 31;

String _text(String name) => File('$_dir/$name').readAsStringSync();

Object? _data(String name) {
  final text = _text(name);
  return name.endsWith('.json') ? jsonDecode(text) : text;
}

ModerateResponse _ok(Object? data) => (statusCode: 200, data: data);

Either<AppException, FloorModerateWindow> _stickWindowOf(String name, {int uid = _admin}) =>
    ModerateRepository.floorWindowOf(_data(name), FloorModerateAction.stick, tid: _tid, fid: _fid, pid: _pid, uid: uid);

FloorModerateForm _stickWindow(String name) => switch (_stickWindowOf(name)) {
  Right(value: FloorModerateWindowReady(:final form)) => form,
  final other => throw StateError('no window: $other'),
};

Either<AppException, RemoveRateWindow> _rateWindowOf(String name, {int uid = _moderator}) =>
    FloorOpsRepository.removeRateWindowOf(_data(name), tid: _tid, pid: _pid, uid: uid);

RemoveRateForm _rateWindow(String name) => switch (_rateWindowOf(name)) {
  Right(value: RemoveRateWindowReady(:final form)) => form,
  final other => throw StateError('no window: $other'),
};

Post _webFloor(String name, String pid) =>
    Post.fromPostNode(parseHtmlDocument(_text(name)).querySelector('div#post_$pid')!, 1)!;

Widget _app(Future<void> Function(BuildContext context) open) => TranslationProvider(
  child: MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: TextButton(onPressed: () async => open(context), child: const Text('open')),
      ),
    ),
  ),
);

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
  });

  group('stick a reply', () {
    test('the window: its served fields; sticking checked unless asked to undo, and the moderator chooses', () {
      final form = _stickWindow('floor_stick_window.json');
      expect(form.uid, _admin);
      expect(form.fields, {
        'formhash': 'f1f2f3f4',
        'fid': '10',
        'tid': _tid,
        'handlekey': 'mods',
        'topiclist[]': _pid,
      });
      expect(form.undo, isFalse);
      expect(form.reasons, contains('广告/SPAM'));
      expect(form.canNotify, isTrue);
      expect(form.body(reason: ' 精品 ')['stickreply'], '1');
      expect(form.body(reason: ' 精品 ')['reason'], '精品');
      expect(form.choosing(undo: true).body()['stickreply'], '0');

      final undo = _stickWindow('floor_stick_window_undo_ajax.xml');
      expect(undo.undo, isTrue);
      expect(undo.body()['stickreply'], '0');
      expect(undo.choosing(undo: false).body()['stickreply'], '1');
    });

    test('only a choosable action is asked with undo', () {
      expect(
        FloorModerateForm.windowUrl(FloorModerateAction.stick, tid: _tid, fid: _fid, pid: _pid, undo: true),
        endsWith(
          'action=stickreply&fid=10&tid=$_tid&topiclist%5B%5D=$_pid&handlekey=mods&infloat=yes&nopost=yes'
          '&undo=1&inajax=1',
        ),
      );
      expect(
        FloorModerateForm.windowUrl(FloorModerateAction.stick, tid: _tid, fid: _fid, pid: _pid),
        isNot(contains('undo')),
      );
      expect(
        FloorModerateForm.windowUrl(FloorModerateAction.ban, tid: _tid, fid: _fid, pid: _pid, undo: true),
        isNot(contains('undo')),
      );
      // The choice of another action is the window's.
      const ban = FloorModerateForm(
        action: FloorModerateAction.ban,
        tid: _tid,
        fid: _fid,
        pid: _pid,
        fields: {'formhash': 'f1f2f3f4'},
        undo: true,
      );
      expect(ban.choosing(undo: false).body()['banned'], '0');
    });

    test("a group that may not stick replies: the forum's words, as JSON and as AJAX", () {
      for (final name in ['floor_stick_nopermission.json', 'floor_stick_nopermission_ajax.xml']) {
        expect(
          _stickWindowOf(name, uid: _moderator),
          isA<Right<AppException, FloorModerateWindow>>().having(
            (e) => (e.value as FloorModerateWindowRefused).message,
            'message',
            '抱歉，您没有权限置顶此帖',
          ),
          reason: name,
        );
      }
    });

    test('the results: admin_succeed, as JSON and as AJAX', () {
      expect(ModerateRepository.outcomeOf(_data('floor_stick_result.json')), isA<ModerateSucceeded>());
      expect(
        (ModerateRepository.outcomeOf(_data('floor_stick_result_ajax.xml')) as ModerateSucceeded).message,
        '管理操作成功',
      );
    });

    test('offered on replies, before the deletion; never on the first floor', () {
      expect(floorModerateActionsFor(first: false), [
        FloorModerateAction.warn,
        FloorModerateAction.ban,
        FloorModerateAction.stick,
        FloorModerateAction.delete,
      ]);
      expect(floorModerateActionsFor(first: true), isNot(contains(FloorModerateAction.stick)));
    });

    test('repository: the window asked with undo, the choice posted once', () async {
      final gets = <String>[];
      final posts = <Map<String, String>>[];
      final repo = ModerateRepository(
        get: (url) async {
          gets.add(url);
          return right(_ok(_data('floor_stick_window_undo_ajax.xml')));
        },
        post: (url, body) async {
          posts.add(body);
          return right(_ok(_data('floor_stick_result.json')));
        },
        currentUid: () => _admin,
      );
      final window = await repo
          .fetchFloorWindow(FloorModerateAction.stick, tid: _tid, fid: _fid, pid: _pid, undo: true)
          .run();
      expect(gets.single, contains('&undo=1'));
      expect(gets.single, contains('tsdmapp=json'));
      final form = (window.getRight().toNullable()! as FloorModerateWindowReady).form;
      expect(form.undo, isTrue);
      final outcome = await repo.submitFloor(form.choosing(undo: false)).run();
      expect(outcome.getRight().toNullable(), isA<ModerateSucceeded>());
      expect(posts.single['stickreply'], '1');
    });
  });

  testWidgets('the stick dialog: unsticking chosen as asked, the moderator may choose sticking', (tester) async {
    final posts = <Map<String, String>>[];
    final repo = ModerateRepository(
      get: (_) async => right(_ok(_data('floor_stick_window_undo_ajax.xml'))),
      post: (_, body) async {
        posts.add(body);
        return right(_ok(_data('floor_stick_result.json')));
      },
      currentUid: () => _admin,
    );
    bool? done;
    await tester.pumpWidget(
      _app(
        (context) async => done = await showFloorModerateDialog(
          context,
          action: FloorModerateAction.stick,
          tid: _tid,
          fid: _fid,
          pid: _pid,
          undo: true,
          repository: repo,
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final choice = tester.widget<SegmentedButton<bool>>(find.byType(SegmentedButton<bool>));
    expect(choice.selected, {true});
    await tester.tap(
      find.descendant(of: find.byType(SegmentedButton<bool>), matching: find.text(t.moderateFloorOps.stick)),
    );
    await tester.pump();
    await tester.tap(find.text(t.general.ok));
    await tester.pumpAndSettle();
    expect(posts.single['stickreply'], '1');
    expect(done, isTrue);
  });

  group('a stuck reply on the thread page', () {
    test('the web page: 置顶回复 in the floor number, its floor after it', () {
      final stuck = _webFloor('thread_stuck.html', _pid);
      expect(stuck.stuck, isTrue);
      expect(stuck.postFloor, 4);
      final first = _webFloor('thread_stuck.html', '7654320');
      expect(first.stuck, isFalse);
      // 楼主 in place of the number: the menu tells the first floor by its link, the thread's.
      expect(first.postFloor, isNull);
      expect(first.shareLink, contains('mod=viewthread&tid=$_tid'));
      expect(stuck.shareLink, contains('goto=findpost'));
    });

    test('another page is never marked', () {
      final json = _data('thread_stuck_api.json')! as Map<String, dynamic>;
      final posts = threadPageFromApi({...json, 'page': 2}, 2).postList;
      expect(posts.where((e) => e.stuck), isEmpty);
    });

    test('the app API: told by the order of the first page', () {
      final posts = threadPageFromApi(_data('thread_stuck_api.json')! as Map<String, dynamic>, 1).postList;
      expect(
        [for (final p in posts) (p.postID, p.postFloor, p.stuck)],
        [
          ('7654320', 1, false),
          (_pid, 4, true),
          ('7654322', 2, false),
          ('7654323', 3, false),
        ],
      );
    });

    test('the order: floors before a floor they come after, either way; never the first floor or a hot reply', () {
      final base = threadPageFromApi(_data('thread_stuck_api.json')! as Map<String, dynamic>, 1).postList.first;
      Post floor(int n, {bool hot = false}) => base.copyWith(postID: 'p$n', postFloor: n, hot: hot);
      List<bool> marks(List<Post> posts, {bool newestFirst = false}) => [
        for (final p in markStuckReplies(posts, newestFirst: newestFirst)) p.stuck,
      ];

      expect(marks([floor(1), floor(2), floor(3)]), [false, false, false]);
      expect(marks([floor(1), floor(7), floor(5), floor(2), floor(3)]), [false, true, true, false, false]);
      // The second floor stuck alone is where it would be anyway.
      expect(marks([floor(1), floor(2), floor(3), floor(4)]), [false, false, false, false]);
      expect(marks([floor(1), floor(9, hot: true), floor(2), floor(3)]), [false, false, false, false]);
      expect(
        marks([floor(1), floor(3), floor(9), floor(8), floor(7)], newestFirst: true),
        [false, true, false, false, false],
      );
    });
  });

  group('take rates back', () {
    test("the window: its rates as the forum lists them, each sent back by the checkbox's value", () {
      for (final name in ['removerate_window.json', 'removerate_window_ajax.xml']) {
        final form = _rateWindow(name);
        expect(form.uid, _moderator, reason: name);
        expect(form.fields, {'formhash': 'f1f2f3f4', 'tid': _tid, 'pid': _pid, 'handlekey': 'rate'}, reason: name);
        expect(
          [for (final e in form.entries) (e.logId, e.username, e.uid, e.time, e.credit, e.reason)],
          [
            ('31 6 1700004217', '测试版主', 31, '2026-11-10 12:16', '精灵 +1', 'MX評分mid'),
            ('30 1 1700004218', '测试管理员', 30, '2026-11-10 12:16', '威望 +1', 'MX評分admin'),
          ],
          reason: name,
        );
        expect(form.canNotify, isTrue);
        expect(form.notifyForced, isFalse);
      }
    });

    test('the body: the rates chosen by index, none the window does not list', () {
      final form = _rateWindow('removerate_window.json');
      expect(form.body(['30 1 1700004218', '1 1 1', '30 1 1700004218'], reason: ' 误评 ', notify: true), {
        'formhash': 'f1f2f3f4',
        'tid': _tid,
        'pid': _pid,
        'handlekey': 'rate',
        'logidarray[0]': '30 1 1700004218',
        'reason': '误评',
        'sendreasonpm': 'on',
        'ratesubmit': 'true',
      });
    });

    test("a member: the forum's words, as JSON and as AJAX; a window of another account is dropped", () {
      for (final name in ['removerate_nopermission.json', 'removerate_nopermission_ajax.xml']) {
        expect(
          _rateWindowOf(name, uid: 42),
          isA<Right<AppException, RemoveRateWindow>>().having(
            (e) => (e.value as RemoveRateWindowRefused).message,
            'message',
            '抱歉，您没有权限撤销评分',
          ),
          reason: name,
        );
      }
      expect(
        _rateWindowOf('removerate_window.json', uid: 99),
        isA<Left<AppException, RemoveRateWindow>>().having((e) => e.value, 'value', isA<IdentityChangedException>()),
      );
    });

    test('the results: thread_rate_removesucceed, as JSON and as AJAX; anything else refused', () {
      expect(removeRateOutcomeOf(_data('removerate_result.json')), isA<FloorOpSucceeded>());
      expect((removeRateOutcomeOf(_data('removerate_result_ajax.xml')) as FloorOpSucceeded).message, '评分撤销成功');
      expect(
        (removeRateOutcomeOf(_data('removerate_nopermission.json')) as FloorOpRefused).message,
        '抱歉，您没有权限撤销评分',
      );
      expect(
        (removeRateOutcomeOf(_data('removerate_nopermission_ajax.xml')) as FloorOpRefused).message,
        '抱歉，您没有权限撤销评分',
      );
      expect(removeRateOutcomeOf(_data('floor_stick_result.json')), isA<FloorOpRefused>());
    });

    test(
      'repository: the window asked with the plugin; posted once, never with nothing chosen or for another account',
      () async {
        var uid = _moderator;
        final gets = <String>[];
        final posts = <(String, Map<String, String>)>[];
        final repo = FloorOpsRepository(
          get: (url) async {
            gets.add(url);
            return right(_ok(_data('removerate_window.json')));
          },
          getOnce: (_) async => throw StateError('no write by GET'),
          post: (url, body) async {
            posts.add((url, body));
            return right(_ok(_data('removerate_result.json')));
          },
          currentUid: () => uid,
        );
        final window = await repo.fetchRemoveRateWindow(tid: _tid, pid: _pid).run();
        expect(gets.single, contains('mod=misc&action=removerate&tid=$_tid&pid=$_pid'));
        expect(gets.single, contains('tsdmapp=json'));
        final form = (window.getRight().toNullable()! as RemoveRateWindowReady).form;

        expect(await repo.removeRates(form, const []).run(), isA<Left<AppException, FloorOpOutcome>>());
        expect(posts, isEmpty);

        final outcome = await repo.removeRates(form, ['31 6 1700004217']).run();
        expect(outcome.getRight().toNullable(), isA<FloorOpSucceeded>());
        expect(posts.single.$1, endsWith('forum.php?mod=misc&action=removerate&ratesubmit=yes&infloat=yes&inajax=1'));
        expect(posts.single.$2['logidarray[0]'], '31 6 1700004217');

        uid = 99;
        expect(
          await repo.removeRates(form, ['31 6 1700004217']).run(),
          isA<Left<AppException, FloorOpOutcome>>().having((e) => e.value, 'value', isA<IdentityChangedException>()),
        );
        expect(posts, hasLength(1));
      },
    );

    testWidgets('the dialog: nothing to send until a rate is checked; the checked ones sent', (tester) async {
      final posts = <Map<String, String>>[];
      final repo = FloorOpsRepository(
        get: (_) async => right(_ok(_data('removerate_window.json'))),
        getOnce: (_) async => throw StateError('no write by GET'),
        post: (_, body) async {
          posts.add(body);
          return right(_ok(_data('removerate_result.json')));
        },
        currentUid: () => _moderator,
      );
      var reloaded = 0;
      bool? done;
      await tester.pumpWidget(
        _app(
          (context) async => done = await showRemoveRateDialog(
            context,
            tid: _tid,
            pid: _pid,
            repository: repo,
            onDone: () => reloaded++,
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('测试版主'), findsOneWidget);
      expect(find.text('威望 +1'), findsOneWidget);
      final ok = find.widgetWithText(TextButton, t.general.ok);
      expect(tester.widget<TextButton>(ok).onPressed, isNull);
      await tester.tap(find.text('测试管理员'));
      await tester.pump();
      await tester.tap(ok);
      await tester.pumpAndSettle();
      expect(posts.single['logidarray[0]'], '30 1 1700004218');
      expect(posts.single.keys.where((e) => e.startsWith('logidarray')), hasLength(1));
      expect(done, isTrue);
      expect(reloaded, 1);
    });
  });

  group('delete an attachment', () {
    test('the answer: how many the forum deleted, as JSON and as AJAX', () {
      expect(deleteAttachmentOutcomeOf(_data('deleteattach_ok.json')), isA<FloorOpSucceeded>());
      expect(deleteAttachmentOutcomeOf(_data('deleteattach_refused.json')), isA<FloorOpRefused>());
      expect(deleteAttachmentOutcomeOf(_data('deleteattach_refused_ajax.xml')), isA<FloorOpRefused>());
      expect(deleteAttachmentOutcomeOf('<html><body>维护中</body></html>'), isNull);
    });

    test('repository: one GET that is never retried, the edit form of the same account only', () async {
      // The author deleted it (the answer was served to the author).
      const author = 42;
      var uid = author;
      final once = <String>[];
      final repo = FloorOpsRepository(
        get: (_) async => throw StateError('a deletion is no read'),
        getOnce: (url) async {
          once.add(url);
          return right(_ok(_data('deleteattach_ok.json')));
        },
        post: (_, _) async => throw StateError('no post'),
        currentUid: () => uid,
      );
      final outcome = await repo
          .deleteAttachment(tid: _tid, pid: _pid, aid: 90008, formHash: 'f1f2f3f4', formUid: author)
          .run();
      expect(outcome.getRight().toNullable(), isA<FloorOpSucceeded>());
      expect(
        once.single,
        contains(
          'forum.php?mod=ajax&action=deleteattach&inajax=yes&formhash=f1f2f3f4&tid=$_tid&pid=$_pid&aids%5B%5D=90008',
        ),
      );
      expect(once.single, contains('tsdmapp=json'));

      uid = 44;
      expect(
        await repo.deleteAttachment(tid: _tid, pid: _pid, aid: 90008, formHash: 'f1f2f3f4', formUid: author).run(),
        isA<Left<AppException, FloorOpOutcome>>().having((e) => e.value, 'value', isA<IdentityChangedException>()),
      );
      expect(once, hasLength(1));
    });

    test('the edit form once deleted: the attachment and its fields out, delattachop 1', () {
      final json = _data('edit_attach_moderator.json')! as Map<String, dynamic>;
      expect(
        [for (final a in editAttachmentsOf(json)) (a.aid, a.filename, a.isImage)],
        [
          (90009, 'mx.png', true),
          (90008, 'mx.zip', false),
        ],
      );
      final served = PostForm.fromJson(json)!.body().toMap()!;
      expect(served['delattachop'], '0');
      expect(served.keys, contains('attachupdate[90008]'));

      final left = editFormWithoutAttachment(json, 90008);
      expect([for (final a in editAttachmentsOf(left)) a.aid], [90009]);
      final body = PostForm.fromJson(left)!.body().toMap()!;
      expect(body['delattachop'], '1');
      expect(body.keys.where((e) => e.contains('90008')), isEmpty);
      expect(body.keys, containsAll(['attachupdate[90009]', 'attachnew[90009][description]']));
      // Another attachment whose id starts the same keeps its fields.
      final similar = editFormWithoutAttachment({
        'attach': {
          'used': const <Object>[],
          'fields': {'attachupdate[9000]': '', 'attachnew[90008][description]': '', 'attachnew[9000][price]': '0'},
        },
      }, 9000);
      expect((similar['attach'] as Map)['fields'], {'attachnew[90008][description]': ''});
      // The served answer is left as it was.
      expect(editAttachmentsOf(json), hasLength(2));
    });

    testWidgets('the list: each deletion confirmed, then sent once', (tester) async {
      final once = <String>[];
      final deleted = <int>[];
      final repo = FloorOpsRepository(
        get: (_) async => throw StateError('no read'),
        getOnce: (url) async {
          once.add(url);
          return right(_ok(_data('deleteattach_ok.json')));
        },
        post: (_, _) async => throw StateError('no post'),
        currentUid: () => 42,
      );
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: EditAttachmentsButton(
                attachments: editAttachmentsOf(_data('edit_attach_moderator.json')! as Map<String, dynamic>),
                tid: _tid,
                pid: _pid,
                formHash: 'f1f2f3f4',
                formUid: 42,
                onDeleted: deleted.add,
                repository: repo,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byType(IconButton));
      await tester.pumpAndSettle();
      expect(find.text('mx.zip'), findsOneWidget);
      final delete = find.descendant(
        of: find.widgetWithText(ListTile, 'mx.zip'),
        matching: find.byIcon(Icons.delete_outline),
      );
      await tester.tap(delete);
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.general.cancel));
      await tester.pumpAndSettle();
      expect(once, isEmpty);
      await tester.tap(delete);
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.general.ok));
      await tester.pumpAndSettle();
      expect(once.single, contains('aids%5B%5D=90008'));
      expect(deleted, [90008]);
      expect(find.text('mx.zip'), findsNothing);
      expect(find.text('mx.png'), findsOneWidget);
    });
  });

  testWidgets('the list stays while a deletion is out, and the editor learns it was deleted', (tester) async {
    final answer = Completer<Either<AppException, ModerateResponse>>();
    final deleted = <int>[];
    final repo = FloorOpsRepository(
      get: (_) async => throw StateError('no read'),
      getOnce: (_) => answer.future,
      post: (_, _) async => throw StateError('no post'),
      currentUid: () => 42,
    );
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: EditAttachmentsButton(
              attachments: editAttachmentsOf(_data('edit_attach_moderator.json')! as Map<String, dynamic>),
              tid: _tid,
              pid: _pid,
              formHash: 'f1f2f3f4',
              formUid: 42,
              onDeleted: deleted.add,
              repository: repo,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(IconButton));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: find.widgetWithText(ListTile, 'mx.zip'), matching: find.byIcon(Icons.delete_outline)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.general.ok));
    await tester.pump();
    await tester.tapAt(const Offset(5, 5));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('mx.zip'), findsOneWidget);
    answer.complete(right(_ok(_data('deleteattach_ok.json'))));
    await tester.pumpAndSettle();
    expect(deleted, [90008]);
  });

  group("another member's floor", () {
    test('a moderator is offered its edit, and the forum shows who edited it last', () {
      final page = threadPageFromApi(_data('thread_moderator_edit_api.json')! as Map<String, dynamic>, 1);
      final floor = page.postList.firstWhere((e) => e.postID == _pid);
      expect(floor.author.uid, '42');
      expect(floor.editUrl, contains('mod=post&action=edit&fid=10&tid=$_tid&pid=$_pid'));
      expect(floor.lastEditUsername, '测试版主');

      // The edit form the forum served the moderator for that floor is the editor's, and posted back with his text,
      // the author's options as served (not made anonymous).
      final form = PostForm.fromJson(_data('edit_attach_moderator.json')! as Map<String, dynamic>)!;
      expect(form.uid, _moderator);
      expect(form.editorSupport('edit'), PostFormSupport.supported);
      final body = form.bodyWith(const PostFormEdits(message: '版主修改的内容')).toMap()!;
      expect(body['message'], '版主修改的内容');
      expect(body['pid'], '7654325');
      expect(body['editsubmit'], 'true');
      expect(body.containsKey('isanonymous'), isFalse);
    });
  });
}
