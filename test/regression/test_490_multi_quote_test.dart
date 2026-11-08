import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/bbcode_editor_controller.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/blocking/cubit/user_block_cubit.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/features/blocking/utils/thread_author_cache.dart';
import 'package:tsdm_client/features/editor/widgets/rich_editor.dart';
import 'package:tsdm_client/features/favorite/repository/favorite_repository.dart';
import 'package:tsdm_client/features/notification/bloc/notification_bloc.dart';
import 'package:tsdm_client/features/notification/bloc/notification_state_cubit.dart';
import 'package:tsdm_client/features/notification/repository/notification_info_repository.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/thread/v1/models/multi_quote_selection.dart';
import 'package:tsdm_client/features/thread/v1/view/thread_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/shared/repositories/fragments_repository/fragments_repository.dart';
import 'package:tsdm_client/widgets/card/post_card/post_card.dart';

/// Replying with the quotes of several floors: "add quote" in a floor's menu starts picking floors (a check box beside
/// each floor, the app bar tells how many are picked and offers the reply), a tap on a floor picks it or takes it back,
/// at most ten floors are picked, back (or the close button) ends picking, and the reply opens with the quote of every
/// floor picked, in the order picked, each followed by a blank line: the quote the forum's reply window gives for the
/// floor, as a reply to that floor alone puts in front of its reply.
///
/// The thread page is synthetic (grounded in the Discuz template), no real account or network.
const _alice = UserLoginInfo(username: 'Alice', uid: 1000);

/// Notification bloc holding a fixed state; the thread page only reads it.
final class _Notifications extends Fake implements NotificationBloc {
  _Notifications(this.state);

  @override
  void add(NotificationEvent event) {}

  @override
  final NotificationState state;

  @override
  Stream<NotificationState> get stream => const Stream.empty();

  @override
  bool get isClosed => false;

  @override
  Future<void> close() async {}
}

/// Never answers: avatars are not loaded in these tests.
final class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

/// The quote the forum's reply window gives for floor [floor].
String _quoteOf(int floor) => '[quote][size=2]Alice floor $floor[/size]\nquoted $floor[/quote]';

/// Serves the thread page, and the reply window of a floor (`repquote`): its quote as `noticetrimstr`.
final class _ThreadAdapter implements HttpClientAdapter {
  final windows = <String>[];

  /// Floors whose window can not be read.
  final broken = <int>{};

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    expect(options.method, 'GET', reason: 'picking quotes must never perform a forum write');
    final query = options.uri.queryParameters;
    final headers = {
      Headers.contentTypeHeader: ['text/html; charset=utf-8'],
    };
    if (query['action'] == 'reply') {
      final pid = int.parse(query['repquote']!);
      windows.add(query['repquote']!);
      if (broken.contains(pid - 9000)) {
        return ResponseBody.fromString('', 500, headers: headers);
      }
      final quote = _quoteOf(pid - 9000).replaceAll('&', '&amp;').replaceAll('"', '&quot;');
      return ResponseBody.fromString(
        '<?xml version="1.0" encoding="utf-8"?><root><![CDATA[<form><input name="formhash" value="f1f2f3f4"> '
        '<input name="noticetrimstr" value="$quote"></form>]]></root>',
        200,
        headers: headers,
      );
    }
    return ResponseBody.fromString(_threadPage(), 200, headers: headers);
  }

  @override
  void close({bool force = false}) {}
}

int _pid(int floor) => 9000 + floor;

/// A floor with its reply link: the first floor replies to the thread (no quote), the others to the floor.
String _floor(int floor) {
  final pid = _pid(floor);
  final reply = floor == 1
      ? 'forum.php?mod=post&amp;action=reply&amp;fid=2&amp;tid=1269&amp;extra=&amp;page=1'
      : 'forum.php?mod=post&amp;action=reply&amp;fid=2&amp;tid=1269&amp;repquote=$pid&amp;extra=&amp;page=1';
  return '''
<div id="post_$pid"><table><tbody><tr>
<td class="pls"></td>
<td class="plc"><div class="pi"><strong><a href="forum.php?mod=redirect&goto=findpost&pid=$pid"><em>$floor</em></a>
</strong><div class="authi"><a href="home.php?mod=space&amp;uid=1000" class="xi2">Alice</a></div></div>
<div class="pct"><div class="pcb"><div class="t_f" id="postmessage_$pid">floor $floor text</div></div></div></td>
</tr><tr><td class="pls"></td><td class="plc"><div class="po"><div class="pob cl"><em><a class="fastre" href="$reply">reply</a></em></div></div></td></tr></tbody></table></div>''';
}

String _threadPage() =>
    '''
<html><head><link rel="canonical" href="forum.php?mod=viewthread&tid=1269" /></head><body>
<input name="srhfid" value="2"><input name="posttime" value="1700000000"><input name="formhash" value="f1f2f3f4">
<input name="subject" value="s"><form id="fastpostform" action="forum.php?mod=post&action=reply&fid=2&tid=1269"><textarea name="message"></textarea></form>
<div id="postlist"><h1 class="ts"><span id="thread_subject">Quote title</span></h1><div class="bm">
${[for (var f = 1; f <= 12; f++) _floor(f)].join('\n')}
</div></div>
</body></html>''';

void main() {
  late AppDatabase db;
  late StorageProvider storage;
  late SettingsRepository settings;
  late SettingsBloc settingsBloc;
  late UserBlockRepository blocks;
  late AuthenticationRepository auth;
  late _ThreadAdapter adapter;

  group('selection', () {
    const a = MultiQuoteEntry(pid: '1', replyAction: 'a');
    const b = MultiQuoteEntry(pid: '2', replyAction: 'b');

    test('keeps the order picked, takes a floor back on the second pick, ends with nothing picked', () {
      final selection = MultiQuoteSelection();
      expect(selection.active, isFalse);
      selection.begin(b);
      expect(selection.active, isTrue);
      expect(selection.toggle(a), isTrue);
      expect([for (final e in selection.entries) e.pid], ['2', '1']);
      expect(selection.toggle(b), isTrue);
      expect([for (final e in selection.entries) e.pid], ['1']);
      expect(selection.active, isTrue, reason: 'nothing picked is still picking');
      selection.exit();
      expect(selection.active, isFalse);
      expect(selection.length, 0);
    });

    test('picks at most ten floors', () {
      final selection = MultiQuoteSelection()..begin(a);
      for (var i = 2; i <= MultiQuoteSelection.maxEntries; i++) {
        expect(selection.toggle(MultiQuoteEntry(pid: '$i', replyAction: 'x')), isTrue);
      }
      expect(selection.length, 10);
      expect(selection.toggle(const MultiQuoteEntry(pid: '99', replyAction: 'x')), isFalse);
      expect(selection.length, 10);
      expect(selection.toggle(a), isTrue, reason: 'a floor picked can still be taken back');
      expect(selection.length, 9);
    });
  });

  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
  });

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings)
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty);
    await settings.init();
    adapter = _ThreadAdapter();
    getIt
      ..registerSingleton<ImageCacheProvider>(
        ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _OfflineAdapter())),
      )
      ..registerFactory<NetClientProvider>(
        () => NetClientProvider.build(
          dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = adapter,
        ),
      );
    settingsBloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository());
    blocks = UserBlockRepository(storage);
    auth = AuthenticationRepository(user: _alice);
    ThreadAuthorCache.clear();
  });

  tearDown(() async {
    await settingsBloc.close();
    await blocks.dispose();
    await getIt.get<ImageCacheProvider>().dispose();
    await getIt.reset();
    await settings.dispose();
    await db.close();
  });

  Future<void> pump(WidgetTester tester) async {
    // Tall enough for every floor to be on screen.
    tester.view
      ..physicalSize = const Size(800, 4000)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final info = NotificationInfoRepository();
    final counts = NotificationStateCubit(info);
    final cubit = UserBlockCubit(repository: blocks, currentUid: () => _alice.uid, authStatus: auth.status);
    const thread = ThreadPage(
      threadID: '1269',
      findPostID: null,
      pageNumber: '1',
      overrideReverseOrder: false,
      overrideWithExactOrder: null,
    );
    final router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, _) => thread),
      ],
    );
    addTearDown(() async {
      router.dispose();
      await cubit.close();
      await info.dispose();
      await counts.close();
    });
    await tester.pumpWidget(
      TranslationProvider(
        child: MultiRepositoryProvider(
          providers: [
            RepositoryProvider<AuthenticationRepository>.value(value: auth),
            RepositoryProvider<FavoriteRepository>(create: (_) => FavoriteRepository()),
          ],
          child: MultiBlocProvider(
            providers: [
              BlocProvider<SettingsBloc>.value(value: settingsBloc),
              BlocProvider<UserBlockCubit>.value(value: cubit),
              BlocProvider<NotificationBloc>.value(
                value: _Notifications(const NotificationState(status: NotificationStatus.success)),
              ),
              BlocProvider<NotificationStateCubit>.value(value: counts),
            ],
            child: MaterialApp.router(routerConfig: router, scaffoldMessengerKey: snackbarKey),
          ),
        ),
      ),
    );
    await settle(tester);
  }

  Finder cardOf(int floor) =>
      find.ancestor(of: find.text('floor $floor text', findRichText: true), matching: find.byType(PostCard));
  Finder checks() => find.byType(Checkbox);
  Finder count() => find.byKey(const ValueKey('multi-quote-count'));
  Finder replyButton() => find.byKey(const ValueKey('multi-quote-reply'));

  /// Start picking from the menu of [floor].
  Future<void> startFrom(WidgetTester tester, int floor) async {
    await tester.ensureVisible(find.descendant(of: cardOf(floor), matching: find.byIcon(Icons.more_vert)));
    await tester.tap(find.descendant(of: cardOf(floor), matching: find.byIcon(Icons.more_vert)));
    await tester.pump(const Duration(milliseconds: 500));
    await settle(tester);
    await tester.tap(find.text('Add quote'));
    await tester.pump(const Duration(milliseconds: 500));
    await settle(tester);
  }

  Future<void> pick(WidgetTester tester, int floor) async {
    await tester.ensureVisible(cardOf(floor));
    await tester.tap(find.text('floor $floor text', findRichText: true), warnIfMissed: false);
    await settle(tester);
  }

  testWidgets('picking floors: the menu starts it, taps pick, the bar counts, the reply holds the quotes in order', (
    tester,
  ) async {
    await pump(tester);
    expect(checks(), findsNothing);
    expect(count(), findsNothing);

    await startFrom(tester, 3);
    expect(count(), findsOneWidget);
    expect(tester.widget<Text>(count()).data, '1/10 selected');
    expect(checks(), findsWidgets);
    expect(tester.widget<FilledButton>(replyButton()).onPressed, isNotNull);

    await pick(tester, 2);
    await pick(tester, 5);
    expect(tester.widget<Text>(count()).data, '3/10 selected');
    // A tap on a picked floor takes it back.
    await pick(tester, 2);
    expect(tester.widget<Text>(count()).data, '2/10 selected');
    await pick(tester, 2);
    expect(tester.widget<Text>(count()).data, '3/10 selected');

    await tester.tap(replyButton());
    await settle(tester);
    await settle(tester);
    expect(adapter.windows.toSet(), {'${_pid(3)}', '${_pid(5)}', '${_pid(2)}'});
    expect(count(), findsNothing, reason: 'picking ended');
    final editor = tester.widget<RichEditor>(find.byType(RichEditor)).controller;
    final code = editor.toForumBBCode();
    final at = [
      for (final f in [3, 5, 2]) code.indexOf('quoted $f'),
    ];
    expect(at.every((e) => e >= 0), isTrue, reason: code);
    expect(at, orderedEquals([...at]..sort()), reason: 'in the order picked: $code');
    expect('[quote]'.allMatches(code).length, 3);
  });

  testWidgets('the first floor has no quote to pick; back ends picking and not the page', (tester) async {
    await pump(tester);
    await tester.ensureVisible(find.descendant(of: cardOf(1), matching: find.byIcon(Icons.more_vert)));
    await tester.tap(find.descendant(of: cardOf(1), matching: find.byIcon(Icons.more_vert)));
    await tester.pump(const Duration(milliseconds: 500));
    await settle(tester);
    expect(find.text('Add quote'), findsNothing);
    await tester.tapAt(const Offset(1, 1));
    await settle(tester);

    await startFrom(tester, 2);
    expect(count(), findsOneWidget);
    await tester.binding.handlePopRoute();
    await settle(tester);
    expect(count(), findsNothing, reason: 'back ended picking');
    expect(checks(), findsNothing);
    expect(find.byType(ThreadPage), findsOneWidget);

    await startFrom(tester, 4);
    await tester.tap(find.byKey(const ValueKey('multi-quote-exit')));
    await settle(tester);
    expect(count(), findsNothing);
  });

  testWidgets('at most ten floors are picked', (tester) async {
    await pump(tester);
    await startFrom(tester, 2);
    for (var f = 3; f <= 11; f++) {
      await pick(tester, f);
    }
    expect(tester.widget<Text>(count()).data, '10/10 selected');
    await pick(tester, 12);
    expect(tester.widget<Text>(count()).data, '10/10 selected');
    expect(find.text('At most 10 floors can be quoted'), findsOneWidget);
  });

  testWidgets('a quote that can not be read puts nothing into the reply and keeps the floors picked', (tester) async {
    adapter.broken.add(4);
    await pump(tester);
    await startFrom(tester, 3);
    await pick(tester, 4);
    await tester.tap(replyButton());
    await settle(tester);
    await settle(tester);
    expect(find.text('Failed to get the quotes'), findsOneWidget);
    expect(count(), findsOneWidget);
    expect(find.byType(RichEditor), findsNothing);
  });
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 20));
  }
}
