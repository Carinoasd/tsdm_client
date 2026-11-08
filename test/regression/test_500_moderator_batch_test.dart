/// Thread management of several threads of a forum at once (the forum page's picking mode).
///
/// The fixtures `test/data/moderate/batch_*` are the test forum's answers to account 31 moderating forum 10 (Discuz!
/// X5 with plugin tsdmapp 3.4.0), scrubbed: the management windows asked for threads 1234567, 1234568 and 1 (a thread
/// not in the forum, left out of the window) with `tsdmapp=json` (groups 1 and 3) and without (group 4, the AJAX
/// fragment), and the refusal to open one for threads none of which can be managed (`admin_moderate_invalid`).
///
/// The forum takes one verdict for the threads of a request and acts on those its window holds, no more than the
/// account's threads per page (20 on the test forum): the batch is posted window by window, the threads numbered
/// (`moderate[0]`, `moderate[1]`…, read by the forum as the website's repeated `moderate[]`).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/moderate/models/moderate_form.dart';
import 'package:tsdm_client/features/moderate/repository/moderate_repository.dart';
import 'package:tsdm_client/features/moderate/widgets/moderate_sheet.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';

const _dir = 'test/data/moderate';
const _fid = 10;
const _uid = 31;
const _asked = ['1234567', '1234568', '1'];

Object? _data(String name) {
  final text = File('$_dir/$name').readAsStringSync();
  return name.endsWith('.json') ? jsonDecode(text) : text;
}

ModerateBatchForm _window(String name, ModerateOperation operation, {List<String> tids = _asked}) =>
    switch (ModerateRepository.batchWindowOf(_data(name), operation, tids: tids, fid: _fid, uid: _uid)) {
      Right(value: ModerateBatchWindowReady(:final form)) => form,
      final other => throw StateError('no window: $other'),
    };

/// The stick window of the fixture holding threads [tids] instead.
Map<String, dynamic> _stickWindowOf(List<String> tids) {
  final json = _data('batch_window_stick_digest.json')! as Map<String, dynamic>;
  final inputs = tids.map((e) => '<input type="hidden" name="moderate[]" value="$e" />').join('\n');
  final document = (json['document'] as String)
      .replaceAll(RegExp(r'<input type="hidden" name="moderate\[\]" value="1234568" />\s*'), '')
      .replaceFirst('<input type="hidden" name="moderate[]" value="1234567" />', inputs);
  return {...json, 'document': document};
}

/// The threads of request body [body], in their order (`moderate[0]`, `moderate[1]`…).
List<String> _threadsOf(Map<String, String> body) => [
  for (var i = 0; body.containsKey('moderate[$i]'); i++) body['moderate[$i]']!,
];

/// The threads asked in window url [url].
List<String> _tidsOf(String url) => RegExp(r'moderate%5B%5D=(\d+)').allMatches(url).map((e) => e.group(1)!).toList();

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
  });

  group('window', () {
    test('the threads the forum takes, the others left out; no level chosen for several', () {
      final batch = _window('batch_window_stick_digest.json', ModerateOperation.stick);
      expect(batch.tids, ['1234567', '1234568']);
      expect(batch.window.uid, _uid);
      expect(batch.window.fields, {
        'frommodcp': '',
        'formhash': 'f1f2f3f4',
        'fid': '10',
        'redirect': 'https://forum.test/./',
        'handlekey': 'mods',
      });
      expect(batch.window.levels.map((e) => e.value), ['0', '1']);
      expect(batch.window.currentLevel, isNull);
      expect(_window('batch_window_stick_digest.json', ModerateOperation.digest).window.levels, hasLength(4));
    });

    test('the window of several threads is not the window of one', () {
      final doc = tsdmAppWriteResultOf(_data('batch_window_stick_digest.json'))!.document;
      expect(ModerateForm.parse(doc, ModerateOperation.stick, tid: '1234567', fid: _fid, uid: _uid), isNull);
    });

    test('a thread served that was not asked: not this window', () {
      expect(
        ModerateRepository.batchWindowOf(
          _data('batch_window_stick_digest.json'),
          ModerateOperation.stick,
          tids: const ['1234567'],
          fid: _fid,
          uid: _uid,
        ).getLeft().toNullable(),
        isNotNull,
      );
    });

    test('close and open: none checked for several threads, the one asked is done', () {
      expect(_window('batch_window_close_ajax.xml', ModerateOperation.close).window.operation, ModerateOperation.close);
      expect(_window('batch_window_close_ajax.xml', ModerateOperation.open).window.operation, ModerateOperation.open);
    });

    test('one thread picked: close or open done as picked, whatever the window of one thread checks', () {
      // The window of one closed thread checks open.
      final single = ModerateForm.parse(
        tsdmAppWriteResultOf(_data('window_close.json'))!.document,
        ModerateOperation.close,
        tid: '1234567',
        fid: _fid,
        uid: _uid,
      );
      expect(single?.operation, ModerateOperation.open);
      final batch = _window('window_close.json', ModerateOperation.close, tids: const ['1234567']);
      expect(batch.tids, ['1234567']);
      expect(batch.window.operation, ModerateOperation.close);
      expect(
        batch.body(const ModerateRequest(operation: ModerateOperation.close))['operations[]'],
        'close',
      );
    });

    test('bump and sink: group 3 asked without an operation', () {
      final batch = _window('batch_window_bump_down.json', ModerateOperation.bump);
      expect(batch.tids, ['1234567', '1234568']);
      final url = ModerateForm.batchWindowUrl(ModerateOperation.down, tids: const ['1', '2'], fid: _fid);
      expect(url, contains('&moderate%5B%5D=1&moderate%5B%5D=2&'));
      expect(url, contains('optgroup=3'));
      expect(url, isNot(contains('operation=')));
      expect(
        ModerateForm.batchWindowUrl(ModerateOperation.delete, tids: const ['1'], fid: _fid),
        contains('operation=delete'),
      );
      expect(
        ModerateForm.windowUrl(ModerateOperation.stick, tid: '1', fid: _fid),
        endsWith(
          '/forum.php?mod=topicadmin&action=moderate&fid=10&moderate%5B%5D=1&handlekey=mods&infloat=yes'
          '&nopost=yes&optgroup=1&inajax=1',
        ),
      );
    });

    test("none of the threads can be managed: the forum's words", () {
      expect(
        ModerateRepository.batchWindowOf(
          _data('batch_window_invalid.json'),
          ModerateOperation.stick,
          tids: const ['1'],
          fid: _fid,
          uid: _uid,
        ).getRight().toNullable(),
        isA<ModerateBatchWindowRefused>().having((e) => e.message, 'message', '抱歉，您尚未选择主题或主题不可执行此类管理'),
      );
    });
  });

  group('body', () {
    test('every thread numbered, the operation and its own fields', () {
      final bump = _window('batch_window_bump_down.json', ModerateOperation.bump);
      final body = bump.body(const ModerateRequest(operation: ModerateOperation.bump, reason: ' 顶起 '));
      expect(_threadsOf(body), ['1234567', '1234568']);
      expect(body.keys.where((e) => e.startsWith('moderate')), ['moderate[0]', 'moderate[1]']);
      expect(body['operations[]'], 'bump');
      expect(body['expirationbump'], '');
      expect(body['reason'], '顶起');
      expect(
        _window(
          'batch_window_bump_down.json',
          ModerateOperation.down,
        ).body(const ModerateRequest(operation: ModerateOperation.down))['expirationdown'],
        '',
      );
    });
  });

  group('run', () {
    test('past the threads per page: posted window by window until all are done', () async {
      final tids = [for (var i = 0; i < 25; i++) '${2000000 + i}'];
      final windows = <List<String>>[];
      final posts = <List<String>>[];
      final repo = ModerateRepository(
        get: (url) async {
          final asked = _tidsOf(url);
          windows.add(asked);
          return right((statusCode: 200, data: _stickWindowOf(asked.take(20).toList())));
        },
        post: (url, body) async {
          posts.add(_threadsOf(body));
          expect(body['sticklevel'], '1');
          return right((statusCode: 200, data: _data('result_succeed.json')));
        },
        currentUid: () => _uid,
      );
      final first = (await repo.fetchBatchWindow(ModerateOperation.stick, tids: tids, fid: _fid).run())
          .getRight()
          .toNullable()!;
      final report = await repo.runBatch(
        (first as ModerateBatchWindowReady).form,
        const ModerateRequest(operation: ModerateOperation.stick, level: '1'),
        tids: tids,
        fid: _fid,
      );
      expect(windows, [tids, tids.sublist(20)]);
      expect(posts, [tids.sublist(0, 20), tids.sublist(20)]);
      expect(report.doneCount, 25);
      expect(report.failed, isEmpty);
      expect(report.results.keys, tids);
    });

    test("a thread no window takes failed in the forum's words", () async {
      final windows = <List<String>>[];
      var posts = 0;
      final repo = ModerateRepository(
        get: (url) async {
          windows.add(_tidsOf(url));
          return right((statusCode: 200, data: _data('batch_window_invalid.json')));
        },
        post: (url, body) async {
          posts++;
          return right((statusCode: 200, data: _data('result_succeed.json')));
        },
        currentUid: () => _uid,
      );
      final report = await repo.runBatch(
        _window('batch_window_stick_digest.json', ModerateOperation.stick),
        const ModerateRequest(operation: ModerateOperation.stick, level: '1'),
        tids: _asked,
        fid: _fid,
      );
      expect(posts, 1);
      expect(windows, [
        ['1'],
      ]);
      expect(report.doneCount, 2);
      expect(report.failed.single.$1, '1');
      expect(report.failed.single.$2.kind, ModerateBatchFailure.refused);
      expect(report.failed.single.$2.message, '抱歉，您尚未选择主题或主题不可执行此类管理');
    });

    test('a refusal fails every thread not done, and nothing is sent after it', () async {
      var gets = 0;
      final repo = ModerateRepository(
        get: (url) async {
          gets++;
          return right((statusCode: 200, data: _data('batch_window_invalid.json')));
        },
        post: (url, body) async => right((statusCode: 200, data: _data('result_stick_refused.json'))),
        currentUid: () => _uid,
      );
      final report = await repo.runBatch(
        _window('batch_window_stick_digest.json', ModerateOperation.stick),
        const ModerateRequest(operation: ModerateOperation.stick, level: '3'),
        tids: _asked,
        fid: _fid,
      );
      expect(gets, 0);
      expect(report.doneCount, 0);
      expect(report.failed.map((e) => e.$1), _asked);
      expect(report.failed.map((e) => e.$2.message).toSet(), {'抱歉，您没有权限设置主题置顶'});
    });

    test('an answer lost: the threads sent may be done, the others were not sent', () async {
      var gets = 0;
      final repo = ModerateRepository(
        get: (url) async {
          gets++;
          return right((statusCode: 200, data: _data('batch_window_invalid.json')));
        },
        post: (url, body) async => left(HttpRequestFailedException(null)),
        currentUid: () => _uid,
      );
      final report = await repo.runBatch(
        _window('batch_window_stick_digest.json', ModerateOperation.stick),
        const ModerateRequest(operation: ModerateOperation.stick, level: '1'),
        tids: _asked,
        fid: _fid,
      );
      expect(gets, 0);
      expect(
        {for (final (tid, failure) in report.failed) tid: failure.kind},
        {
          '1234567': ModerateBatchFailure.unknown,
          '1234568': ModerateBatchFailure.unknown,
          '1': ModerateBatchFailure.failed,
        },
      );
    });

    test('an answer the app can not read: the threads sent may be done', () async {
      final repo = ModerateRepository(
        get: (url) async => throw StateError('no window'),
        post: (url, body) async => right((statusCode: 200, data: '<html><body>maintenance</body></html>')),
        currentUid: () => _uid,
      );
      final report = await repo.runBatch(
        _window('batch_window_stick_digest.json', ModerateOperation.stick),
        const ModerateRequest(operation: ModerateOperation.stick, level: '1'),
        tids: _asked,
        fid: _fid,
      );
      expect(
        {for (final (tid, failure) in report.failed) tid: failure.kind},
        {
          '1234567': ModerateBatchFailure.unknown,
          '1234568': ModerateBatchFailure.unknown,
          '1': ModerateBatchFailure.refused,
        },
      );
    });

    test('the window of one account is never posted for another', () async {
      var posts = 0;
      final repo = ModerateRepository(
        get: (url) async => throw StateError('no window'),
        post: (url, body) async {
          posts++;
          return right((statusCode: 200, data: _data('result_succeed.json')));
        },
        currentUid: () => 32,
      );
      final report = await repo.runBatch(
        _window('batch_window_stick_digest.json', ModerateOperation.stick),
        const ModerateRequest(operation: ModerateOperation.stick, level: '1'),
        tids: _asked,
        fid: _fid,
      );
      expect(posts, 0);
      expect(report.failed.map((e) => e.$2.kind).toSet(), {ModerateBatchFailure.accountChanged});
    });
  });

  group('sheet', () {
    test('the operations of several threads: both close and open, bump and sink, delete last', () {
      expect(moderateBatchOperations, containsAll([ModerateOperation.close, ModerateOperation.open]));
      expect(moderateBatchOperations, containsAll([ModerateOperation.bump, ModerateOperation.down]));
      expect(moderateBatchOperations.last, ModerateOperation.delete);
      expect(moderateOperationsFor(closed: false), isNot(contains(ModerateOperation.bump)));
    });

    testWidgets('the dialog loads the window of the threads and pops what became of each', (tester) async {
      final posts = <Map<String, String>>[];
      final repo = ModerateRepository(
        get: (url) async => right((statusCode: 200, data: _data('batch_window_stick_digest.json'))),
        post: (url, body) async {
          posts.add(body);
          return right((statusCode: 200, data: _data('result_succeed.json')));
        },
        currentUid: () => _uid,
      );
      ModerateBatchReport? report;
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async => report = await showDialog<ModerateBatchReport>(
                    context: context,
                    builder: (_) => ModerateDialog.batch(
                      operation: ModerateOperation.stick,
                      tids: _asked,
                      fid: _fid,
                      repository: repo,
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
      expect(find.text(t.moderate.batch.title(operation: t.moderate.stick, count: 3)), findsOneWidget);
      final ok = find.widgetWithText(TextButton, t.general.ok);
      // No level chosen yet.
      expect(tester.widget<TextButton>(ok).onPressed, isNull);
      await tester.tap(find.text('本版置顶'));
      await tester.pumpAndSettle();
      await tester.tap(ok);
      await tester.pumpAndSettle();
      // Thread 1 is asked again on its own, and the window of the fixture is not one of it.
      expect(posts, hasLength(1));
      expect(_threadsOf(posts.single), ['1234567', '1234568']);
      expect(report?.doneCount, 2);
      expect(report?.failed.single.$1, '1');
    });
  });
}
