import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart' show left, right;
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/blocking/cubit/user_block_cubit.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/features/latest_thread/repository/latest_thread_repository.dart';
import 'package:tsdm_client/features/latest_thread/view/latest_thread_page.dart';
import 'package:tsdm_client/features/moderate/models/moderate_form.dart';
import 'package:tsdm_client/features/moderate/repository/moderate_repository.dart';
import 'package:tsdm_client/features/moderate/widgets/thread_picking.dart';
import 'package:tsdm_client/features/profile/utils/management_group.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/shared/repositories/fragments_repository/fragments_repository.dart';
import 'package:tsdm_client/widgets/card/thread_card/thread_card.dart';
import 'package:universal_html/parsing.dart';

/// The moderator's picking of threads on the lists of threads from several forums (the latest threads here; the search
/// and a member's threads use the same [ListThreadPicking]): offered only to an account the app knows is of a
/// management group, without a request; only the threads of one forum picked at once (the forum manages the threads
/// of the request's forum and leaves the others untouched while it says it is done); the forum page asked once for
/// what the account may do there.

const _moderator = 31;

/// The rows of `guide_new_x5.html` in forum 4, in the list's order, and one of another forum.
const _forum4 = ['1264962', '1264775', '1264485', '1264926', '1264581', '1262280', '1264956'];
const _otherForum = '1264837';

/// Author of `1264485` (forum 4), blocked in the test of the hidden threads.
const _blockedAuthor = 1105;

String _data(String name) => File('test/data/$name').readAsStringSync();

/// Never answers: avatars are not loaded in these tests.
final class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

/// Serves the captured 最新回复 page.
final class _Latest extends LatestThreadRepository {
  @override
  AsyncEither<TsdmAppPageAnswer> fetchPage(String url) =>
      AsyncEither.of(TsdmAppWebPage(parseHtmlDocument(_data('guide_new_x5.html'))));
}

/// The account in use is [uid]; [switchTo] changes it and tells it as the app does.
final class _Auth extends AuthenticationRepository {
  _Auth(this.uid);

  int? uid;
  final _statuses = StreamController<AuthStatus>.broadcast();

  @override
  int? get effectiveCurrentUid => uid;

  @override
  Stream<AuthStatus> get status => _statuses.stream;

  void switchTo(int other) {
    uid = other;
    _statuses.add(const AuthStatusUnknown());
  }

  @override
  Future<void> dispose() async {
    await _statuses.close();
  }
}

/// The forum page answer of plugin 3.8.0 for forum [fid]: the account moderates it and may close or open its threads.
Map<String, dynamic> _forumPage(int fid, {required int uid}) => {
  'ok': 1,
  'api': 1,
  'uid': uid,
  'type': 'forum',
  'schema': 2,
  'forum': {'fid': fid, 'name': 'Forum', 'ismoderator': 1},
  'perms': {'ismoderator': 1, 'allow_close': 1},
};

/// A list of [threads] (replaced by the test) picked with [ListThreadPicking], each row a plain tile.
class _Host extends StatefulWidget {
  const _Host({required this.threads, required this.repository});

  final List<ListPickableThread> threads;
  final ModerateRepository repository;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> with ListThreadPicking {
  @override
  ModerateRepository get pickingRepository => widget.repository;

  @override
  Widget build(BuildContext context) {
    watchPickingAccount(context);
    return buildPickingPopScope(
      child: Scaffold(
        appBar: buildPickingAppBar(context, widget.threads, onDone: () {}) ?? AppBar(),
        body: ListView(
          children: [
            for (final t in widget.threads)
              buildPickableCard(
                context,
                t,
                (onPick, onStartPicking) => ListTile(
                  key: ValueKey('row-${t.tid}'),
                  title: Text(t.title),
                  onTap: onPick,
                  onLongPress: onStartPicking,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

ListPickableThread _row(String tid, int fid) => (tid: tid, title: 'T$tid', fid: fid, authorUid: null, filtered: false);

void main() {
  late AppDatabase db;
  late StorageProvider storage;
  late SettingsRepository settings;
  late SettingsBloc settingsBloc;

  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.zhCn);
  });

  setUp(() async {
    ModerateRepository.resetModeratorCache();
    ManagementGroupCache.reset();
    db = AppDatabase(NativeDatabase.memory());
    storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings)
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty);
    await settings.init();
    getIt.registerSingleton<ImageCacheProvider>(
      ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _OfflineAdapter())),
    );
    settingsBloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository());
  });

  tearDown(() async {
    await settingsBloc.close();
    await getIt.get<ImageCacheProvider>().dispose();
    await getIt.reset();
    await settings.dispose();
    await db.close();
  });

  /// Every request of the management, the forum page asked for [_forumPage] and anything else failing.
  final asked = <String>[];
  final posted = <String>[];
  ModerateRepository moderation(_Auth auth) => ModerateRepository(
    get: (url) async {
      asked.add(url);
      final fid = int.tryParse(Uri.parse(url).queryParameters['fid'] ?? '');
      if (url.contains('mod=forumdisplay') && fid != null) {
        return right((statusCode: 200, data: _forumPage(fid, uid: auth.uid ?? 0)));
      }
      return left(HttpRequestFailedException(500));
    },
    post: (url, body) async {
      posted.add(url);
      return left(HttpRequestFailedException(500));
    },
    currentUid: () => auth.uid ?? 0,
  );

  Future<_Auth> pump(WidgetTester tester, {required int uid, int? blocked}) async {
    asked.clear();
    posted.clear();
    final auth = _Auth(uid);
    addTearDown(auth.dispose);
    if (blocked != null) {
      await tester.runAsync(
        () => UserBlockRepository(storage).block(ownerUid: uid, uid: blocked, username: 'u$blocked'),
      );
    }
    final cubit = UserBlockCubit(
      repository: UserBlockRepository(storage),
      currentUid: () => auth.uid,
      authStatus: auth.status,
    );
    addTearDown(cubit.close);
    await tester.runAsync(() async {
      for (var i = 0; i < 50 && !cubit.state.isKnown; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => LatestThreadPage(
            url: '$baseUrl/forum.php?mod=guide&view=new',
            repository: _Latest(),
            moderateRepository: moderation(auth),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      TranslationProvider(
        child: RepositoryProvider<AuthenticationRepository>.value(
          value: auth,
          child: BlocProvider<UserBlockCubit>.value(
            value: cubit,
            child: BlocProvider<SettingsBloc>.value(
              value: settingsBloc,
              child: MaterialApp.router(routerConfig: router),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return auth;
  }

  Finder card(String tid) => find.byWidgetPredicate((w) => w is LatestThreadCard && w.thread.threadID == tid);

  /// The context menu of [finder]: a right click here, a long press on a phone.
  Future<void> openMenu(WidgetTester tester, Finder finder) => tester.tap(finder, buttons: kSecondaryButton);

  /// Start picking with [tid] from its context menu (a long press on a phone).
  Future<void> startWith(WidgetTester tester, String tid) async {
    await openMenu(tester, card(tid));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.moderate.batch.select));
    await tester.pumpAndSettle();
  }

  Checkbox checkboxOf(WidgetTester tester, String tid) => tester.widget<Checkbox>(
    find.descendant(of: find.byKey(ValueKey('thread-picking-$tid')), matching: find.byType(Checkbox)),
  );

  group('who is offered the picking', () {
    testWidgets('an ordinary member: no picking, no request', (tester) async {
      ManagementGroupCache.remember(_moderator, value: false);
      await pump(tester, uid: _moderator);
      expect(find.byType(LatestThreadCard), findsWidgets);
      await openMenu(tester, card(_forum4.first));
      await tester.pumpAndSettle();
      expect(find.text(t.moderate.batch.select), findsNothing);
      expect(find.byType(ThreadPickingAppBar), findsNothing);
      expect(asked, isEmpty);
      expect(posted, isEmpty);
    });

    testWidgets('nothing known of the account: no picking, nothing asked to learn it', (tester) async {
      await pump(tester, uid: _moderator);
      await openMenu(tester, card(_forum4.first));
      await tester.pumpAndSettle();
      expect(find.text(t.moderate.batch.select), findsNothing);
      expect(asked, isEmpty);
      expect(ManagementGroupCache.cached(_moderator), isNull);
    });
  });

  group('a moderator', () {
    setUp(() => ManagementGroupCache.remember(_moderator, value: true));

    testWidgets('picks the threads of one forum only; nothing is asked while picking', (tester) async {
      await pump(tester, uid: _moderator);
      await startWith(tester, _forum4.first);
      expect(find.byType(ThreadPickingAppBar), findsOneWidget);
      expect(find.text(t.moderate.batch.selected(count: 1)), findsOneWidget);
      // Another forum's thread: its box can not be checked, a tap neither picks nor opens it.
      expect(checkboxOf(tester, _otherForum).onChanged, isNull);
      await tester.tap(card(_otherForum));
      await tester.pumpAndSettle();
      expect(find.text(t.moderate.batch.selected(count: 1)), findsOneWidget);
      expect(find.byType(ThreadPickingAppBar), findsOneWidget);
      // One of the same forum.
      expect(checkboxOf(tester, _forum4[1]).onChanged, isNotNull);
      await tester.tap(card(_forum4[1]));
      await tester.pumpAndSettle();
      expect(find.text(t.moderate.batch.selected(count: 2)), findsOneWidget);
      // All: those of the forum.
      await tester.tap(find.byTooltip(t.moderate.batch.selectAll));
      await tester.pumpAndSettle();
      expect(find.text(t.moderate.batch.selected(count: _forum4.length)), findsOneWidget);
      expect(checkboxOf(tester, _otherForum).value, isFalse);
      expect(asked, isEmpty);
      // Unpicking the last one stops picking: then any forum may start it.
      await tester.tap(find.byTooltip(MaterialLocalizations.of(tester.element(card(_otherForum))).closeButtonTooltip));
      await tester.pumpAndSettle();
      expect(find.byType(ThreadPickingAppBar), findsNothing);
      await startWith(tester, _otherForum);
      expect(checkboxOf(tester, _otherForum).value, isTrue);
      expect(checkboxOf(tester, _forum4.first).onChanged, isNull);
    });

    testWidgets("the forum's management of the threads picked, its page asked once for the forum", (tester) async {
      await pump(tester, uid: _moderator);
      await startWith(tester, _forum4.first);
      await tester.tap(find.byTooltip(t.moderate.batch.selectAll));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('thread-picking-moderate')));
      await tester.pumpAndSettle();
      expect(asked, hasLength(1));
      expect(asked.single, contains('mod=forumdisplay&fid=4'));
      // What the forum page told: closing and opening only.
      expect(find.text(t.moderate.close), findsOneWidget);
      expect(find.text(t.moderate.open), findsOneWidget);
      expect(find.text(t.moderate.delete), findsNothing);
      await tester.tap(find.text(t.moderate.close));
      await tester.pumpAndSettle();
      // The forum's window of the threads picked, all of forum 4.
      final window = Uri.parse(asked.last);
      expect(window.queryParameters['mod'], 'topicadmin');
      expect(window.queryParameters['fid'], '4');
      expect(window.queryParametersAll['moderate[]'], _forum4);
      expect(window.queryParametersAll['moderate[]'], isNot(contains(_otherForum)));
      expect(posted, isEmpty);
      Navigator.of(tester.element(find.byType(AlertDialog).first)).pop();
      await tester.pumpAndSettle();
      // Asked again: the forum's answer is kept.
      final before = asked.where((e) => e.contains('mod=forumdisplay')).length;
      await tester.tap(find.byKey(const ValueKey('thread-picking-moderate')));
      await tester.pumpAndSettle();
      expect(asked.where((e) => e.contains('mod=forumdisplay')), hasLength(before));
    });

    testWidgets('a thread hidden by the block list is never picked', (tester) async {
      await pump(
        tester,
        uid: _moderator,
        blocked: _blockedAuthor,
      );
      expect(find.byKey(const ValueKey('thread-picking-1264485')), findsNothing);
      await startWith(tester, _forum4.first);
      await tester.tap(find.byTooltip(t.moderate.batch.selectAll));
      await tester.pumpAndSettle();
      expect(find.text(t.moderate.batch.selected(count: _forum4.length - 1)), findsOneWidget);
      expect(find.byKey(const ValueKey('thread-picking-1264485')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('thread-picking-moderate')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.moderate.close));
      await tester.pumpAndSettle();
      expect(Uri.parse(asked.last).queryParametersAll['moderate[]'], isNot(contains('1264485')));
    });

    testWidgets('another account: what was picked is dropped', (tester) async {
      final auth = await pump(tester, uid: _moderator);
      await startWith(tester, _forum4.first);
      expect(find.byType(ThreadPickingAppBar), findsOneWidget);
      auth.switchTo(35);
      await tester.pumpAndSettle();
      expect(find.byType(ThreadPickingAppBar), findsNothing);
      // The other account is not known to manage: not offered.
      await openMenu(tester, card(_forum4.first));
      await tester.pumpAndSettle();
      expect(find.text(t.moderate.batch.select), findsNothing);
      expect(asked, isEmpty);
    });
  });

  group('the list changing while picking', () {
    setUp(() => ManagementGroupCache.remember(_moderator, value: true));

    Future<(_Auth, StateSetter)> host(
      WidgetTester tester,
      List<ListPickableThread> Function() threads,
      ModerateRepository Function(_Auth) repository,
    ) async {
      final auth = _Auth(_moderator);
      addTearDown(auth.dispose);
      late StateSetter rebuild;
      await tester.pumpWidget(
        TranslationProvider(
          child: RepositoryProvider<AuthenticationRepository>.value(
            value: auth,
            child: MaterialApp(
              home: StatefulBuilder(
                builder: (context, setState) {
                  rebuild = setState;
                  return _Host(threads: threads(), repository: repository(auth));
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return (auth, rebuild);
    }

    testWidgets('another list without the threads picked: picking stops, any forum may start it', (tester) async {
      var rows = [_row('1', 4), _row('2', 4), _row('3', 7)];
      final (auth, rebuild) = await host(tester, () => rows, moderation);
      await tester.longPress(find.byKey(const ValueKey('row-1')));
      await tester.pumpAndSettle();
      expect(find.byType(ThreadPickingAppBar), findsOneWidget);
      // Another page of the search: none of the threads picked is there.
      rebuild(() => rows = [_row('8', 7), _row('9', 4)]);
      await tester.pumpAndSettle();
      expect(find.byType(ThreadPickingAppBar), findsNothing);
      await tester.longPress(find.byKey(const ValueKey('row-8')));
      await tester.pumpAndSettle();
      expect(find.text(t.moderate.batch.selected(count: 1)), findsOneWidget);
      expect(checkboxOf(tester, '9').onChanged, isNull);
      // A refresh that keeps one of two picked: the count is what is shown.
      rebuild(() => rows = [_row('8', 7), _row('10', 7)]);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('row-10')));
      await tester.pumpAndSettle();
      expect(find.text(t.moderate.batch.selected(count: 2)), findsOneWidget);
      rebuild(() => rows = [_row('10', 7)]);
      await tester.pumpAndSettle();
      expect(find.text(t.moderate.batch.selected(count: 1)), findsOneWidget);
      // Unpicking it stops picking.
      await tester.tap(find.byKey(const ValueKey('row-10')));
      await tester.pumpAndSettle();
      expect(find.byType(ThreadPickingAppBar), findsNothing);
      expect(auth.uid, _moderator);
    });

    testWidgets('picking stopped while the forum page is asked: no management opens', (tester) async {
      final hold = Completer<void>();
      final rows = [_row('1', 4), _row('2', 4)];
      await host(
        tester,
        () => rows,
        (auth) => ModerateRepository(
          get: (url) async {
            asked.add(url);
            await hold.future;
            return right((statusCode: 200, data: _forumPage(4, uid: _moderator)));
          },
          post: (url, body) async => throw StateError('no post'),
          currentUid: () => auth.uid ?? 0,
        ),
      );
      asked.clear();
      await tester.longPress(find.byKey(const ValueKey('row-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('thread-picking-moderate')));
      await tester.pump();
      expect(asked, hasLength(1));
      await tester.tap(find.byTooltip(MaterialLocalizations.of(tester.element(find.byType(_Host))).closeButtonTooltip));
      await tester.pump();
      hold.complete();
      await tester.pumpAndSettle();
      expect(find.text(t.moderate.close), findsNothing);
      expect(find.byType(BottomSheet), findsNothing);
    });

    testWidgets('a thread unpicked while the forum page is asked is not managed', (tester) async {
      final hold = Completer<void>();
      final rows = [_row('1', 4), _row('2', 4)];
      final windows = <String>[];
      await host(
        tester,
        () => rows,
        (auth) => ModerateRepository(
          get: (url) async {
            if (url.contains('mod=forumdisplay')) {
              await hold.future;
              return right((statusCode: 200, data: _forumPage(4, uid: _moderator)));
            }
            windows.add(url);
            return left(HttpRequestFailedException(500));
          },
          post: (url, body) async => throw StateError('no post'),
          currentUid: () => auth.uid ?? 0,
        ),
      );
      await tester.longPress(find.byKey(const ValueKey('row-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('row-2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('thread-picking-moderate')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('row-2')));
      await tester.pump();
      hold.complete();
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.moderate.close));
      await tester.pumpAndSettle();
      expect(Uri.parse(windows.single).queryParametersAll['moderate[]'], ['1']);
    });
  });

  group('the forum page asked for the management', () {
    test('what the account may do comes with whether it moderates, from one request, kept', () async {
      var gets = 0;
      final auth = _Auth(_moderator);
      addTearDown(auth.dispose);
      var page = _forumPage(4, uid: _moderator);
      final repo = ModerateRepository(
        get: (url) async {
          gets++;
          return right((statusCode: 200, data: page));
        },
        post: (url, body) async => throw StateError('no post'),
        currentUid: () => auth.uid ?? 0,
      );
      final known = await repo.moderationOf(4);
      expect(known?.moderates, isTrue);
      expect(known?.perms?.allowsThread(ModerateOperation.close), isTrue);
      expect(known?.perms?.allowsThread(ModerateOperation.delete), isFalse);
      expect(await repo.isModerator(4), isTrue);
      expect(gets, 1);
      // Not a moderator there: no permissions kept, the forum refuses in its own words when asked.
      page = {
        ..._forumPage(9, uid: _moderator),
        'forum': {'fid': 9, 'name': 'Forum', 'ismoderator': 0},
        'perms': <String, dynamic>{},
      };
      final other = await repo.moderationOf(9);
      expect(other?.moderates, isFalse);
      expect(other?.perms, isNull);
      // Another account asks again.
      auth.uid = 35;
      page = _forumPage(4, uid: 35);
      await repo.moderationOf(4);
      expect(gets, 3);
    });
  });

  test('the three lists use the one picking of the moderators, the forum page its bar', () {
    String source(String path) => File(path).readAsStringSync();
    for (final page in [
      'lib/features/search/view/search_page.dart',
      'lib/features/member_thread/view/member_thread_page.dart',
      'lib/features/latest_thread/view/latest_thread_page.dart',
    ]) {
      expect(source(page), contains(RegExp('with [^{]*ListThreadPicking')), reason: page);
      expect(source(page), contains('buildPickableCard('), reason: page);
    }
    final forum = source('lib/features/forum/view/forum_page.dart');
    expect(forum, contains('ThreadPickingAppBar('));
    expect(forum, contains('PickableThreadRow('));
  });
}
