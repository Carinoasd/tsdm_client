import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/fp.dart';
import 'package:tsdm_client/features/rate/repository/rate_repository.dart';
import 'package:tsdm_client/features/rate/view/rate_post_page.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/widgets/debounce_buttons.dart';
import 'package:tsdm_client/widgets/section_switch_list_tile.dart';

/// Samples of Discuz! X5 (TSDM) answers:
///
/// * rate_window_x5.xml: the rate window of a post, captured live (2026-09-22) with a test account, formhash masked.
///   The "通知作者" checkbox is a plain checkbox; with the user group setting `reasonpm` 2 or 3 the forum renders it
///   `checked="checked" disabled="disabled"` (template/default/forum/rate.php), built below from the same sample.
/// * rate_submit_rejected_x5.xml: the answer to a rate the forum refused, captured live (score far above what the
///   account could give, nothing was rated).
/// * rate_submit_success_x5.xml: built from the X5 source (`showmessage('thread_rate_succeed', dreferer())` in an
///   ajax post); byte for byte the answer of a real +1 rate between two test accounts, captured later the same day.
String _data(String name) => File('test/data/$name').readAsStringSync();

const _pid = '77983792';
const _rateAction = '$baseUrl/forum.php?mod=misc&action=rate&tid=1264975&pid=$_pid';
const _refused = '抱歉，您的天使币不足，无法评分';

String _forcedNoticeWindow() {
  const plain = '<input type="checkbox" name="sendreasonpm" id="sendreasonpm" class="pc" />';
  final window = _data('rate_window_x5.xml');
  expect(window, contains(plain));
  return window.replaceFirst(
    plain,
    '<input type="checkbox" name="sendreasonpm" id="sendreasonpm" class="pc" checked="checked" disabled="disabled" />',
  );
}

/// Plays the forum: answers each rate window GET with the next of [windows] (the last one again when used up) and
/// each rate POST with the next of [submits]; [offline] as a submit fails the request instead. The GET at index `i`
/// waits for `holds[i]` when there is one.
final class _FakeForum implements HttpClientAdapter {
  _FakeForum({required this.windows, List<String>? submits, this.holds = const {}}) : submits = submits ?? [];

  static const offline = 'offline';

  final List<String> windows;
  final List<String> submits;
  final Map<int, Completer<void>> holds;
  final gets = <Uri>[];
  final posts = <Map<String, String>>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final String body;
    if (options.method == 'POST') {
      final encoded = await requestStream!.fold<List<int>>([], (all, chunk) => all..addAll(chunk));
      posts.add(Uri.splitQueryString(String.fromCharCodes(encoded)));
      body = submits.removeAt(0);
      if (body == offline) {
        throw DioException.connectionError(requestOptions: options, reason: offline);
      }
    } else {
      final index = gets.length;
      gets.add(options.uri);
      await holds[index]?.future;
      body = windows[index < windows.length ? index : windows.length - 1];
    }
    return ResponseBody.fromString(
      body,
      200,
      headers: {
        Headers.contentTypeHeader: ['text/xml; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

String _windowWithFormHash(String formHash) {
  final window = _data('rate_window_x5.xml');
  expect(window, contains('value="XXXXXXXX"'));
  return window.replaceFirst('value="XXXXXXXX"', 'value="$formHash"');
}

/// The answer to a rate window request the forum refuses (`showmessage` of an ajax GET, template
/// common/showmessage.php `msgtype` 2), here `thread_rate_duplicate`.
const _duplicateWindow =
    '<?xml version="1.0" encoding="utf-8"?>\r\n<root><![CDATA[<h3 class="flb"><em>提示信息</em><span><a '
    'href="javascript:;" '
    'class="flbc" onclick="hideWindow(\'rate\');" title="关闭">关闭</a></span></h3>\n<div class="c altw">\n<div '
    'class="alert_error">抱歉，您不能对同一个帖子重复评分<script type="text/javascript" reload="1">if(typeof '
    "errorhandle_rate=='function') {errorhandle_rate('抱歉，您不能对同一个帖子重复评分', {});}</script></div>\n</div>\n"
    '<p class="o pns">\n<button type="button" class="pn pnc" id="closebtn" '
    'onclick="hideWindow(\'rate\');"><strong>确定</strong></button>\n</p>]]></root>';

void main() {
  late AppDatabase db;
  late SettingsRepository settings;

  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(useConsoleLogs: false));
  });

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    final storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings)
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty);
    await settings.init();
  });

  tearDown(() async {
    await getIt.reset();
    await settings.dispose();
    await db.close();
  });

  void useForum(_FakeForum forum) => getIt.registerFactory<NetClientProvider>(
    () => NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = forum),
  );

  group('rate repository', () {
    test('parses the X5 rate window, the notify checkbox is optional unless the forum forces it', () async {
      useForum(_FakeForum(windows: [_data('rate_window_x5.xml')]));
      final info = (await RateRepository().fetchInfo(pid: _pid, rateTarget: _rateAction).run()).unwrap();
      expect(info.formHash, 'XXXXXXXX');
      expect(info.pid, _pid);
      expect(info.scoreList.map((e) => '${e.id} ${e.name.trim()} ${e.allowedRangeDescription} ${e.remaining}'), [
        'score2 天使币 0 ~ 10 20',
        'score4 天然 -5 ~ 15 40',
        'score5 腹黑 -5 ~ 15 40',
      ]);
      expect(info.noticeAuthorForced, isFalse);

      await getIt.unregister<NetClientProvider>();
      useForum(_FakeForum(windows: [_forcedNoticeWindow()]));
      final forced = (await RateRepository().fetchInfo(pid: _pid, rateTarget: _rateAction).run()).unwrap();
      expect(forced.noticeAuthorForced, isTrue);
    });

    test('a refused rate carries the forum message, quotes unescaped', () async {
      const quoted =
          "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<root><![CDATA[it's over<script type=\"text/javascript\" "
          "reload=\"1\">if(typeof errorhandle_rate=='function') "
          r"{errorhandle_rate('it\'s over', {});}</script>]]></root>";
      final forum = _FakeForum(
        windows: [''],
        submits: [_data('rate_submit_rejected_x5.xml'), quoted, _data('rate_submit_success_x5.xml')],
      );
      useForum(forum);
      final repo = RateRepository();

      final refused = (await repo.rate({'pid': _pid}).run()).unwrapErr();
      expect(refused, isA<RateFailedException>().having((e) => e.reason, 'reason', _refused));
      final escaped = (await repo.rate({'pid': _pid}).run()).unwrapErr();
      expect(escaped, isA<RateFailedException>().having((e) => e.reason, 'reason', "it's over"));
      expect((await repo.rate({'pid': _pid}).run()).isRight(), isTrue);
    });
  });

  group('rate page', () {
    Future<void> openRatePage(WidgetTester tester) async {
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byType(RatePostPage), findsOneWidget);
    }

    Future<void> pumpApp(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            scaffoldMessengerKey: snackbarKey,
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            const RatePostPage(username: 'Alice', pid: _pid, floor: '2', rateAction: _rateAction),
                      ),
                    ),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    Finder submitButton() => find.byType(DebounceFilledButton);

    Future<void> setScore(WidgetTester tester, String value) async {
      await tester.enterText(find.widgetWithText(TextFormField, '天使币'), value);
      await tester.pump();
    }

    Future<void> submit(WidgetTester tester) async {
      await tester.tap(submitButton());
      await tester.pumpAndSettle();
    }

    testWidgets('a refused rate keeps the form and shows the forum reason, the rate window reloads behind it', (
      tester,
    ) async {
      final forum = _FakeForum(
        windows: [_windowWithFormHash('AAAAAAAA'), _windowWithFormHash('BBBBBBBB')],
        submits: [_data('rate_submit_rejected_x5.xml'), _data('rate_submit_success_x5.xml')],
      );
      useForum(forum);
      await pumpApp(tester);
      await openRatePage(tester);
      final tr = t.ratePostPage;

      await setScore(tester, '5');
      await submit(tester);

      expect(forum.posts.single, containsPair('formhash', 'AAAAAAAA'));
      expect(find.text(_refused), findsOneWidget);
      expect(find.byType(RatePostPage), findsOneWidget);
      // Still the same form with what the user filled in, never replaced by a loading indicator.
      expect(find.widgetWithText(TextFormField, '5'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.widgetWithText(SnackBar, tr.failedToRate), findsNothing);
      // The rate window was loaded again behind the form: a new form hash and today's remaining scores.
      expect(forum.gets, hasLength(2));

      await submit(tester);
      expect(forum.posts.last, containsPair('formhash', 'BBBBBBBB'));
      expect(forum.posts.last, containsPair('score2', '5'));
      expect(find.byType(RatePostPage), findsNothing);
      expect(find.widgetWithText(SnackBar, tr.success), findsOneWidget);
    });

    testWidgets('a failed request shows the generic reason in place of the previous one', (tester) async {
      final forum = _FakeForum(
        windows: [_data('rate_window_x5.xml')],
        submits: [_data('rate_submit_rejected_x5.xml'), _FakeForum.offline],
      );
      useForum(forum);
      await pumpApp(tester);
      await openRatePage(tester);
      final tr = t.ratePostPage;

      await setScore(tester, '5');
      await submit(tester);
      expect(find.text(_refused), findsOneWidget);

      await submit(tester);
      expect(forum.posts, hasLength(2));
      expect(find.text(_refused), findsNothing);
      expect(find.text(tr.failedToRate), findsOneWidget);
      expect(find.widgetWithText(SnackBar, tr.failedToRate), findsNothing);
      expect(find.byType(RatePostPage), findsOneWidget);
      expect(find.widgetWithText(TextFormField, '5'), findsOneWidget);
    });

    testWidgets('a rate window the forum refuses still closes the page with the forum message', (tester) async {
      final forum = _FakeForum(windows: [_duplicateWindow]);
      useForum(forum);
      await pumpApp(tester);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.byType(RatePostPage), findsNothing);
      expect(find.widgetWithText(SnackBar, '抱歉，您不能对同一个帖子重复评分'), findsOneWidget);
      expect(forum.gets, hasLength(1));
      expect(forum.posts, isEmpty);
    });

    testWidgets('a reload that comes back after the next refused rate is dropped', (tester) async {
      final lateReload = Completer<void>();
      final forum = _FakeForum(
        windows: [_windowWithFormHash('AAAAAAAA'), _windowWithFormHash('BBBBBBBB'), _windowWithFormHash('CCCCCCCC')],
        submits: [
          _data('rate_submit_rejected_x5.xml'),
          _data('rate_submit_rejected_x5.xml'),
          _data('rate_submit_success_x5.xml'),
        ],
        holds: {1: lateReload},
      );
      useForum(forum);
      await pumpApp(tester);
      await openRatePage(tester);

      await setScore(tester, '5');
      // Refused, its reload (B) hangs.
      await submit(tester);
      // Refused again, its reload (C) comes back.
      await submit(tester);
      expect(forum.gets, hasLength(3));
      // The first reload comes back last.
      lateReload.complete();
      await tester.pumpAndSettle();

      await submit(tester);
      // The third rate uses the window of the second reload, not the late first one (B).
      expect(forum.posts.map((e) => e['formhash']), ['AAAAAAAA', 'AAAAAAAA', 'CCCCCCCC']);
      expect(find.byType(RatePostPage), findsNothing);
    });

    testWidgets('notify the author only when the switch is on', (tester) async {
      final forum = _FakeForum(
        windows: [_data('rate_window_x5.xml')],
        submits: [_data('rate_submit_rejected_x5.xml'), _data('rate_submit_rejected_x5.xml')],
      );
      useForum(forum);
      await pumpApp(tester);
      await openRatePage(tester);
      final tr = t.ratePostPage;

      await setScore(tester, '5');
      await submit(tester);
      expect(forum.posts.last, containsPair('sendreasonpm', 'on'));
      expect(forum.posts.last, containsPair('score2', '5'));

      // The web page sends nothing for an unchecked box; the forum notified the author for any value, even "off".
      await tester.tap(find.widgetWithText(SectionSwitchListTile, tr.noticeAuthor));
      await tester.pumpAndSettle();
      await submit(tester);
      expect(forum.posts.last.containsKey('sendreasonpm'), isFalse);
      expect(forum.posts.last, containsPair('score2', '5'));
    });

    testWidgets('when the forum always notifies, the switch says so and can not be turned off', (tester) async {
      final forum = _FakeForum(windows: [_forcedNoticeWindow()], submits: [_data('rate_submit_rejected_x5.xml')]);
      useForum(forum);
      await pumpApp(tester);
      await openRatePage(tester);
      final tr = t.ratePostPage;

      final tile = tester.widget<SectionSwitchListTile>(find.widgetWithText(SectionSwitchListTile, tr.noticeAuthor));
      expect(tile.value, isTrue);
      expect(tile.onChanged, isNull);
      expect(find.text(tr.noticeAuthorForced), findsOneWidget);

      await setScore(tester, '5');
      await submit(tester);
      expect(forum.posts.single, containsPair('sendreasonpm', 'on'));
    });

    testWidgets('the success of the previous rate does not cover the submit button of the next one', (tester) async {
      final forum = _FakeForum(
        windows: [_data('rate_window_x5.xml')],
        submits: [_data('rate_submit_success_x5.xml'), _data('rate_submit_success_x5.xml')],
      );
      useForum(forum);
      await pumpApp(tester);
      final tr = t.ratePostPage;

      await openRatePage(tester);
      await setScore(tester, '5');
      await submit(tester);
      expect(find.byType(RatePostPage), findsNothing);
      expect(find.widgetWithText(SnackBar, tr.success), findsOneWidget);

      // Rate the next post right away, well within the four seconds the snack bar stays.
      await openRatePage(tester);
      expect(find.byType(SnackBar), findsNothing);
      await setScore(tester, '3');
      await submit(tester);
      expect(forum.posts, hasLength(2));
      expect(forum.posts.last, containsPair('score2', '3'));
      expect(find.byType(RatePostPage), findsNothing);
    });

    testWidgets('other snack bars stay when a rate page opens', (tester) async {
      useForum(_FakeForum(windows: [_data('rate_window_x5.xml')]));
      await pumpApp(tester);
      // Like the session expiry notice: an action keeps it on screen until the user acts on it.
      snackbarKey.currentState!.showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: const Text('session expired'),
          action: SnackBarAction(label: 'view', onPressed: () {}),
        ),
      );
      await tester.pumpAndSettle();

      await openRatePage(tester);
      expect(find.widgetWithText(SnackBar, 'session expired'), findsOneWidget);
    });

    testWidgets('a rate success queued behind another snack bar does not cover the next rate page', (tester) async {
      final forum = _FakeForum(
        windows: [_data('rate_window_x5.xml')],
        submits: [_data('rate_submit_success_x5.xml')],
      );
      useForum(forum);
      await pumpApp(tester);
      final tr = t.ratePostPage;

      await openRatePage(tester);
      await setScore(tester, '5');
      await tester.tap(submitButton());
      // Another notice shows up while the rate is sent: the success waits behind it.
      snackbarKey.currentState!.showSnackBar(
        const SnackBar(behavior: SnackBarBehavior.floating, content: Text('other notice')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(RatePostPage), findsNothing);
      expect(find.widgetWithText(SnackBar, 'other notice'), findsOneWidget);

      await openRatePage(tester);
      // The other notice times out, the success would show now, over the submit button of this page.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(SnackBar, tr.success), findsNothing);
      expect(submitButton().hitTestable(), findsOneWidget);
    });
  });
}
