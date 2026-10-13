import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bbcode_editor/flutter_bbcode_editor.dart' show BBCodeExt;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart' hide State;
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/blocking/cubit/user_block_cubit.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/features/blocking/utils/thread_author_cache.dart';
import 'package:tsdm_client/features/checkin/bloc/auto_checkin_bloc.dart';
import 'package:tsdm_client/features/checkin/repository/auto_checkin_repository.dart';
import 'package:tsdm_client/features/editor/widgets/rich_editor.dart';
import 'package:tsdm_client/features/favorite/repository/favorite_repository.dart';
import 'package:tsdm_client/features/forum/bloc/forum_bloc.dart';
import 'package:tsdm_client/features/forum/bloc/forum_group_bloc.dart';
import 'package:tsdm_client/features/forum/models/models.dart';
import 'package:tsdm_client/features/forum/repository/forum_repository.dart';
import 'package:tsdm_client/features/forum/utils/group.dart';
import 'package:tsdm_client/features/forum/view/forum_group_page.dart';
import 'package:tsdm_client/features/forum/view/forum_page.dart';
import 'package:tsdm_client/features/homepage/widgets/user_operation_dialog.dart';
import 'package:tsdm_client/features/multi_user/bloc/switch_user_bloc.dart';
import 'package:tsdm_client/features/multi_user/cubit/current_account_cubit.dart';
import 'package:tsdm_client/features/multi_user/utils/switch_account.dart';
import 'package:tsdm_client/features/multi_user/view/manage_account_page.dart';
import 'package:tsdm_client/features/multi_user/widgets/current_account_avatar.dart';
import 'package:tsdm_client/features/notification/bloc/auto_notification_cubit.dart';
import 'package:tsdm_client/features/notification/bloc/notification_bloc.dart';
import 'package:tsdm_client/features/notification/bloc/notification_state_cubit.dart';
import 'package:tsdm_client/features/notification/bloc/notification_sync_all_cubit.dart';
import 'package:tsdm_client/features/notification/repository/notification_info_repository.dart';
import 'package:tsdm_client/features/notification/repository/notification_repository.dart';
import 'package:tsdm_client/features/notification/repository/notification_sync_all_repository.dart';
import 'package:tsdm_client/features/profile/repository/profile_repository.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/thread/v1/bloc/thread_bloc.dart';
import 'package:tsdm_client/features/thread/v1/repository/thread_repository.dart';
import 'package:tsdm_client/features/thread/v1/view/thread_page.dart';
import 'package:tsdm_client/features/thread/v1/widgets/post_list.dart';
import 'package:tsdm_client/features/thread_visit_history/bloc/thread_visit_history_bloc.dart';
import 'package:tsdm_client/features/thread_visit_history/repository/thread_visit_history_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
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
import 'package:tsdm_client/widgets/heroes.dart';
import 'package:tsdm_client/widgets/reply_bar/bloc/reply_bloc.dart';
import 'package:tsdm_client/widgets/reply_bar/repository/reply_repository.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

/// Roadmap item 2, follow-up of GitHub #184: the avatar menu lists the other saved accounts and switches with one tap.
/// The manage accounts page switches through the same helper (`switchAccount`): one switch at a time, the in-app
/// notification sync paused around it and always resumed (leaving the page while switching left it paused), a toast
/// when that sync is busy, no switch while a reply is sent on any page. The profile page cache follows the account,
/// and the thread page reloads for the new account (once shown, on the page being read) without losing an unsent
/// reply. A thread load still pending for the previous account is superseded by that reload: its answer, or the
/// failure its dropped request ends with, never reaches the page (every floor showed twice, with "failed to load").
/// The forum and forum group pages load again for the new account as well, once shown.
///
/// The forum pages are synthetic (grounded in the Discuz templates), no real account or network.
const _alice = UserLoginInfo(username: 'Alice', uid: 1000);
const _bob = UserLoginInfo(username: 'Bob', uid: 1001);
const _carol = UserLoginInfo(username: 'Carol', uid: 1002);

/// The check page as served to a logged-in [user].
String _authedPage(UserLoginInfo user) =>
    '<html><body><div id="inner_stat"><strong><a href="home.php?mod=space&amp;uid=${user.uid}">${user.username}</a> '
    '</strong></div><input type="hidden" name="formhash" value="XXXXXXXX" /></body></html>';

/// What the forum renders for a guest: the login form, no user node.
const _guestPage =
    '<html><body><form id="lsform" method="post"><input type="hidden" name="formhash" value="XXXXXXXX" /> '
    '<input name="username" /></form><div id="messagetext"><p>请先登录后才能继续浏览</p></div></body></html>';

/// Cookie row in the format the persistent cookie jar reads back: the auth cookie is sent with every request.
Map<String, String> _cookieOf(UserLoginInfo user) => {
  '.index': '["$baseHost"]',
  baseHost: '{"/":{"Ystv_2132_auth":"Ystv_2132_auth=${user.username!.toLowerCase()}; Path=/;_crt=1"}}',
};

/// The forum as seen by the isolated client of the switch: [body] for every request, once [gate] completes.
final class _SwitchAdapter implements HttpClientAdapter {
  String body = _authedPage(_bob);
  Completer<void>? gate;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (gate != null) {
      await gate!.future;
    }
    return ResponseBody.fromString(
      body,
      200,
      headers: {
        Headers.contentTypeHeader: ['text/html; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Avatars are not downloaded in tests.
final class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

/// The profile page of the uid asked for, once [gate] completes; records the uids asked for.
final class _ProfileAdapter implements HttpClientAdapter {
  Completer<void>? gate;
  final uids = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final uid = options.uri.queryParameters['uid'] ?? '';
    uids.add(uid);
    if (gate != null) {
      await gate!.future;
    }
    return ResponseBody.fromString(
      '<html><body><div id="ct">profile of $uid</div></body></html>',
      200,
      headers: {
        Headers.contentTypeHeader: ['text/html; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// A thread page holding floor [floor] (floor 1 by default), open for replies with [formHash], [breadcrumb] above it.
String _threadHtml(String formHash, {int floor = 1, String breadcrumb = ''}) =>
    '''
<html><head><link rel="canonical" href="forum.php?mod=viewthread&tid=1264975" /></head><body>
$breadcrumb
<div id="postlist"><h1 class="ts"><span id="thread_subject">Switch title</span></h1><div class="bm">
<div id="post_$floor"><table><tbody><tr>
<td class="pls"></td>
<td class="plc"><div class="pi"><strong><a href="forum.php?mod=redirect&goto=findpost&pid=$floor"><em>$floor</em></a>
</strong><div class="authi"><a href="home.php?mod=space&amp;uid=1000" class="xi2">Alice</a></div></div>
<div class="pct"><div class="pcb"><div class="t_f" id="postmessage_$floor">floor $floor text</div></div></div></td>
</tr></tbody></table></div>
</div></div>
<form method="post" id="fastpostform" action="forum.php?mod=post&amp;action=reply&amp;fid=2&amp;tid=1264975&amp;replysubmit=yes">
<input type="hidden" name="formhash" value="$formHash" />
<input type="hidden" name="posttime" value="1760000000" />
<input type="hidden" name="subject" value="" />
<div class="area"><textarea name="message"></textarea></div>
</form>
</body></html>''';

/// One thread page with one floor, open for replies, for every request; counts the thread loads.
///
/// The reply form carries a formhash of the account whose cookie came with the request, like the forum's.
final class _ThreadAdapter implements HttpClientAdapter {
  int requests = 0;

  /// The `page` asked for by every thread load.
  final pages = <String?>[];

  /// Holds the answers back while set.
  Completer<void>? gate;

  /// With the forum path above the thread: the page then records the visit of the account in use.
  bool breadcrumb = false;

  /// Alice may not read the thread: she gets the login page.
  bool aliceNeedsLogin = false;

  static const _loginPage =
      '<html><body><div id="messagetext"><p>login</p></div><div id="messagelogin"><form id="lsform"></form></div> '
      '</body></html>';

  static const _breadcrumb =
      '<div id="pt"><a href="forum.php">Home</a><a href="forum.php?mod=forumdisplay&amp;fid=2">SomeForum</a> '
      '<a href="forum.php?mod=viewthread&amp;tid=1264975">Switch title</a></div>';

  String _page(String formHash) => _threadHtml(formHash, breadcrumb: breadcrumb ? _breadcrumb : '');

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    expect(options.method, 'GET', reason: 'never a forum write');
    if (options.uri.queryParameters['mod'] == 'viewthread') {
      requests++;
      pages.add(options.uri.queryParameters['page']);
    }
    if (gate != null) {
      await gate!.future;
    }
    final cookie = '${options.headers['cookie'] ?? options.headers['Cookie'] ?? ''}';
    if (aliceNeedsLogin && !cookie.contains('auth=bob')) {
      return ResponseBody.fromString(
        _loginPage,
        200,
        headers: {
          Headers.contentTypeHeader: ['text/html; charset=utf-8'],
        },
      );
    }
    final formHash = cookie.contains('auth=bob')
        ? 'hashOfBob'
        : (cookie.contains('auth=alice') ? 'hashOfAlice' : 'none');
    return ResponseBody.fromString(
      _page(formHash),
      200,
      headers: {
        Headers.contentTypeHeader: ['text/html; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Thread loads the test answers one by one: every load waits for an answer of its own.
final class _HeldThreadRepository extends Fake implements ThreadRepository {
  /// The answer of every load, in the order asked.
  final answers = <Completer<Either<AppException, uh.Document>>>[];

  /// The page asked for by every load.
  final pages = <int>[];

  @override
  AsyncEither<uh.Document> fetchThread({
    String? tid,
    String? pid,
    int pageNumber = 1,
    String? onlyVisibleUid,
    bool? reverseOrder,
    int? exactOrder,
  }) {
    final answer = Completer<Either<AppException, uh.Document>>();
    answers.add(answer);
    pages.add(pageNumber);
    return AsyncEither(() => answer.future);
  }
}

/// A forum without threads whose only sub forum is [board].
String _subForumsPage(String board) =>
    '''
<html><body><div id="ct" class="wp cl"><div class="bm bml pbn"><div class="bm_h cl"><h1 class="xs2">
<a href="forum.php?mod=forumdisplay&amp;fid=73">SomeForum</a></h1></div></div>
<div class="bm bmw"><div id="subforum_73" class="bm_c"><table class="fl_tb"><tr><td class="fl_icn"></td>
<td><h2><a href="forum.php?mod=forumdisplay&amp;fid=2000">$board</a></h2></td>
<td class="fl_i"><span class="xi2">1</span><span class="xg1"> / 2</span></td></tr><tr class="fl_row"></tr>
</table></div></div></div></body></html>''';

/// The forum index with group 1 holding [board] only.
String _groupHtml(String board) =>
    '''
<html><body><div id="ct"><div class="mn"><div class="fl bm"><div class="bm bmw  cl"><div class="bm_h cl">
<h2><a href="forum.php?gid=1">SomeGroup</a></h2></div><div id="category_1" class="bm_c"><table class="fl_tb">
<tr><td class="fl_icn"></td><td><h2><a href="forum.php?mod=forumdisplay&amp;fid=2000">$board</a></h2></td>
<td class="fl_i"><span class="xi2">1</span><span class="xg1"> / 2</span></td></tr>
<tr class="fl_row"></tr></table></div></div></div></div></div></body></html>''';

/// The boards the account in use may see, in a forum and in a forum group: "Alice board" for Alice, "Bob board" for
/// Bob, as of when the request goes out. Answers once [gate] completes; records every load.
final class _BoardsRepository implements ForumRepository {
  _BoardsRepository(this._uid);

  final int? Function() _uid;

  /// Holds the answers back while set.
  Completer<void>? gate;

  /// The filter of every forum load.
  final forumLoads = <FilterState>[];

  int groupLoads = 0;

  String _board() => _uid() == _bob.uid ? 'Bob board' : 'Alice board';

  @override
  AsyncEither<uh.Document> fetchForum({required String fid, required FilterState filterState, int pageNumber = 1}) =>
      AsyncEither(() async {
        forumLoads.add(filterState);
        final board = _board();
        await gate?.future;
        return right(parseHtmlDocument(_subForumsPage(board)));
      });

  @override
  AsyncEither<ForumGroup?> fetchForumGroup(String gid) => AsyncEither(() async {
    groupLoads++;
    final board = _board();
    await gate?.future;
    return right(buildGroupListFromDocument(parseHtmlDocument(_groupHtml(board))).firstOrNull);
  });
}

/// Notification bloc holding a fixed state; the thread page only reads it.
final class _Notifications extends Fake implements NotificationBloc {
  @override
  void add(NotificationEvent event) {}

  @override
  NotificationState get state => const NotificationState(status: NotificationStatus.success);

  @override
  Stream<NotificationState> get stream => const Stream.empty();

  @override
  bool get isClosed => false;

  @override
  Future<void> close() async {}
}

/// The forum taking a reply: answers once [gate] completes, refusing it; counts the replies sent.
final class _ReplyAdapter implements HttpClientAdapter {
  final gate = Completer<void>();
  int posts = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    posts++;
    await gate.future;
    return ResponseBody.fromString(
      "<script>errorhandle_fastpost('closed', {});</script>",
      200,
      headers: {
        Headers.contentTypeHeader: ['text/html; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Frames with real time in between: the database and its streams answer on the real event loop.
Future<void> _settle(WidgetTester tester, {int rounds = 8}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Lets the snack bar and the database stream timers fire before the framework checks for pending timers.
Future<void> _dispose(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 5));
}

/// The homepage app bar, reduced to the avatar that opens the menu the way the real one does.
class _Home extends StatelessWidget {
  const _Home();

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      actions: [
        IconButton(
          key: const ValueKey('home-avatar'),
          icon: const Icon(Icons.person),
          onPressed: () async => showHeroDialog<void>(
            context,
            (context, _, _) =>
                const UserOperationDialog(username: 'Alice', avatarUrl: null, heroTag: 'Alice', latestThreadUrl: null),
          ),
        ),
      ],
    ),
    body: const Center(child: Text('homepage')),
  );
}

void main() {
  late AppDatabase db;
  late StorageProvider storage;
  late SettingsRepository settings;
  late AuthenticationRepository auth;
  late _SwitchAdapter forum;

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
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
      ..registerSingleton<ImageCacheProvider>(
        ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _OfflineAdapter())),
      );
    await settings.init();
    // Alice is logged in on this device.
    await storage.saveCookie(username: 'Alice', uid: 1000, cookie: _cookieOf(_alice));
    await settings.setValue<int>(SettingsKeys.loginUid, 1000);
    await settings.setValue<String>(SettingsKeys.loginUsername, 'Alice');
    getIt.registerSingleton<CookieProvider>(CookieProvider(_alice, _cookieOf(_alice)));
    forum = _SwitchAdapter();
    auth = AuthenticationRepository(
      user: _alice,
      clientFactory: (cookie) => NetClientProvider.buildNoCookie(
        dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum,
        cookie: cookie,
      ),
    );
  });

  tearDown(() async {
    await auth.dispose();
    await getIt.get<ImageCacheProvider>().dispose();
    await getIt.reset();
    await settings.dispose();
    await db.close();
  });

  Future<void> saveAccounts(List<UserLoginInfo> users) async {
    for (final u in users) {
      await storage.saveCookie(username: u.username!, uid: u.uid!, cookie: _cookieOf(u));
    }
  }

  int? cookieUid() => getIt.get<CookieProvider>().userLoginInfo.uid;

  /// The in-app notification sync of the app, ticking; built in the test zone so its timer runs on the pumps.
  AutoNotificationCubit autoSync() {
    final notifications = NotificationRepository();
    final auto = AutoNotificationCubit(
      authenticationRepository: auth,
      notificationRepository: notifications,
      storageProvider: storage,
    )..start(const Duration(hours: 1));
    addTearDown(() async {
      await auto.close();
      await notifications.dispose();
    });
    return auto;
  }

  /// Whether the sync ticks: a resumed sync restarts its timer and says so on the next second.
  Future<void> expectTicking(WidgetTester tester, AutoNotificationCubit auto) async {
    await tester.pump(const Duration(seconds: 1));
    expect(auto.state, isA<AutoNoticeStateTicking>(), reason: 'the in-app notification sync runs again');
  }

  /// A reply sent from some thread page, held by the forum until [_ReplyAdapter.gate] completes.
  Future<(ReplyBloc, _ReplyAdapter)> sendReply(WidgetTester tester) async {
    final replies = _ReplyAdapter();
    getIt.registerFactory<NetClientProvider>(
      () => NetClientProvider.buildNoCookie(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = replies),
    );
    final bloc = ReplyBloc(replyRepository: const ReplyRepository())
      ..add(
        const ReplyToThreadRequested(
          replyParameters: ReplyParameters(fid: '2', tid: '1264975', postTime: null, formHash: 'x', subject: ''),
          replyMessage: 'a reply',
        ),
      );
    addTearDown(bloc.close);
    // Runs first: a failed test does not leave the reply hanging.
    addTearDown(() {
      if (!replies.gate.isCompleted) {
        replies.gate.complete();
      }
    });
    await _settle(tester, rounds: 2);
    expect(replies.posts, 1);
    expect(ReplyBloc.sendingAny, isTrue);
    return (bloc, replies);
  }

  /// The forum answered [reply]: nothing is being sent any more.
  Future<void> replyAnswered(WidgetTester tester, (ReplyBloc, _ReplyAdapter) reply) async {
    reply.$2.gate.complete();
    await _settle(tester, rounds: 2);
    expect(reply.$1.state.status, ReplyStatus.failure);
    expect(ReplyBloc.sendingAny, isFalse);
  }

  Finder row(UserLoginInfo user) => find.byKey(ValueKey('quick-switch-${user.uid}'));
  final dialog = find.byType(UserOperationDialog);

  group('avatar menu', () {
    late AutoNotificationCubit auto;

    /// [home] with the providers of the app and the routes the menu opens.
    Future<void> pumpHome(
      WidgetTester tester, {
      Widget home = const _Home(),
      CurrentAccountCubit? accounts,
    }) async {
      auto = autoSync();
      final router = GoRouter(
        routes: [
          GoRoute(path: '/', builder: (_, _) => home),
          GoRoute(
            path: ScreenPaths.manageAccount,
            name: ScreenPaths.manageAccount,
            builder: (_, _) => const Scaffold(body: Center(child: Text('manage account page'))),
          ),
          GoRoute(
            path: ScreenPaths.login,
            name: ScreenPaths.login,
            builder: (_, state) =>
                Scaffold(body: Center(child: Text('login ${state.uri.queryParameters['username']}'))),
          ),
        ],
      );
      addTearDown(router.dispose);
      Widget app = MaterialApp.router(routerConfig: router, scaffoldMessengerKey: snackbarKey);
      if (accounts != null) {
        app = BlocProvider<CurrentAccountCubit>.value(value: accounts, child: app);
      }
      await tester.pumpWidget(
        TranslationProvider(
          child: RepositoryProvider<AuthenticationRepository>.value(
            value: auth,
            child: BlocProvider<AutoNotificationCubit>.value(value: auto, child: app),
          ),
        ),
      );
      await _settle(tester);
      await expectTicking(tester, auto);
    }

    Future<void> openMenu(WidgetTester tester, {Finder? button}) async {
      await tester.tap(button ?? find.byKey(const ValueKey('home-avatar')));
      await _settle(tester);
      expect(dialog, findsOneWidget);
    }

    Future<void> finish(WidgetTester tester) async {
      auto.stop();
      await _dispose(tester);
    }

    testWidgets('a single saved account: no account list, the menu is as before', (tester) async {
      await pumpHome(tester);
      await openMenu(tester);

      expect(find.text(t.manageAccountPage.switchAccount.title), findsNothing);
      expect(find.byType(HeroUserAvatar), findsOneWidget, reason: 'only the avatar of the title');
      final entries = tester.widgetList<ListTile>(find.descendant(of: dialog, matching: find.byType(ListTile)));
      expect(entries, hasLength(7), reason: 'profile, medals, history, threads, favorites, manage, latest');
      expect(tester.takeException(), isNull);
      await finish(tester);
    });

    testWidgets('lists the other accounts above the menu, never the current one', (tester) async {
      await saveAccounts([_bob, _carol]);
      await pumpHome(tester);
      await openMenu(tester);

      expect(find.text(t.manageAccountPage.switchAccount.title), findsOneWidget);
      expect(row(_alice), findsNothing, reason: 'the account in use is the title');
      expect(find.descendant(of: dialog, matching: find.text('Alice')), findsOneWidget);
      expect(row(_bob), findsOneWidget);
      expect(row(_carol), findsOneWidget);
      // Same order as the manage accounts page, above the entries of the account in use.
      expect(tester.getTopLeft(row(_bob)).dy, lessThan(tester.getTopLeft(row(_carol)).dy));
      final profile = find.widgetWithText(ListTile, t.profilePage.title);
      expect(tester.getTopLeft(row(_carol)).dy, lessThan(tester.getTopLeft(profile).dy));

      final avatar = find.descendant(of: row(_bob), matching: find.byType(HeroUserAvatar));
      expect(tester.getSize(avatar), const Size(32, 32));
      expect(tester.widget<HeroUserAvatar>(avatar).disableHero, isTrue, reason: 'the title avatar is the hero');
      expect(tester.widget<HeroUserAvatar>(avatar).avatarUrl, avatarUrlOfUid('1001'));
      expect(tester.takeException(), isNull);
      await finish(tester);
    });

    testWidgets('more than four other accounts: four rows and a row to the manage accounts page', (tester) async {
      final others = [for (var i = 0; i < 6; i++) UserLoginInfo(username: 'U$i', uid: 2000 + i)];
      await saveAccounts(others);
      await pumpHome(tester);
      await openMenu(tester);

      for (final u in others.take(4)) {
        expect(row(u), findsOneWidget);
      }
      expect(row(others[4]), findsNothing);
      expect(row(others[5]), findsNothing);
      final more = find.text(t.currentAccount.moreAccounts(count: 2));
      expect(more, findsOneWidget);
      expect(find.text('2 more account(s)'), findsOneWidget);

      await tester.ensureVisible(more);
      await tester.tap(more);
      await _settle(tester);
      expect(dialog, findsNothing);
      expect(find.text('manage account page'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('a tap switches: cookie and settings name the account, the menu closes with a toast', (tester) async {
      await saveAccounts([_bob, _carol]);
      await pumpHome(tester);
      await openMenu(tester);

      await tester.tap(row(_bob));
      await _settle(tester);

      expect(forum.requests, hasLength(1), reason: 'one check of the stored login');
      expect(cookieUid(), 1001);
      expect(settings.currentSettings.loginUid, 1001);
      expect(settings.currentSettings.loginUsername, 'Bob');
      expect(auth.currentUser?.uid, 1001);
      expect(dialog, findsNothing);
      expect(find.text('Switched to Bob'), findsOneWidget);
      expect(isSwitchingAccount, isFalse);
      await expectTicking(tester, auto);
      await finish(tester);
    });

    testWidgets('a guest page: the menu stays open, says the login expired and marks the row', (tester) async {
      await saveAccounts([_bob]);
      forum.body = _guestPage;
      await pumpHome(tester);
      await openMenu(tester);
      expect(
        find.descendant(of: row(_bob), matching: find.text(t.manageAccountPage.sessionExpired.hint)),
        findsNothing,
      );

      await tester.tap(row(_bob));
      await _settle(tester);

      expect(dialog, findsOneWidget);
      expect(find.text(t.loginPage.perhapsExpired), findsOneWidget);
      expect(cookieUid(), 1000, reason: 'Alice stays');
      expect(settings.currentSettings.loginUid, 1000);
      expect(
        find.descendant(of: row(_bob), matching: find.text(t.manageAccountPage.sessionExpired.hint)),
        findsOneWidget,
      );
      await expectTicking(tester, auto);

      // An expired login is not switched to: the login page opens with the name.
      await tester.tap(row(_bob));
      await _settle(tester);
      expect(dialog, findsNothing);
      expect(find.text('login Bob'), findsOneWidget);
      expect(forum.requests, hasLength(1));
      await finish(tester);
    });

    testWidgets('the notification sync keeps fetching: no switch, a toast says to try again', (tester) async {
      await saveAccounts([_bob]);
      await pumpHome(tester);
      await openMenu(tester);

      // A fetch in flight.
      auto.emit(AutoNoticeStatePending(DateTime.now()));
      await tester.tap(row(_bob));
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }

      expect(find.text(t.currentAccount.switchBusy), findsOneWidget);
      expect(find.text('Notifications are syncing, try again in a moment'), findsOneWidget);
      expect(forum.requests, isEmpty);
      expect(cookieUid(), 1000);
      expect(dialog, findsOneWidget);
      expect(tester.widget<ListTile>(row(_bob)).enabled, isTrue, reason: 'can be tried again');

      // The fetch ended: nothing of the switch holds the sync, and the next tap switches.
      auto.emit(const AutoNoticeStateTicking(total: Duration(hours: 1), remain: Duration(minutes: 59)));
      await expectTicking(tester, auto);
      await tester.tap(row(_bob));
      await _settle(tester);
      expect(cookieUid(), 1001);
      expect(dialog, findsNothing);
      await expectTicking(tester, auto);
      await finish(tester);
    });

    testWidgets('cannot be dismissed while switching, and every entry waits', (tester) async {
      await saveAccounts([_bob, _carol]);
      forum.gate = Completer<void>();
      await pumpHome(tester);
      await openMenu(tester);

      await tester.tap(row(_bob));
      await _settle(tester, rounds: 3);
      expect(forum.requests, hasLength(1));
      expect(auto.state, isA<AutoNoticeStatePaused>(), reason: 'paused while switching');
      expect(find.descendant(of: row(_bob), matching: find.byType(CircularProgressIndicator)), findsOneWidget);

      // Neither the barrier nor back closes it.
      await tester.tapAt(const Offset(5, 590));
      await tester.pump();
      expect(dialog, findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(dialog, findsOneWidget);
      expect(tester.widget<ListTile>(find.widgetWithText(ListTile, t.profilePage.title)).enabled, isFalse);
      expect(tester.widget<ListTile>(row(_carol)).enabled, isFalse);
      await tester.tap(row(_carol), warnIfMissed: false);
      await tester.pump();
      expect(forum.requests, hasLength(1), reason: 'no second switch');

      forum.gate!.complete();
      await _settle(tester);
      expect(cookieUid(), 1001);
      expect(dialog, findsNothing);
      await expectTicking(tester, auto);
      await finish(tester);
    });

    testWidgets('the app bar avatar of a page sending a reply: the switch is refused', (tester) async {
      await saveAccounts([_bob]);
      final accounts = CurrentAccountCubit(
        currentUser: () => auth.effectiveCurrentUser,
        authStatus: auth.status,
        accounts: storage.allUsersStream(),
      );
      addTearDown(accounts.close);
      await pumpHome(
        tester,
        accounts: accounts,
        home: Scaffold(
          appBar: AppBar(title: const Text('thread'), actions: const [CurrentAccountAvatarButton()]),
        ),
      );
      final reply = await sendReply(tester);
      final button = find.byKey(const ValueKey('current_account_avatar_button'));
      expect(button, findsOneWidget);
      await openMenu(tester, button: button);
      expect(row(_bob), findsOneWidget, reason: 'the app bar avatar opens the same list');

      await tester.tap(row(_bob));
      await _settle(tester);
      expect(find.text(t.currentAccount.replyBusy), findsOneWidget);
      expect(forum.requests, isEmpty, reason: 'the reply is not dropped and sent twice');
      expect(cookieUid(), 1000);
      expect(dialog, findsOneWidget);
      expect(tester.widget<ListTile>(row(_bob)).enabled, isTrue);
      await expectTicking(tester, auto);

      // Once the reply is done the switch goes through.
      await replyAnswered(tester, reply);
      await tester.tap(row(_bob));
      await _settle(tester);
      expect(cookieUid(), 1001);
      expect(dialog, findsNothing);
      await finish(tester);
    });

    testWidgets('a reply sent from another page (the homepage menu, no reply bar here): refused too', (tester) async {
      // The thread page sending it is under the page whose avatar is tapped (a link followed while it sends).
      await saveAccounts([_bob]);
      await pumpHome(tester);
      final reply = await sendReply(tester);
      await openMenu(tester);

      await tester.tap(row(_bob));
      await _settle(tester);
      expect(find.text(t.currentAccount.replyBusy), findsOneWidget);
      expect(forum.requests, isEmpty);
      expect(cookieUid(), 1000);
      expect(isSwitchingAccount, isFalse);

      await replyAnswered(tester, reply);
      await tester.tap(row(_bob));
      await _settle(tester);
      expect(cookieUid(), 1001);
      await finish(tester);
    });
  });

  group('manage accounts page', () {
    late AutoCheckinBloc checkin;
    late AutoNotificationCubit auto;

    setUp(() {
      checkin = AutoCheckinBloc(
        autoCheckinRepository: AutoCheckinRepository(storageProvider: storage),
        settingsRepository: settings,
        storageProvider: storage,
      );
    });

    tearDown(() async => checkin.close());

    Future<void> pumpPage(WidgetTester tester) async {
      await saveAccounts([_bob]);
      auto = autoSync();
      await tester.pumpWidget(
        TranslationProvider(
          child: RepositoryProvider<AuthenticationRepository>.value(
            value: auth,
            child: MultiBlocProvider(
              providers: [
                BlocProvider<AutoCheckinBloc>.value(value: checkin),
                BlocProvider<AutoNotificationCubit>.value(value: auto),
                BlocProvider<NotificationSyncAllCubit>(
                  create: (_) => NotificationSyncAllCubit(
                    repository: NotificationSyncAllRepository(
                      storageProvider: storage,
                      notificationRepository: NotificationRepository(),
                    ),
                    storageProvider: storage,
                    authenticationRepository: auth,
                    infoRepository: NotificationInfoRepository(),
                  ),
                ),
              ],
              child: MaterialApp(scaffoldMessengerKey: snackbarKey, home: const ManageAccountPage()),
            ),
          ),
        ),
      );
      await _settle(tester);
      expect(find.text('Bob'), findsOneWidget);
      await expectTicking(tester, auto);
      // The dialog of Bob.
      await tester.tap(find.text('Bob'));
      await _settle(tester, rounds: 3);
      expect(find.text(t.manageAccountPage.switchAccount.dialog.switchAccount), findsOneWidget);
    }

    testWidgets('switching from the account dialog: same flow, it closes with the same toast', (tester) async {
      await pumpPage(tester);
      await tester.tap(find.text(t.manageAccountPage.switchAccount.dialog.switchAccount));
      await _settle(tester);

      expect(cookieUid(), 1001);
      expect(settings.currentSettings.loginUid, 1001);
      expect(find.text(t.manageAccountPage.switchAccount.dialog.switchAccount), findsNothing, reason: 'closed');
      expect(find.text('Switched to Bob'), findsOneWidget);
      await expectTicking(tester, auto);
      auto.stop();
      await _dispose(tester);
    });

    testWidgets('a guest page keeps the dialog open with the reason, the sync ticks again', (tester) async {
      forum.body = _guestPage;
      await pumpPage(tester);
      await tester.tap(find.text(t.manageAccountPage.switchAccount.dialog.switchAccount));
      await _settle(tester);

      expect(cookieUid(), 1000);
      expect(find.text(t.manageAccountPage.switchAccount.dialog.switchAccount), findsOneWidget, reason: 'still open');
      expect(find.text(t.loginPage.perhapsExpired), findsOneWidget);
      await expectTicking(tester, auto);
      auto.stop();
      await _dispose(tester);
    });

    testWidgets('a reply being sent: the account dialog refuses to switch as well', (tester) async {
      await pumpPage(tester);
      final reply = await sendReply(tester);
      await tester.tap(find.text(t.manageAccountPage.switchAccount.dialog.switchAccount));
      await _settle(tester);

      expect(find.text(t.currentAccount.replyBusy), findsOneWidget);
      expect(forum.requests, isEmpty);
      expect(cookieUid(), 1000);
      expect(find.text(t.manageAccountPage.switchAccount.dialog.switchAccount), findsOneWidget, reason: 'still open');

      await replyAnswered(tester, reply);
      await tester.tap(find.text(t.manageAccountPage.switchAccount.dialog.switchAccount));
      await _settle(tester);
      expect(cookieUid(), 1001);
      auto.stop();
      await _dispose(tester);
    });

    testWidgets('leaving the page while switching: the sync stays paused until the switch ended, then ticks', (
      tester,
    ) async {
      SwitchAccountResult? secondSwitch;
      forum.gate = Completer<void>();
      await pumpPage(tester);
      await tester.tap(find.text(t.manageAccountPage.switchAccount.dialog.switchAccount));
      await _settle(tester, rounds: 3);
      expect(forum.requests, hasLength(1));
      expect(auto.state, isA<AutoNoticeStatePaused>());

      // The page (and the bloc it holds) goes away before the forum answered. Closing the bloc does not stop the
      // switch: the sync stays paused and no other switch starts until it ended.
      await tester.pumpWidget(const SizedBox());
      await _settle(tester, rounds: 3);
      expect(isSwitchingAccount, isTrue);
      await tester.pump(const Duration(seconds: 1));
      expect(auto.state, isA<AutoNoticeStatePaused>());
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            scaffoldMessengerKey: snackbarKey,
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  final bloc = SwitchUserBloc(auth);
                  secondSwitch = await switchAccount(context, bloc: bloc, userInfo: _carol);
                  await bloc.close();
                },
                child: const Text('switch to Carol'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('switch to Carol'));
      await tester.pump();
      expect(secondSwitch, SwitchAccountResult.alreadySwitching);
      expect(forum.requests, hasLength(1));

      // The switch itself ends; nothing is shown, and only then the sync ticks again.
      forum.gate!.complete();
      await _settle(tester);
      expect(cookieUid(), 1001);
      expect(isSwitchingAccount, isFalse);
      await expectTicking(tester, auto);
      auto.stop();
      await _dispose(tester);
    });
  });

  group('profile cache', () {
    late _ProfileAdapter profiles;

    setUp(() {
      profiles = _ProfileAdapter();
      // No identity guard on this client: a page that arrives after a switch reaches the repository.
      getIt.registerFactory<NetClientProvider>(
        () => NetClientProvider.buildNoCookie(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = profiles),
      );
    });

    test('a switch drops the profile of the previous account, the next load asks for the new one', () async {
      await saveAccounts([_bob]);
      final repo = ProfileRepository();
      expect((await repo.fetchProfile().run()).isRight(), isTrue);
      expect(repo.hasCache(), isTrue);
      expect(repo.getCache()!.querySelector('#ct')?.text, contains('profile of 1000'));
      expect((await repo.fetchProfile().run()).isRight(), isTrue);
      expect(profiles.uids, ['1000'], reason: 'served from the cache');

      expect((await auth.switchUser(_bob).run()).isRight(), isTrue);
      expect(repo.hasCache(), isFalse, reason: "Alice's page is not Bob's");
      expect(repo.getCache(), isNull);

      final bob = await repo.fetchProfile().run();
      expect(bob.getRight().toNullable()!.querySelector('#ct')?.text, contains('profile of 1001'));
      expect(profiles.uids, ['1000', '1001']);
      expect(repo.getCache()!.querySelector('#ct')?.text, contains('profile of 1001'));
    });

    test('removing the account in use drops it too', () async {
      final repo = ProfileRepository();
      expect((await repo.fetchProfile().run()).isRight(), isTrue);
      expect(repo.hasCache(), isTrue);
      expect((await auth.forgetCurrentUser().run()).isRight(), isTrue);
      expect(repo.hasCache(), isFalse);
      expect(repo.getCache(), isNull);
    });

    test('a page that arrives after a switch is not kept for the new account', () async {
      await saveAccounts([_bob]);
      final repo = ProfileRepository();
      profiles.gate = Completer<void>();
      final alice = repo.fetchProfile().run();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect((await auth.switchUser(_bob).run()).isRight(), isTrue);
      profiles.gate!.complete();
      expect((await alice).isRight(), isTrue);
      expect(repo.hasCache(), isFalse);

      profiles.gate = null;
      final bob = await repo.fetchProfile().run();
      expect(bob.getRight().toNullable()!.querySelector('#ct')?.text, contains('profile of 1001'));
    });
  });

  group('thread page', () {
    late SettingsBloc settingsBloc;
    late UserBlockRepository blocks;
    late _ThreadAdapter thread;

    setUp(() async {
      await saveAccounts([_bob]);
      thread = _ThreadAdapter();
      getIt.registerFactory<NetClientProvider>(
        () => NetClientProvider.build(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = thread),
      );
      settingsBloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository());
      blocks = UserBlockRepository(storage);
      ThreadAuthorCache.clear();
    });

    tearDown(() async {
      await settingsBloc.close();
      await blocks.dispose();
    });

    /// The thread page opened on [pageNumber]; `/other` is a plain page to push above it. Returns the router.
    Future<GoRouter> pumpThread(WidgetTester tester, {String pageNumber = '1', bool loaded = true}) async {
      final info = NotificationInfoRepository();
      final counts = NotificationStateCubit(info);
      final cubit = UserBlockCubit(
        repository: blocks,
        currentUid: () => auth.effectiveCurrentUid,
        authStatus: auth.status,
      );
      final history = ThreadVisitHistoryBloc(ThreadVisitHistoryRepo(storage));
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => ThreadPage(
              threadID: '1264975',
              findPostID: null,
              pageNumber: pageNumber,
              overrideReverseOrder: false,
              overrideWithExactOrder: null,
            ),
          ),
          GoRoute(
            path: '/other',
            builder: (_, _) => const Scaffold(body: Center(child: Text('other page'))),
          ),
        ],
      );
      addTearDown(() async {
        router.dispose();
        await cubit.close();
        await history.close();
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
                BlocProvider<NotificationBloc>.value(value: _Notifications()),
                BlocProvider<NotificationStateCubit>.value(value: counts),
                BlocProvider<ThreadVisitHistoryBloc>.value(value: history),
              ],
              child: MaterialApp.router(routerConfig: router, scaffoldMessengerKey: snackbarKey),
            ),
          ),
        ),
      );
      await _settle(tester);
      if (loaded) {
        expect(find.textContaining('floor 1 text', findRichText: true), findsWidgets);
      }
      expect(thread.requests, 1, reason: 'opening the page loads it once');
      return router;
    }

    /// Threads in the visit history of [user].
    Future<int> visits(WidgetTester tester, UserLoginInfo user) async {
      final result = await tester.runAsync(() => storage.fetchThreadVisitHistoryByUid(user.uid!).run());
      return result!.getOrElse((_) => []).length;
    }

    Future<void> switchNow(WidgetTester tester, UserLoginInfo user) async {
      final result = await tester.runAsync(() => auth.switchUser(user).run());
      expect(result!.isRight(), isTrue, reason: '$result');
      await _settle(tester);
    }

    TextEditingController replyBox(WidgetTester tester) =>
        tester.widget<TextField>(find.byKey(const ValueKey('reply-bar-field'))).controller!;

    String? formHash(WidgetTester tester) =>
        BlocProvider.of<ReplyBloc>(tester.element(find.byType(PostList))).state.replyParameters?.formHash;

    /// Lets the page show its loading state, the reply bar gone, as on a real network; then answers.
    Future<void> reloadSlowly(WidgetTester tester, Future<void> Function() reload) async {
      thread.gate = Completer<void>();
      await reload();
      await _settle(tester);
      expect(find.byKey(const ValueKey('reply-bar-field')), findsNothing, reason: 'no reply bar while loading');
      thread.gate!.complete();
      thread.gate = null;
      await _settle(tester);
    }

    Future<void> switchToBob(WidgetTester tester) => reloadSlowly(tester, () async {
      final result = await tester.runAsync(() => auth.switchUser(_bob).run());
      expect(result!.isRight(), isTrue, reason: '$result');
    });

    testWidgets('an account change reloads the thread and keeps the unsent reply', (tester) async {
      await pumpThread(tester);
      expect(formHash(tester), 'hashOfAlice');
      replyBox(tester).text = 'unsent reply';
      await tester.pump();

      await switchToBob(tester);
      expect(thread.requests, 2, reason: 'reloaded for Bob: his formhash and his own floors');
      expect(formHash(tester), 'hashOfBob', reason: "a reply goes out with Bob's formhash");
      expect(find.textContaining('floor 1 text', findRichText: true), findsWidgets);
      expect(replyBox(tester).text, 'unsent reply');
      expect(tester.takeException(), isNull);
      await _dispose(tester);
    });

    testWidgets('a reply written in the open editor survives the reload too', (tester) async {
      await pumpThread(tester);
      await tester.tap(find.byKey(const ValueKey('reply-bar-field')));
      await _settle(tester, rounds: 4);
      tester.widget<RichEditor>(find.byType(RichEditor)).controller.insertBBCode('written in the editor');
      await tester.pump();

      await switchToBob(tester);
      expect(thread.requests, 2);
      expect(find.byType(RichEditor), findsNothing, reason: 'the editor closed with the old bar');
      expect(replyBox(tester).text, contains('written in the editor'));
      expect(tester.takeException(), isNull);
      await _dispose(tester);
    });

    testWidgets('a reload of the page keeps the unsent reply as well', (tester) async {
      await pumpThread(tester);
      replyBox(tester).text = 'unsent reply';
      await tester.pump();

      final bloc = BlocProvider.of<ThreadBloc>(tester.element(find.byType(PostList)));
      await reloadSlowly(tester, () async => bloc.add(ThreadRefreshRequested()));
      expect(thread.requests, 2);
      expect(replyBox(tester).text, 'unsent reply');
      await _dispose(tester);
    });

    testWidgets('a quick reload while the editor still closes keeps its text, without touching a locked tree', (
      tester,
    ) async {
      await pumpThread(tester);
      await tester.tap(find.byKey(const ValueKey('reply-bar-field')));
      await _settle(tester, rounds: 4);
      tester.widget<RichEditor>(find.byType(RichEditor)).controller.insertBBCode('written in the editor');
      await tester.pump();

      final bloc = BlocProvider.of<ThreadBloc>(tester.element(find.byType(PostList)));
      thread.gate = Completer<void>();
      bloc.add(ThreadRefreshRequested());
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('reply-bar-field')), findsNothing, reason: 'the old bar is gone');
      expect(find.byType(RichEditor), findsOneWidget, reason: 'its editor is still closing');
      // The forum answers before the editor finished closing: the new bar is there first.
      thread.gate!.complete();
      thread.gate = null;
      for (var i = 0; i < 4; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(find.byKey(const ValueKey('reply-bar-field')), findsOneWidget);
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        expect(tester.takeException(), isNull);
      }
      expect(find.byType(RichEditor), findsNothing);
      expect(replyBox(tester).text, contains('written in the editor'));
      await _dispose(tester);
    });

    testWidgets('a thread page under another page reloads once it shows again, not before', (tester) async {
      thread.breadcrumb = true;
      final router = await pumpThread(tester);
      expect(await visits(tester, _alice), 1);
      unawaited(router.push('/other'));
      await _settle(tester);
      expect(find.text('other page'), findsOneWidget);

      await switchNow(tester, _bob);
      await _settle(tester);
      expect(thread.requests, 1, reason: 'not reloaded while covered');
      expect(await visits(tester, _bob), 0, reason: 'Bob never opened the thread');

      router.pop();
      await _settle(tester);
      expect(thread.requests, 2, reason: 'reloaded for Bob once shown again');
      expect(formHash(tester), 'hashOfBob');
      expect(await visits(tester, _bob), 1, reason: 'Bob reads it now');
      await _settle(tester);
      expect(thread.requests, 2, reason: 'once');
      await _dispose(tester);
    });

    testWidgets('the menu the switch came from covers the page: it reloads once the menu closed', (tester) async {
      await pumpThread(tester);
      final page = tester.element(find.byType(PostList));
      unawaited(
        showDialog<void>(
          context: page,
          builder: (_) => const AlertDialog(content: Text('menu')),
        ),
      );
      await _settle(tester);

      await switchNow(tester, _bob);
      expect(thread.requests, 1);
      Navigator.of(tester.element(find.text('menu'))).pop();
      await _settle(tester);
      expect(thread.requests, 2);
      expect(formHash(tester), 'hashOfBob');
      await _dispose(tester);
    });

    testWidgets('the reload stays on the page being read', (tester) async {
      await pumpThread(tester, pageNumber: '3');
      expect(thread.pages, ['3']);

      await switchNow(tester, _bob);
      expect(thread.pages, ['3', '3'], reason: 'not back to the first page');
      expect(formHash(tester), 'hashOfBob');
      await _dispose(tester);
    });

    testWidgets('a page asking to log in reloads for an account that may read the thread', (tester) async {
      thread.aliceNeedsLogin = true;
      await pumpThread(tester, loaded: false);
      expect(find.text(t.general.needLoginToSeeThisPage), findsOneWidget);

      await switchNow(tester, _bob);
      expect(thread.requests, 2);
      expect(find.text(t.general.needLoginToSeeThisPage), findsNothing);
      expect(find.textContaining('floor 1 text', findRichText: true), findsWidgets);
      await _dispose(tester);
    });

    // Integration review: the reload for the new account began while a load of Alice was pending. Her request ended
    // with IdentityChangedException after the reload had cleared the page, put her floors back with "failed to load",
    // and Bob's were appended to them: every floor twice.
    for (final jump in [false, true]) {
      final name = jump ? 'jump' : 'refresh';
      testWidgets('a $name pending for the previous account never comes back: every floor once, no failure', (
        tester,
      ) async {
        await pumpThread(tester, pageNumber: jump ? '3' : '1');
        final bloc = BlocProvider.of<ThreadBloc>(tester.element(find.byType(PostList)));
        // Alice reloads the page, the forum is slow.
        thread.gate = Completer<void>();
        bloc.add(jump ? const ThreadJumpPageRequested(3) : ThreadRefreshRequested());
        await _settle(tester);
        expect(thread.requests, 2);

        // Switched to Bob meanwhile: the page reloads for him at once, Alice's answer is yet to come.
        await switchNow(tester, _bob);
        expect(thread.requests, 3);
        expect(thread.pages.last, jump ? '3' : '1');
        thread.gate!.complete();
        thread.gate = null;
        await _settle(tester);

        expect(bloc.state.status, ThreadStatus.success);
        expect(bloc.state.postList, hasLength(1));
        expect(find.byType(PostCard), findsOneWidget, reason: 'every floor once');
        expect(find.text(t.general.failedToLoad), findsNothing, reason: "Alice's dropped request is no failure");
        expect(formHash(tester), 'hashOfBob');
        expect(tester.takeException(), isNull);
        await _dispose(tester);
      });
    }

    testWidgets('the same account reported again does not reload', (tester) async {
      await pumpThread(tester);
      await tester.runAsync(() => auth.loginWithDocument(parseHtmlDocument(_authedPage(_alice))).run());
      await _settle(tester);
      expect(thread.requests, 1);
      await _dispose(tester);
    });
  });
  group('thread loads', () {
    late _HeldThreadRepository repo;
    late ThreadBloc bloc;
    final states = <ThreadState>[];

    Future<void> answer(int load, Either<AppException, uh.Document> result) async {
      repo.answers[load].complete(result);
      await pumpEventQueue();
    }

    uh.Document page(String formHash, {int floor = 1}) => parseHtmlDocument(_threadHtml(formHash, floor: floor));

    setUp(() async {
      repo = _HeldThreadRepository();
      bloc = ThreadBloc(
        tid: '1264975',
        pid: null,
        onlyVisibleUid: null,
        reverseOrder: null,
        exactOrder: null,
        threadRepository: repo,
      );
      final sub = bloc.stream.listen(states.add);
      addTearDown(() async {
        for (final pending in repo.answers.where((e) => !e.isCompleted)) {
          pending.complete(left(IdentityChangedException()));
        }
        await pumpEventQueue();
        await sub.cancel();
        await bloc.close();
      });
      // Alice opens the thread.
      bloc.add(const ThreadLoadMoreRequested(1));
      await pumpEventQueue();
      await answer(0, right(page('hashOfAlice')));
      expect(bloc.state.status, ThreadStatus.success);
      expect(bloc.state.postList, hasLength(1));
      states.clear();
    });

    /// Bob's page is on screen, once, and nothing failed on the way.
    void expectBobsPage() {
      expect(bloc.state.status, ThreadStatus.success);
      expect(bloc.state.postList.map((e) => e.postFloor), [1], reason: 'every floor once');
      expect(bloc.state.replyParameters?.formHash, 'hashOfBob');
      expect(states.where((e) => e.status == ThreadStatus.failure), isEmpty, reason: 'no "failed to load"');
    }

    for (final jump in [false, true]) {
      final name = jump ? 'jump' : 'refresh';
      ThreadEvent reload() => jump ? const ThreadJumpPageRequested(3) : ThreadRefreshRequested();

      test("$name: Alice's pending one ends dropped after the reload for Bob began", () async {
        // Alice's own, then the reload for Bob.
        bloc
          ..add(reload())
          ..add(reload());
        await pumpEventQueue();
        expect(repo.pages, [
          1,
          if (jump) ...[3, 3] else ...[1, 1],
        ]);
        await answer(1, left(IdentityChangedException()));
        await answer(2, right(page('hashOfBob')));
        expectBobsPage();
      });

      test("$name: Alice's pending one ends dropped after Bob's page is on screen", () async {
        bloc
          ..add(reload())
          ..add(reload());
        await pumpEventQueue();
        await answer(2, right(page('hashOfBob')));
        await answer(1, left(IdentityChangedException()));
        expectBobsPage();
      });

      test('$name: a late answer of a superseded load is dropped too', () async {
        bloc
          ..add(reload())
          ..add(reload());
        await pumpEventQueue();
        await answer(2, right(page('hashOfBob')));
        await answer(1, right(page('hashOfAlice')));
        expectBobsPage();
      });
    }

    for (final dropped in [false, true]) {
      test('load more begun before a reload never appends to it (${dropped ? 'dropped' : 'answered'})', () async {
        bloc.add(const ThreadLoadMoreRequested(2));
        await pumpEventQueue();
        bloc.add(ThreadRefreshRequested());
        await pumpEventQueue();
        expect(repo.pages, [1, 2, 1]);
        await answer(1, dropped ? left(IdentityChangedException()) : right(page('hashOfAlice', floor: 2)));
        await answer(2, right(page('hashOfBob')));
        expectBobsPage();
      });
    }

    test('load more still appends to the page it began on', () async {
      bloc.add(const ThreadLoadMoreRequested(2));
      await pumpEventQueue();
      await answer(1, right(page('hashOfAlice', floor: 2)));
      expect(bloc.state.postList.map((e) => e.postFloor), [1, 2]);
    });

    test('a request dropped for the previous account is no failure: the page waits for the reload', () async {
      bloc.add(ThreadRefreshRequested());
      await pumpEventQueue();
      await answer(1, left(IdentityChangedException()));
      expect(bloc.state.status, ThreadStatus.loading);
      expect(states.where((e) => e.status == ThreadStatus.failure), isEmpty);

      bloc.add(ThreadRefreshRequested());
      await pumpEventQueue();
      await answer(2, right(page('hashOfBob')));
      expectBobsPage();
    });

    test('a failure of the latest load still shows, the floors kept', () async {
      bloc.add(ThreadRefreshRequested());
      await pumpEventQueue();
      await answer(1, left(HttpRequestFailedException(500)));
      expect(bloc.state.status, ThreadStatus.failure);
      expect(bloc.state.postList.map((e) => e.postFloor), [1]);
    });
  });

  group('forum pages', () {
    late _BoardsRepository boards;
    late SettingsBloc settingsBloc;

    setUp(() async {
      await saveAccounts([_bob]);
      boards = _BoardsRepository(() => auth.effectiveCurrentUid);
      settingsBloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository());
    });

    tearDown(() async {
      if (boards.gate case final gate? when !gate.isCompleted) {
        gate.complete();
      }
      await settingsBloc.close();
    });

    /// [page] opened; `/other` is a plain page to push above it. Returns the router.
    Future<GoRouter> pumpBoards(WidgetTester tester, Widget page) async {
      final info = NotificationInfoRepository();
      final counts = NotificationStateCubit(info);
      final router = GoRouter(
        routes: [
          GoRoute(path: '/', builder: (_, _) => page),
          GoRoute(
            path: '/other',
            builder: (_, _) => const Scaffold(body: Center(child: Text('other page'))),
          ),
        ],
      );
      addTearDown(() async {
        router.dispose();
        await info.dispose();
        await counts.close();
      });
      await tester.pumpWidget(
        TranslationProvider(
          child: MultiRepositoryProvider(
            providers: [
              RepositoryProvider<AuthenticationRepository>.value(value: auth),
              RepositoryProvider<ForumRepository>.value(value: boards),
              RepositoryProvider<FavoriteRepository>(create: (_) => FavoriteRepository()),
            ],
            child: MultiBlocProvider(
              providers: [
                BlocProvider<SettingsBloc>.value(value: settingsBloc),
                BlocProvider<NotificationBloc>.value(value: _Notifications()),
                BlocProvider<NotificationStateCubit>.value(value: counts),
              ],
              child: MaterialApp.router(routerConfig: router, scaffoldMessengerKey: snackbarKey),
            ),
          ),
        ),
      );
      await _settle(tester);
      expect(find.text('Alice board'), findsOneWidget);
      return router;
    }

    Future<void> switchNow(WidgetTester tester, UserLoginInfo user) async {
      final result = await tester.runAsync(() => auth.switchUser(user).run());
      expect(result!.isRight(), isTrue, reason: '$result');
      await _settle(tester);
    }

    void expectBobsBoards(WidgetTester tester) {
      expect(find.text('Bob board'), findsOneWidget);
      expect(find.text('Alice board'), findsNothing);
      expect(find.text(t.general.retry), findsNothing);
      expect(tester.takeException(), isNull);
    }

    final pages = <String, (Widget, int Function(_BoardsRepository))>{
      'forum page': (const ForumPage(fid: '73'), (boards) => boards.forumLoads.length),
      'forum group page': (const ForumGroupPage(gid: '1'), (boards) => boards.groupLoads),
    };

    for (final MapEntry(key: name, value: (page, loads)) in pages.entries) {
      group(name, () {
        testWidgets('loads again for the new account', (tester) async {
          await pumpBoards(tester, page);
          expect(loads(boards), 1);

          await switchNow(tester, _bob);
          expect(loads(boards), 2);
          expectBobsBoards(tester);
          await _dispose(tester);
        });

        testWidgets('under another page: loads again once it shows again, not before', (tester) async {
          final router = await pumpBoards(tester, page);
          unawaited(router.push('/other'));
          await _settle(tester);

          await switchNow(tester, _bob);
          expect(loads(boards), 1, reason: 'not loaded while covered');
          router.pop();
          await _settle(tester);
          expect(loads(boards), 2);
          expectBobsBoards(tester);
          await _settle(tester);
          expect(loads(boards), 2, reason: 'once');
          await _dispose(tester);
        });

        testWidgets('the same account reported again does not load again', (tester) async {
          await pumpBoards(tester, page);
          await tester.runAsync(() => auth.loginWithDocument(parseHtmlDocument(_authedPage(_alice))).run());
          await _settle(tester);
          expect(loads(boards), 1);
          await _dispose(tester);
        });

        testWidgets("a load still pending for the previous account never shows Alice's boards", (tester) async {
          await pumpBoards(tester, page);
          boards.gate = Completer<void>();
          final context = tester.element(find.text('Alice board'));
          if (page is ForumPage) {
            context.read<ForumBloc>().add(ForumRefreshRequested());
          } else {
            context.read<ForumGroupBloc>().add(const ForumGroupLoadRequested('1'));
          }
          await _settle(tester);
          expect(loads(boards), 2);

          await switchNow(tester, _bob);
          expect(loads(boards), 3);
          boards.gate!.complete();
          await _settle(tester);
          expectBobsBoards(tester);
          await _dispose(tester);
        });
      });
    }

    testWidgets('the forum page keeps the chosen thread filter', (tester) async {
      await pumpBoards(tester, const ForumPage(fid: '73'));
      const filter = FilterState(
        filter: 'typeid',
        filterType: FilterType(name: 'Art', typeID: '7'),
      );
      tester
          .element(find.text('Alice board'))
          .read<ForumBloc>()
          .add(const ForumChangeThreadFilterStateRequested(filter));
      await _settle(tester);
      expect(boards.forumLoads.last.filterType?.typeID, '7');

      await switchNow(tester, _bob);
      expect(boards.forumLoads, hasLength(3));
      expect(boards.forumLoads.last.filterType?.typeID, '7', reason: 'still filtered for Bob');
      expect(find.text('Bob board'), findsOneWidget);
      await _dispose(tester);
    });
  });
}
