/// Thread management: highlight, recommend, and bump and sink from the thread page.
///
/// The fixtures under `test/data/moderate` are the test forum's answers to a moderator of forum 10 (Discuz! X5 with
/// plugin tsdmapp 3.6.0), scrubbed as the other fixtures there (account 31, thread 1234567, forum 10):
///
/// * `window_highlight.json`: the window of group 1 asked for `highlight`, the thread not highlighted, the forum
///   offering recommendation; `window_highlight_set.json` the same once highlighted (color 5, bold and underline,
///   background `#FFFF00`); `window_highlight_ajax.xml` the AJAX fragment without the plugin;
///   `batch_window_highlight.json` the window of threads 1234567 and 1234568, the highlight fields served empty;
/// * `window_recommend.json`: the window of group 1 asked for `recommend` (the recommendation alone, its title and
///   place); `window_recommend_set.json` once recommended with an end day; `window_recommend_closed.json` the same
///   asked in a forum without recommendation (no operation at all);
/// * `window_bump_down.json`: the window of group 3 asked without `operation` (bump and sink);
/// * `result_highlight_invalid.json`: the answer to a color out of 0 to 8 (`parameters_error`).
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
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';

Translations get t => LocaleSettings.instance.currentTranslations;

const _dir = 'test/data/moderate';
const _tid = '1234567';
const _fid = 10;
const _uid = 31;

Object? _data(String name) {
  final text = File('$_dir/$name').readAsStringSync();
  return name.endsWith('.json') ? jsonDecode(text) : text;
}

/// The answer [name] with [edit] applied to its window.
Map<String, dynamic> _edited(String name, String Function(String document) edit) {
  final page = jsonDecode(jsonEncode(_data(name))) as Map<String, dynamic>;
  page['document'] = edit(page['document'] as String);
  return page;
}

Either<AppException, ModerateWindow> _windowOf(Object? data, ModerateOperation operation) =>
    ModerateRepository.windowOf(data, operation, tid: _tid, fid: _fid, uid: _uid);

ModerateForm _window(Object? data, ModerateOperation operation) => switch (_windowOf(data, operation)) {
  Right(value: ModerateWindowReady(:final form)) => form,
  final other => throw StateError('no window: $other'),
};

String _day(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// A repository serving window [window] and answering every post with [result], the bodies posted kept in [posts].
ModerateRepository _repo(Object? window, List<Map<String, String>> posts, {String result = 'result_succeed.json'}) =>
    ModerateRepository(
      get: (url) async => right((statusCode: 200, data: window)),
      post: (url, body) async {
        posts.add(body);
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
                builder: (_) => ModerateDialog(operation: operation, tid: _tid, fid: _fid, repository: repo),
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
      expect(ModerateOperation.highlight.group, 1);
      expect(ModerateOperation.recommend.group, 1);
      expect(
        ModerateForm.windowUrl(ModerateOperation.highlight, tid: _tid, fid: _fid),
        allOf(contains('optgroup=1'), contains('&operation=highlight')),
      );
      expect(
        ModerateForm.windowUrl(ModerateOperation.recommend, tid: _tid, fid: _fid),
        contains('&operation=recommend'),
      );
      // Bump and sink: the window of group 3 asked as it is holds both.
      for (final op in [ModerateOperation.bump, ModerateOperation.down]) {
        expect(
          ModerateForm.windowUrl(op, tid: _tid, fid: _fid),
          allOf(contains('optgroup=3'), isNot(contains('operation='))),
        );
      }
    });

    test('highlight: none, then as set', () {
      final none = _window(_data('window_highlight.json'), ModerateOperation.highlight);
      expect(none.highlight, const ModerateHighlight());
      expect(none.highlight!.marksTitle, isFalse);
      expect(none.fields, {
        'frommodcp': '',
        'formhash': 'f1f2f3f4',
        'fid': '10',
        'redirect': 'https://forum.test/./',
        'handlekey': 'mods',
        'moderate[]': _tid,
      });
      expect(none.canNotify, isTrue);
      expect(none.reasons, contains('广告/SPAM'));

      final set = _window(_data('window_highlight_set.json'), ModerateOperation.highlight);
      expect(
        set.highlight,
        const ModerateHighlight(color: 5, bold: true, underline: true, background: '#FFFF00'),
      );
      expect(set.highlight!.marksTitle, isTrue);
      // The other operations of the same window know nothing of the highlight.
      expect(_window(_data('window_highlight_set.json'), ModerateOperation.stick).highlight, isNull);
    });

    test('highlight: the AJAX fragment of a forum without the plugin', () {
      final form = _window(_data('window_highlight_ajax.xml'), ModerateOperation.highlight);
      expect(form.highlight, const ModerateHighlight());
      expect(form.fields['formhash'], 'f1f2f3f4');
    });

    test('highlight: a color out of the palette is none, the background kept as the forum kept it', () {
      final form = _window(
        _edited(
          'window_highlight_set.json',
          (d) => d
              .replaceFirst('name="highlight_color" value="5"', 'name="highlight_color" value="12"')
              .replaceFirst('name="highlight_bgcolor" value="#FFFF00"', 'name="highlight_bgcolor" value="red"'),
        ),
        ModerateOperation.highlight,
      );
      expect(form.highlight!.color, 0);
      expect(form.highlight!.background, 'red');
    });

    test('highlight of several threads: served empty, none', () {
      final batch = ModerateRepository.batchWindowOf(
        _data('batch_window_highlight.json'),
        ModerateOperation.highlight,
        tids: ['1234567', '1234568'],
        fid: _fid,
        uid: _uid,
      );
      final form = (batch.getRight().toNullable()! as ModerateBatchWindowReady).form;
      expect(form.tids, ['1234567', '1234568']);
      expect(form.window.highlight, const ModerateHighlight());
      expect(form.window.fields.containsKey('moderate[]'), isFalse);
    });

    test('recommend: the title and the place, sent back as served', () {
      final form = _window(_data('window_recommend.json'), ModerateOperation.recommend);
      expect(form.recommendTitle, 'MX測試 高亮推薦 1');
      expect(form.recommendFields, {'position': '1'});
      expect(form.expiration, isNull);
      // The window of the recommendation alone holds no other operation.
      expect(
        _windowOf(_data('window_recommend.json'), ModerateOperation.stick),
        isA<Right<AppException, ModerateWindow>>(),
      );
      expect(
        (_windowOf(_data('window_recommend.json'), ModerateOperation.stick).getRight().toNullable()!
                as ModerateWindowRefused)
            .unavailable,
        isTrue,
      );
    });

    test('recommend: the image chosen before is kept', () {
      final form = _window(
        _edited(
          'window_recommend.json',
          (d) => d.replaceFirst(
            '<input type="hidden" name="position" value="1" />',
            '<input type="hidden" name="position" value="1" />\n<tr class="dopt"><td>&nbsp;</td><td> '
                '<select name="selectattach" class="ps"><option value="">不使用图片</option> '
                '<option value="77">a.jpg</option><option value="78" selected="selected">b.jpg</option></select> '
                '</td></tr>',
          ),
        ),
        ModerateOperation.recommend,
      );
      expect(form.recommendFields, {'position': '1', 'selectattach': '78'});
    });

    test('the end day served: kept when after today', () {
      final ahead = DateTime.now().add(const Duration(days: 10));
      expect((_data('window_recommend_set.json')! as Map<String, dynamic>)['document'], contains('2026-11-15 00:00'));
      final later = _window(
        _edited('window_recommend_set.json', (d) => d.replaceFirst('2026-11-15 00:00', '${_day(ahead)} 00:00')),
        ModerateOperation.recommend,
      );
      expect(later.expiration, DateTime(ahead.year, ahead.month, ahead.day));
      final past = _window(
        _edited('window_recommend_set.json', (d) => d.replaceFirst('2026-11-15 00:00', '2020-01-01 00:00')),
        ModerateOperation.recommend,
      );
      expect(past.expiration, isNull);
    });

    test('a forum without recommendation: the window without the operation, not a failure to retry', () {
      final answer = _windowOf(_data('window_recommend_closed.json'), ModerateOperation.recommend);
      expect(
        answer.getRight().toNullable(),
        isA<ModerateWindowRefused>().having((e) => e.unavailable, 'unavailable', isTrue),
      );
      // A window of another group, thread or forum is still no window.
      expect(_windowOf(_data('window_close.json'), ModerateOperation.highlight).isLeft(), isTrue);
      expect(
        ModerateRepository.windowOf(
          _data('window_recommend_closed.json'),
          ModerateOperation.recommend,
          tid: '1',
          fid: _fid,
          uid: _uid,
        ).isLeft(),
        isTrue,
      );
      expect(
        ModerateRepository.windowOf(
          _data('window_recommend_closed.json'),
          ModerateOperation.recommend,
          tid: _tid,
          fid: 2,
          uid: _uid,
        ).isLeft(),
        isTrue,
      );
      // The refusal of the forum is still its words.
      expect(
        _windowOf(_data('window_nopermission.json'), ModerateOperation.highlight).getRight().toNullable(),
        isA<ModerateWindowRefused>()
            .having((e) => e.message, 'message', '抱歉，您没有权限使用管理功能')
            .having((e) => e.unavailable, 'unavailable', isFalse),
      );
    });

    test('bump and sink of one thread: the window of group 3 asked as it is', () {
      expect(_window(_data('window_bump_down.json'), ModerateOperation.bump).operation, ModerateOperation.bump);
      expect(_window(_data('window_bump_down.json'), ModerateOperation.down).operation, ModerateOperation.down);
      expect(_windowOf(_data('window_bump_down.json'), ModerateOperation.delete).isRight(), isTrue);
    });
  });

  group('request body', () {
    test('highlight with an end day', () {
      final form = _window(_data('window_highlight.json'), ModerateOperation.highlight);
      final body = ModerateRequest(
        operation: ModerateOperation.highlight,
        highlight: const ModerateHighlight(color: 5, bold: true, underline: true, background: '#FFF3B0'),
        expiration: DateTime(2026, 11, 20),
        reason: ' 好帖 ',
      ).body(form);
      expect(body, {
        ...form.fields,
        'operations[]': 'highlight',
        'highlight_color': '5',
        'highlight_style[1]': '1',
        'highlight_style[2]': '0',
        'highlight_style[3]': '1',
        'highlight_bgcolor': '#FFF3B0',
        'expirationhighlight': '2026-11-20',
        'reason': '好帖',
      });
    });

    test('no highlight takes it off: every field cleared, no end day', () {
      final form = _window(_data('window_highlight_set.json'), ModerateOperation.highlight);
      final body = ModerateRequest(
        operation: ModerateOperation.highlight,
        highlight: const ModerateHighlight(),
        expiration: DateTime(2026, 11, 20),
      ).body(form);
      expect(body['highlight_color'], '0');
      expect([body['highlight_style[1]'], body['highlight_style[2]'], body['highlight_style[3]']], ['0', '0', '0']);
      expect(body['highlight_bgcolor'], '');
      expect(body['expirationhighlight'], '');
      // A background alone is not a highlight to the forum: no end day.
      final background = ModerateRequest(
        operation: ModerateOperation.highlight,
        highlight: const ModerateHighlight(background: '#D6EBFF'),
        expiration: DateTime(2026, 11, 20),
      ).body(form);
      expect(background['highlight_bgcolor'], '#D6EBFF');
      expect(background['expirationhighlight'], '');
    });

    test('highlight of several threads', () {
      final batch =
          (ModerateRepository.batchWindowOf(
                    _data('batch_window_highlight.json'),
                    ModerateOperation.highlight,
                    tids: ['1234567', '1234568'],
                    fid: _fid,
                    uid: _uid,
                  ).getRight().toNullable()!
                  as ModerateBatchWindowReady)
              .form;
      final body = batch.body(
        const ModerateRequest(operation: ModerateOperation.highlight, highlight: ModerateHighlight(color: 4)),
      );
      expect(body['moderate[0]'], '1234567');
      expect(body['moderate[1]'], '1234568');
      expect(body['highlight_color'], '4');
      expect(body.containsKey('reducetitle'), isFalse);
    });

    test('recommend, and take it off', () {
      final form = _window(_data('window_recommend.json'), ModerateOperation.recommend);
      final body = ModerateRequest(
        operation: ModerateOperation.recommend,
        expiration: DateTime(2026, 11, 20),
        recommendTitle: ' 短标题 ',
      ).body(form);
      expect(body, {
        ...form.fields,
        'operations[]': 'recommend',
        'isrecommend': '1',
        'expirationrecommend': '2026-11-20',
        'position': '1',
        'reducetitle': '短标题',
        'reason': '',
      });
      // The title of the window when none was typed.
      expect(const ModerateRequest(operation: ModerateOperation.recommend).body(form)['reducetitle'], 'MX測試 高亮推薦 1');
      final off = ModerateRequest(
        operation: ModerateOperation.recommend,
        recommend: false,
        expiration: DateTime(2026, 11, 20),
      ).body(form);
      expect(off['isrecommend'], '0');
      expect(off['expirationrecommend'], '');
      expect(off.containsKey('reducetitle'), isFalse);
    });

    test('bump and sink', () {
      final form = _window(_data('window_bump_down.json'), ModerateOperation.bump);
      expect(const ModerateRequest(operation: ModerateOperation.bump).body(form)['operations[]'], 'bump');
      expect(const ModerateRequest(operation: ModerateOperation.down).body(form)['operations[]'], 'down');
      expect(form.submitUrl, contains('optgroup=3&modsubmit=yes'));
    });
  });

  test('a color the forum does not take: refused in its words', () {
    expect(
      ModerateRepository.outcomeOf(_data('result_highlight_invalid.json')),
      isA<ModerateRefused>().having((e) => e.message, 'message', '参数错误'),
    );
  });

  group('sheet', () {
    test('one thread: highlight and recommend after digest, bump and sink before move, delete last', () {
      expect(moderateOperationsFor(closed: false), [
        ModerateOperation.stick,
        ModerateOperation.digest,
        ModerateOperation.highlight,
        ModerateOperation.recommend,
        ModerateOperation.close,
        ModerateOperation.bump,
        ModerateOperation.down,
        ModerateOperation.move,
        ModerateOperation.delete,
      ]);
      expect(moderateBatchOperations, contains(ModerateOperation.highlight));
      expect(moderateBatchOperations, isNot(contains(ModerateOperation.recommend)));
      expect(moderateBatchOperations.last, ModerateOperation.delete);
    });

    testWidgets('highlight: the window as set, changed and sent once', (tester) async {
      final posts = <Map<String, String>>[];
      await _open(tester, ModerateOperation.highlight, _repo(_data('window_highlight_set.json'), posts));
      expect(find.text(t.moderate.highlight), findsOneWidget);
      // Highlighted: the end day is offered.
      expect(find.text(t.moderate.expiration), findsOneWidget);
      await tester.tap(find.byTooltip('#ee1b2e'));
      await tester.pump();
      await tester.tap(find.byTooltip(t.moderate.bold));
      await tester.pump();
      await tester.tap(find.byTooltip(t.moderate.italic));
      await tester.pump();
      await tester.tap(find.byTooltip(moderateHighlightBackgrounds.first));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, t.general.ok));
      await tester.pumpAndSettle();
      expect(posts, hasLength(1));
      expect(posts.single, containsPair('operations[]', 'highlight'));
      expect(posts.single, containsPair('highlight_color', '1'));
      expect(posts.single, containsPair('highlight_style[1]', '0'));
      expect(posts.single, containsPair('highlight_style[2]', '1'));
      expect(posts.single, containsPair('highlight_style[3]', '1'));
      expect(posts.single, containsPair('highlight_bgcolor', moderateHighlightBackgrounds.first));
      expect(find.byType(ModerateDialog), findsNothing);
    });

    testWidgets('highlight: taken off, no end day offered', (tester) async {
      final posts = <Map<String, String>>[];
      await _open(tester, ModerateOperation.highlight, _repo(_data('window_highlight_set.json'), posts));
      await tester.tap(find.byTooltip(t.moderate.defaultColor));
      await tester.pump();
      await tester.tap(find.byTooltip(t.moderate.bold));
      await tester.pump();
      await tester.tap(find.byTooltip(t.moderate.underline));
      await tester.pump();
      await tester.tap(find.byTooltip(t.moderate.noColor));
      await tester.pumpAndSettle();
      expect(find.text(t.moderate.expiration), findsNothing);
      await tester.tap(find.widgetWithText(TextButton, t.general.ok));
      await tester.pumpAndSettle();
      expect(posts.single, containsPair('highlight_color', '0'));
      expect(posts.single, containsPair('highlight_style[1]', '0'));
      expect(posts.single, containsPair('highlight_style[3]', '0'));
      expect(posts.single, containsPair('highlight_bgcolor', ''));
    });

    testWidgets("highlight refused: the forum's words, the dialog stays", (tester) async {
      final posts = <Map<String, String>>[];
      await _open(
        tester,
        ModerateOperation.highlight,
        _repo(_data('window_highlight.json'), posts, result: 'result_highlight_invalid.json'),
      );
      await tester.tap(find.byTooltip('#2897c5'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, t.general.ok));
      await tester.pumpAndSettle();
      expect(posts, hasLength(1));
      expect(find.text('参数错误'), findsOneWidget);
      expect(find.byType(ModerateDialog), findsOneWidget);
    });

    testWidgets('recommend: the title of the window, taken off without one', (tester) async {
      final posts = <Map<String, String>>[];
      await _open(tester, ModerateOperation.recommend, _repo(_data('window_recommend.json'), posts));
      expect(find.widgetWithText(TextField, 'MX測試 高亮推薦 1'), findsOneWidget);
      expect(find.text(t.moderate.expiration), findsOneWidget);
      await tester.tap(find.text(t.moderate.unrecommend));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, 'MX測試 高亮推薦 1'), findsNothing);
      expect(find.text(t.moderate.expiration), findsNothing);
      await tester.tap(find.widgetWithText(TextButton, t.general.ok));
      await tester.pumpAndSettle();
      expect(posts.single, containsPair('operations[]', 'recommend'));
      expect(posts.single, containsPair('isrecommend', '0'));
      expect(posts.single, containsPair('expirationrecommend', ''));
    });

    testWidgets('recommend where the forum does not offer it: said so, nothing to retry or send', (tester) async {
      final posts = <Map<String, String>>[];
      await _open(tester, ModerateOperation.recommend, _repo(_data('window_recommend_closed.json'), posts));
      expect(find.text(t.moderate.unavailable), findsOneWidget);
      expect(find.widgetWithText(TextButton, t.general.retry), findsNothing);
      expect(find.widgetWithText(TextButton, t.general.ok), findsNothing);
      await tester.tap(find.widgetWithText(TextButton, t.general.cancel));
      await tester.pumpAndSettle();
      expect(posts, isEmpty);
    });

    testWidgets('sink from the thread page', (tester) async {
      final posts = <Map<String, String>>[];
      await _open(tester, ModerateOperation.down, _repo(_data('window_bump_down.json'), posts));
      expect(find.text(t.moderate.down), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, t.general.ok));
      await tester.pumpAndSettle();
      expect(posts.single, containsPair('operations[]', 'down'));
      expect(posts.single, containsPair('moderate[]', _tid));
    });
  });
}
