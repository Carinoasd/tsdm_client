import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/replied_thread/cubit/replied_thread_cubit.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/thread/v1/utils/parse_thread_document.dart';
import 'package:tsdm_client/features/thread/v1/utils/replied_thread_seed.dart';
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
import 'package:tsdm_client/widgets/card/thread_card/thread_card.dart';
import 'package:tsdm_client/widgets/reply_bar/bloc/reply_bloc.dart';
import 'package:tsdm_client/widgets/reply_bar/repository/reply_repository.dart';
import 'package:universal_html/parsing.dart';

/// Issue #21: a local "already replied" mark per account and thread. It is recorded when a reply is stored, seeded
/// from the floors of the current user seen on a thread page, shown on the thread cards of the forum list, watched
/// live, and removed together with the account.
const _alice = UserLoginInfo(username: 'Alice', uid: 1000);
const _bob = UserLoginInfo(username: 'Bob', uid: 2000);

const _params = ReplyParameters(fid: '4', tid: '1264975', postTime: '1788597210', formHash: 'XXXXXXXX', subject: '  ');

/// Answers every request with the fixture [name].
final class _FixtureAdapter implements HttpClientAdapter {
  _FixtureAdapter(this.name);

  final String name;
  int requests = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (requestStream != null) {
      // Drain the form body like a server would.
      await requestStream.fold<List<int>>([], (a, b) => a..addAll(b));
    }
    requests += 1;
    return ResponseBody.fromString(
      File('test/data/$name').readAsStringSync(),
      200,
      headers: {
        Headers.contentTypeHeader: ['text/xml; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Never answers: avatars are not loaded in these tests.
final class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

/// One floor of a Discuz! X5 thread page, the author in the post header like the real page.
String _floor({required int pid, required int floor, required int uid, required String name}) =>
    '''
<div id="post_$pid"><table><tbody><tr>
<td class="pls"></td>
<td class="plc"><div class="pi"><strong><a href="forum.php?mod=redirect&goto=findpost&pid=$pid"><em>$floor</em></a>
</strong><div class="authi"><a href="home.php?mod=space&amp;uid=$uid" class="xi2">$name</a></div></div>
<div class="pct"><div class="pcb"><div class="t_f" id="postmessage_$pid">floor $floor</div></div></div></td>
</tr></tbody></table></div>''';

/// A thread page (tid 1264975 in forum 4) whose first floor is Bob's and whose second floor is Alice's reply.
final _threadPage =
    '''
<html><head><link rel="canonical" href="forum.php?mod=viewthread&tid=1264975" /></head><body>
<input type="hidden" name="srhfid" value="4" />
<div id="postlist"><div class="bm">
${_floor(pid: 1, floor: 1, uid: 2000, name: 'Bob')}
${_floor(pid: 2, floor: 2, uid: 1000, name: 'Alice')}
</div></div>
<form id="fastpostform" action="forum.php?mod=post&action=reply&fid=4&tid=1264975">
<input type="hidden" name="formhash" value="XXXXXXXX" /><input type="hidden" name="subject" value="" />
<textarea name="message"></textarea></form>
</body></html>''';

NormalThread _thread(String tid) => NormalThread(
  title: 'Thread $tid',
  url: '$baseUrl/forum.php?mod=viewthread&tid=$tid',
  threadID: tid,
  author: const User(name: 'Bob', url: '$baseUrl/home.php?mod=space&uid=2000', uid: '2000'),
  publishDate: DateTime(2026, 9),
  latestReplyAuthor: const User(name: 'Alice', url: '$baseUrl/home.php?mod=space&uid=1000', uid: '1000'),
  latestReplyTime: DateTime(2026, 9, 2, 8),
  iconUrl: '',
  threadType: null,
  replyCount: 3,
  viewCount: 30,
  price: null,
  privilege: null,
  css: null,
  stateSet: const {},
  isRecentThread: false,
);

void main() {
  late AppDatabase db;
  late StorageProvider storage;
  late SettingsRepository settings;

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
    for (final u in [_alice, _bob]) {
      await storage.saveCookie(username: u.username!, uid: u.uid!, cookie: {'Ystv_2132_auth': '${u.username}'});
    }
  });

  tearDown(() async {
    await getIt.reset();
    await settings.dispose();
    await db.close();
  });

  Future<void> record(int uid, int tid, int fid) => storage.recordRepliedThread(uid: uid, tid: tid, fid: fid);

  group('storage', () {
    test('record, fetch by account and forum, refresh without duplicates', () async {
      await record(1000, 10, 4);
      await record(1000, 11, 5);
      await record(2000, 10, 4);
      // Recorded twice: still one mark.
      await record(1000, 10, 4);

      expect(await storage.fetchRepliedTids(1000), {10, 11});
      expect(await storage.fetchRepliedTids(1000, fid: 4), {10});
      expect(await storage.fetchRepliedTids(1000, fid: 5), {11});
      expect(await storage.fetchRepliedTids(2000), {10});
      expect(await storage.fetchRepliedTids(3000), isEmpty);
    });

    test('the watch stream emits the current marks first and again after a new one', () async {
      await record(1000, 10, 4);
      final seen = <Set<int>>[];
      final sub = storage.watchRepliedTids(1000).listen(seen.add);
      while (seen.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(seen.last, {10});

      await record(1000, 12, 4);
      while (seen.length < 2) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(seen.last, {10, 12});

      // Another account's mark does not reach this stream's set.
      await record(2000, 99, 4);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(seen.last, {10, 12});
      await sub.cancel();
    });

    test('the marks go with the account, one by one or in a batch', () async {
      await record(1000, 10, 4);
      await record(2000, 10, 4);
      await record(2000, 11, 4);

      expect(await storage.deleteCookieByUid(1000), isTrue);
      expect(await storage.fetchRepliedTids(1000), isEmpty, reason: 'deleted with the account');
      expect(await storage.fetchRepliedTids(2000), {10, 11}, reason: 'other accounts keep theirs');

      expect(await storage.deleteCookiesByUids([2000]), 1);
      expect(await storage.fetchRepliedTids(2000), isEmpty);
    });
  });

  group('reply bloc', () {
    Future<ReplyState> drive(ReplyBloc bloc, ReplyEvent event) async {
      final states = <ReplyState>[];
      final sub = bloc.stream.listen(states.add);
      addTearDown(sub.cancel);
      bloc.add(event);
      for (var i = 0; i < 80 && (states.isEmpty || states.last.status == ReplyStatus.loading); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      return states.last;
    }

    ReplyBloc blocOf(AuthenticationRepository auth, String fixture) {
      final adapter = _FixtureAdapter(fixture);
      getIt.registerFactory<NetClientProvider>(
        () => NetClientProvider.build(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = adapter),
      );
      final bloc = ReplyBloc(
        replyRepository: const ReplyRepository(),
        storageProvider: storage,
        authenticationRepository: auth,
      );
      addTearDown(() async {
        await bloc.close();
        await auth.dispose();
      });
      return bloc;
    }

    test('a stored reply records the mark for the current account', () async {
      final bloc = blocOf(AuthenticationRepository(user: _alice), 'reply_success_fastpost_x5.xml');
      final state = await drive(bloc, const ReplyToThreadRequested(replyParameters: _params, replyMessage: 'hi'));
      expect(state.status, ReplyStatus.success);
      expect(await storage.fetchRepliedTids(1000), {1264975});
      expect(await storage.fetchRepliedTids(1000, fid: 4), {1264975}, reason: 'the forum comes from the parameters');
      expect(await storage.fetchRepliedTids(2000), isEmpty);
    });

    test('a rejected reply records nothing', () async {
      final bloc = blocOf(AuthenticationRepository(user: _alice), 'reply_error_flood_x5.xml');
      final state = await drive(bloc, const ReplyToThreadRequested(replyParameters: _params, replyMessage: 'hi'));
      expect(state.status, ReplyStatus.failure);
      expect(await storage.fetchRepliedTids(1000), isEmpty);
    });

    test('a stored reply without a logged user records nothing', () async {
      final bloc = blocOf(AuthenticationRepository(), 'reply_success_fastpost_x5.xml');
      final state = await drive(bloc, const ReplyToThreadRequested(replyParameters: _params, replyMessage: 'hi'));
      expect(state.status, ReplyStatus.success);
      expect(await storage.fetchRepliedTids(1000), isEmpty);
      expect(await storage.fetchRepliedTids(2000), isEmpty);
    });
  });

  group('seeding from a thread page', () {
    test('a floor of the current user other than the first one marks the thread', () async {
      final info = parseThreadDocument(parseHtmlDocument(_threadPage), 1);
      expect(info.tid, '1264975');
      expect(info.fid, 4);
      expect(info.postList.map((e) => (e.postFloor, e.author.uid)), [(1, '2000'), (2, '1000')]);

      expect(hasReplyBy(info.postList, 1000), isTrue);
      expect(hasReplyBy(info.postList, 2000), isFalse, reason: 'the first floor is the thread, not a reply');
      expect(hasReplyBy(info.postList, 3000), isFalse);

      final seeded = await seedRepliedThreadFromPosts(
        storageProvider: storage,
        uid: 1000,
        tid: info.tid,
        fid: info.fid,
        posts: info.postList,
      );
      expect(seeded, isTrue);
      expect(await storage.fetchRepliedTids(1000, fid: 4), {1264975});

      // The thread author only opened it.
      expect(
        await seedRepliedThreadFromPosts(
          storageProvider: storage,
          uid: 2000,
          tid: info.tid,
          fid: info.fid,
          posts: info.postList,
        ),
        isFalse,
      );
      expect(await storage.fetchRepliedTids(2000), isEmpty);
    });

    test('nothing is recorded while the user, the thread or the forum is unknown', () async {
      final posts = parseThreadDocument(parseHtmlDocument(_threadPage), 1).postList;
      for (final (uid, tid, fid) in [(null, '1264975', 4), (1000, null, 4), (1000, 'x', 4), (1000, '1264975', null)]) {
        expect(
          await seedRepliedThreadFromPosts(storageProvider: storage, uid: uid, tid: tid, fid: fid, posts: posts),
          isFalse,
          reason: 'uid=$uid tid=$tid fid=$fid',
        );
      }
      expect(await storage.fetchRepliedTids(1000), isEmpty);
    });
  });

  testWidgets(
    'the thread card marks a replied thread, not another, and follows the marks live',
    (tester) async {
      getIt.registerSingleton<ImageCacheProvider>(
        ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _OfflineAdapter())),
      );
      addTearDown(() async => getIt.get<ImageCacheProvider>().dispose());

      // The database is only used from the real zone (runAsync): drift fetches and drops its streams through timers,
      // and a database timer left in the fake zone, or a fake-zone continuation of a real one, never runs and hangs
      // the tear-down's database close.
      // Both blocs are built in the real zone as well: a bloc's own subscriptions live in the zone it was built in
      // and its close waits for their done events, which never arrive across zones.
      final (cubit, settingsBloc) = (await tester.runAsync(() async {
        await record(1000, 10, 4);
        final cubit = RepliedThreadCubit(storageProvider: storage, uid: 1000);
        for (var i = 0; i < 100 && cubit.state.isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        return (cubit, SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository()));
      }))!;
      expect(cubit.state, {10}, reason: 'the marks are loaded from the database');

      await tester.runAsync(() async {
        await tester.pumpWidget(
          TranslationProvider(
            child: MultiBlocProvider(
              providers: [
                BlocProvider<SettingsBloc>.value(value: settingsBloc),
                BlocProvider<RepliedThreadCubit>.value(value: cubit),
              ],
              child: MaterialApp(
                home: Scaffold(
                  body: ListView(
                    children: [
                      NormalThreadCard(_thread('10'), disableTap: true),
                      NormalThreadCard(_thread('11'), disableTap: true),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        for (var i = 0; i < 10; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump(const Duration(milliseconds: 20));
        }
      });

      expect(find.text('Thread 10'), findsOneWidget);
      expect(find.text('Thread 11'), findsOneWidget);
      expect(find.byIcon(Icons.reply_outlined), findsOneWidget);
      expect(find.byTooltip('Replied'), findsOneWidget);
      final marked = tester.widget<NormalThreadCard>(
        find.ancestor(of: find.byIcon(Icons.reply_outlined), matching: find.byType(NormalThreadCard)),
      );
      expect(marked.thread.threadID, '10');

      // A reply in the other thread: its card gets the mark without a reload.
      await tester.runAsync(() async {
        await record(1000, 11, 4);
        for (var i = 0; i < 100 && cubit.state.length < 2; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        await tester.pump();
      });
      expect(cubit.state, {10, 11});
      expect(find.byIcon(Icons.reply_outlined), findsNWidgets(2));

      // Outside the app tree (no cubit above): no mark and no error.
      await tester.runAsync(() async {
        await tester.pumpWidget(
          TranslationProvider(
            child: BlocProvider<SettingsBloc>.value(
              value: settingsBloc,
              child: MaterialApp(home: Scaffold(body: NormalThreadCard(_thread('10'), disableTap: true))),
            ),
          ),
        );
        for (var i = 0; i < 5; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump(const Duration(milliseconds: 20));
        }
      });
      expect(find.text('Thread 10'), findsOneWidget);
      expect(find.byIcon(Icons.reply_outlined), findsNothing);
      expect(tester.takeException(), isNull);

      // Unmount and close in the same real zone: the bloc close waits for the tree's subscriptions to end, and drift
      // drops the cancelled stream through a zero timer, neither of which runs across zones. Then let the remaining
      // timers fire before the framework checks for pending timers.
      await tester.runAsync(() async {
        await tester.pumpWidget(const SizedBox());
        await cubit.close();
        await settingsBloc.close();
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump(const Duration(seconds: 5));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
