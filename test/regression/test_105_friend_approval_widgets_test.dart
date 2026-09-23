import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/friend/models/add_friend.dart';
import 'package:tsdm_client/features/friend/models/approve_friend.dart';
import 'package:tsdm_client/features/friend/repository/approve_friend_repository.dart';
import 'package:tsdm_client/features/friend/utils/parse_approve_friend.dart';
import 'package:tsdm_client/features/notification/bloc/notification_bloc.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/widgets/munched_html.dart';
import 'package:universal_html/parsing.dart';

/// GitHub #102, on screen: the "批准申请" link of a friend request notice opens the app's own approval dialog.
///
/// The fixtures were captured with the two test accounts (uids 1000/1001, Alice/Bob); no real forum is contacted.
const _bob = UserLoginInfo(username: 'Bob', uid: 1001);
const _carol = UserLoginInfo(username: 'Carol', uid: 2000);
const _alice = 1000;
const _noticeLink = 'https://www.tsdm39.com/home.php?mod=spacecp&ac=friend&op=add&uid=1000&from=notice';

String _data(String name) => File('test/data/$name').readAsStringSync();

Translations get tr => LocaleSettings.instance.currentTranslations;

TranslationsFriendPageApproveFriendEn get atr => tr.friendPage.approveFriend;

ApproveFriendForm _form() =>
    parseApproveFriendForm(_data('friend_accept_form_x5.xml'), targetUid: _alice) as ApproveFriendForm;

/// Authentication with a current account that the test switches, like a switch in the account manager.
final class _Auth extends Fake implements AuthenticationRepository {
  _Auth(this.currentUser);

  @override
  UserLoginInfo? currentUser;

  final _controller = StreamController<AuthStatus>.broadcast(sync: true);

  @override
  Stream<AuthStatus> get status => _controller.stream;

  void switchTo(UserLoginInfo? user) {
    currentUser = user;
    _controller.add(user == null ? const AuthStatusNotAuthed() : AuthStatusAuthed(user));
  }

  Future<void> close() => _controller.close();
}

/// Records the events the approval sends to the notification bloc.
final class _Notifications extends Fake implements NotificationBloc {
  final events = <NotificationEvent>[];

  @override
  void add(NotificationEvent event) => events.add(event);

  @override
  NotificationState get state => const NotificationState(status: NotificationStatus.success);

  @override
  Stream<NotificationState> get stream => const Stream.empty();

  @override
  bool get isClosed => false;

  @override
  Future<void> close() async {}
}

/// Never answers.
final class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

/// Approvals answered by the test through completers; every client asked for and every call is recorded.
final class _Approvals extends ApproveFriendRepository {
  final clientsFor = <int?>[];
  final loads = <(int, Completer<Either<ApproveFriendFailure, ApproveFriendFormResult>>)>[];
  final posts = <(ApproveFriendForm, String, Completer<Either<ApproveFriendFailure, AddFriendResult>>)>[];

  @override
  NetClientProvider clientFor(UserLoginInfo user) {
    clientsFor.add(user.uid);
    return NetClientProvider.buildNoCookie(
      dio: Dio()..httpClientAdapter = _OfflineAdapter(),
      cookie: CookieProvider.buildEmpty(),
    );
  }

  @override
  Future<Either<ApproveFriendFailure, ApproveFriendFormResult>> fetchForm(
    NetClientProvider client, {
    required int targetUid,
  }) {
    final c = Completer<Either<ApproveFriendFailure, ApproveFriendFormResult>>();
    loads.add((targetUid, c));
    return c.future;
  }

  @override
  Future<Either<ApproveFriendFailure, AddFriendResult>> approve(
    NetClientProvider client, {
    required ApproveFriendForm form,
    required String gid,
  }) {
    final c = Completer<Either<ApproveFriendFailure, AddFriendResult>>();
    posts.add((form, gid, c));
    return c.future;
  }
}

/// The captured forum behind the real repository: the form for a GET, the captured success for a POST.
final class _Forum implements HttpClientAdapter {
  final requests = <RequestOptions>[];

  List<RequestOptions> get posts => requests.where((e) => e.method == 'POST').toList();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final name = options.method == 'GET' ? 'friend_accept_form_x5.xml' : 'friend_accept_result_x5.xml';
    return ResponseBody.fromString(
      _data(name),
      200,
      headers: {
        Headers.contentTypeHeader: ['text/xml; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// The real repository, with clients talking to [forum].
final class _ForumApprovals extends ApproveFriendRepository {
  _ForumApprovals(this.forum);

  final _Forum forum;

  @override
  NetClientProvider clientFor(UserLoginInfo user) =>
      NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = forum, cookie: CookieProvider.buildEmpty());
}

/// Let futures finish outside the fake zone, then build the frames they caused, until the route animations they
/// started are over (a closing dialog is gone, a snack bar is shown).
///
/// Not `pumpAndSettle`: a loading dialog spins forever.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 20));
  }
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
}

void main() {
  late _Auth auth;
  late _Notifications notifications;
  final launched = <MethodCall>[];

  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
  });

  setUp(() {
    getIt.registerSingleton<NetErrorSaver>(NetErrorSaver());
    auth = _Auth(_bob);
    notifications = _Notifications();
    launched.clear();
    // Links left to the browser end here instead of a platform.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/url_launcher'),
      (call) async {
        launched.add(call);
        return true;
      },
    );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/url_launcher'),
      null,
    );
    await auth.close();
    await getIt.reset();
  });

  Future<void> pump(WidgetTester tester, Widget child, ApproveFriendRepository repository) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MultiRepositoryProvider(
          providers: [
            RepositoryProvider<AuthenticationRepository>.value(value: auth),
            RepositoryProvider<ApproveFriendRepository>.value(value: repository),
          ],
          child: BlocProvider<NotificationBloc>.value(
            value: notifications,
            child: MaterialApp(
              home: Scaffold(body: child),
              scaffoldMessengerKey: snackbarKey,
            ),
          ),
        ),
      ),
    );
  }

  /// A button dispatching [url] the way every rendered link does.
  Widget link(String url, {bool external = false}) => Builder(
    builder: (context) => TextButton(
      onPressed: () async => context.dispatchAsUrl(url, external: external),
      child: const Text('open'),
    ),
  );

  Finder approveButton() => find.byKey(const ValueKey('approve-friend-approve'));
  Finder cancelButton() => find.byKey(const ValueKey('approve-friend-cancel'));

  /// Open the approval of Alice's request and answer the form read with the captured form.
  Future<void> openWithForm(WidgetTester tester, _Approvals approvals) async {
    await pump(tester, link(_noticeLink), approvals);
    await tester.tap(find.text('open'));
    await tester.pump();
    expect(approvals.loads.single.$1, _alice);
    approvals.loads.single.$2.complete(right(_form()));
    await settle(tester);
    expect(approveButton(), findsOneWidget);
  }

  /// Cancel a dialog a test leaves open: the approval only ends (and may be opened again) once its dialog closed, and
  /// tearing down the tree does not close it.
  Future<void> closeDialog(WidgetTester tester) async {
    await tester.tap(cancelButton());
    await settle(tester);
    expect(find.text(atr.title), findsNothing);
  }

  group('notice link', () {
    testWidgets('the link in the captured notice opens the approval, the chosen group is posted as served', (
      tester,
    ) async {
      final forum = _Forum();
      final doc = parseHtmlDocument(_data('notice_friend_request_x5.html'));
      final notice = Notice.toV2(NotificationV2.noticeNodes(doc).single)!;
      await pump(tester, MunchedHtml(notice.data), _ForumApprovals(forum));

      await tester.tapOnText(find.textRange.ofSubstring('批准申请'));
      await settle(tester);
      expect(launched, isEmpty, reason: 'not handed to the browser');
      expect(forum.requests.single.method, 'GET');
      expect(find.text(atr.title), findsOneWidget);
      expect(find.text(atr.content(name: 'Alice')), findsOneWidget);
      expect(find.text('通过本站认识'), findsWidgets, reason: 'the checked group is preselected');

      await tester.tap(find.byKey(const ValueKey('approve-friend-group')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('通过朋友认识').last);
      await tester.pumpAndSettle();
      await tester.tap(approveButton());
      await settle(tester);

      final post = forum.posts.single;
      expect(post.uri.path, '/home.php');
      expect(Map.of(post.uri.queryParameters)..remove('mobile'), {
        'mod': 'spacecp',
        'ac': 'friend',
        'op': 'add',
        'uid': '1000',
        'inajax': '1',
      });
      expect(post.data, {
        'referer': 'https://www.tsdm39.com/forum.php',
        'add2submit': 'true',
        'from': '',
        'handlekey': 'afrfriendhk_1001',
        'formhash': 'XXXXXXXX',
        'gid': '3',
      });
      expect(find.text(atr.title), findsNothing);
      expect(find.text('您已和Alice成为好友'), findsOneWidget);
      expect(notifications.events.single, isA<NotificationUpdateAllRequested>());
    });

    testWidgets('opened in the browser on request, never approved in the app', (tester) async {
      final approvals = _Approvals();
      await pump(tester, link(_noticeLink, external: true), approvals);
      await tester.tap(find.text('open'));
      await settle(tester);
      expect(launched, hasLength(1));
      expect(approvals.clientsFor, isEmpty);
      expect(approvals.loads, isEmpty);
      expect(find.text(atr.title), findsNothing);
    });

    for (final (reason, url) in [
      ('a foreign host', 'https://evil.example/home.php?mod=spacecp&ac=friend&op=add&uid=1000&from=notice'),
      ('another port', 'https://www.tsdm39.com:8443/home.php?mod=spacecp&ac=friend&op=add&uid=1000&from=notice'),
      ('user info', 'https://a@www.tsdm39.com/home.php?mod=spacecp&ac=friend&op=add&uid=1000&from=notice'),
      ('the add-friend link', 'https://www.tsdm39.com/home.php?mod=spacecp&ac=friend&op=add&uid=1000'),
    ]) {
      testWidgets('$reason is not approved in the app', (tester) async {
        final approvals = _Approvals();
        await pump(tester, link(url), approvals);
        await tester.tap(find.text('open'));
        await settle(tester);
        expect(approvals.clientsFor, isEmpty);
        expect(approvals.loads, isEmpty);
        expect(find.text(atr.title), findsNothing);
      });
    }
  });

  group('approval dialog', () {
    testWidgets('the client is bound to the account current when the link was tapped', (tester) async {
      final approvals = _Approvals();
      await openWithForm(tester, approvals);
      expect(approvals.clientsFor, [_bob.uid]);
      await closeDialog(tester);
    });

    testWidgets('cancel sends nothing and claims nothing', (tester) async {
      final approvals = _Approvals();
      await openWithForm(tester, approvals);
      await tester.tap(cancelButton());
      await settle(tester);
      expect(find.text(atr.title), findsNothing);
      expect(approvals.posts, isEmpty);
      expect(notifications.events, isEmpty);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('double taps on Approve post once, with the preselected group', (tester) async {
      final approvals = _Approvals();
      await openWithForm(tester, approvals);
      await tester.tap(approveButton());
      await tester.tap(approveButton(), warnIfMissed: false);
      await tester.pump();
      expect(approvals.posts, hasLength(1));
      expect(approvals.posts.single.$2, '1');
      expect(approvals.posts.single.$1.field('add2submit'), 'true');

      // Every control is disabled while the forum answers.
      expect(tester.widget<FilledButton>(approveButton()).onPressed, isNull);
      expect(tester.widget<TextButton>(cancelButton()).onPressed, isNull);
      await tester.tap(approveButton(), warnIfMissed: false);
      await tester.pump();
      expect(approvals.posts, hasLength(1));

      approvals.posts.single.$3.complete(right(const AddFriendResult(success: true, message: '您已和Alice成为好友')));
      await settle(tester);
      expect(find.text('您已和Alice成为好友'), findsOneWidget);
      expect(notifications.events.single, isA<NotificationUpdateAllRequested>());
    });

    testWidgets('tapping the link again while it loads loads once', (tester) async {
      final approvals = _Approvals();
      await pump(tester, link(_noticeLink), approvals);
      // Deliver two activations before the modal barrier can intercept the second tap.
      final open = tester.widget<TextButton>(find.widgetWithText(TextButton, 'open')).onPressed!;
      open();
      open();
      await tester.pump();
      expect(approvals.loads, hasLength(1));
      expect(find.text(atr.busy), findsOneWidget);
      await closeDialog(tester);
      // The load answering after the cancel is dropped.
      approvals.loads.single.$2.complete(right(_form()));
      await settle(tester);
      expect(find.text(atr.title), findsNothing);
      expect(approvals.posts, isEmpty);
    });

    testWidgets('a load that throws closes the spinner as a network failure, nothing is posted', (tester) async {
      final approvals = _Approvals();
      await pump(tester, link(_noticeLink), approvals);
      await tester.tap(find.text('open'));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      approvals.loads.single.$2.completeError(Exception('offline'));
      await settle(tester);
      expect(find.text(atr.title), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text(atr.failure.network), findsOneWidget);
      expect(approvals.posts, isEmpty);
      expect(notifications.events, isEmpty);

      // The approval is released: it can be opened again.
      await tester.tap(find.text('open'));
      await tester.pump();
      expect(approvals.loads, hasLength(2));
      await closeDialog(tester);
    });

    testWidgets('a post that throws is an unknown result: never success, never retried nor refreshed', (tester) async {
      final approvals = _Approvals();
      await openWithForm(tester, approvals);
      await tester.tap(approveButton());
      await tester.pump();
      approvals.posts.single.$3.completeError(Exception('connection reset'));
      await settle(tester);
      expect(find.text(atr.title), findsNothing);
      expect(find.text(atr.failure.unknownAfterSubmit), findsOneWidget);
      expect(find.text(atr.approved), findsNothing);
      expect(approvals.posts, hasLength(1));
      expect(notifications.events, isEmpty);
    });

    testWidgets('system back while loading closes only the dialog; a late answer leaves the page below alone', (
      tester,
    ) async {
      final approvals = _Approvals();
      await pump(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () async => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => Scaffold(
                  body: Column(children: [const Text('notice page'), link(_noticeLink)]),
                ),
              ),
            ),
            child: const Text('push'),
          ),
        ),
        approvals,
      );
      await tester.tap(find.text('push'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('open'));
      await tester.pump();
      expect(find.text(atr.title), findsOneWidget);

      // Finish opening so system back exercises the full reverse transition.
      await tester.pump(const Duration(milliseconds: 400));

      await tester.binding.handlePopRoute();
      // The failure lands while the dialog is still animating out.
      await tester.pump(const Duration(milliseconds: 10));
      expect(find.text(atr.title), findsOneWidget, reason: 'still closing');
      approvals.loads.single.$2.completeError(Exception('offline'));
      await settle(tester);

      expect(find.text(atr.title), findsNothing);
      expect(find.text('notice page'), findsOneWidget, reason: 'the page below the dialog is not popped');
      expect(find.text(atr.failure.network), findsNothing, reason: 'closed by the user: nothing to report');
      expect(approvals.posts, isEmpty);

      // The approval is released and opens again from the same page.
      await tester.tap(find.text('open'));
      await tester.pump();
      expect(approvals.loads, hasLength(2));
      await closeDialog(tester);
      expect(find.text('notice page'), findsOneWidget);
    });

    testWidgets('an unknown form stops before anything is asked or posted', (tester) async {
      final approvals = _Approvals();
      await pump(tester, link(_noticeLink), approvals);
      await tester.tap(find.text('open'));
      await tester.pump();
      approvals.loads.single.$2.complete(left(ApproveFriendFailure.unknownForm));
      await settle(tester);
      expect(find.text(atr.title), findsNothing);
      expect(find.text(atr.failure.unknownForm), findsOneWidget);
      expect(approvals.posts, isEmpty);
      expect(notifications.events, isEmpty);
    });

    testWidgets("the forum's refusal of the form is shown as is and nothing is posted", (tester) async {
      final approvals = _Approvals();
      await pump(tester, link(_noticeLink), approvals);
      await tester.tap(find.text('open'));
      await tester.pump();
      approvals.loads.single.$2.complete(right(const ApproveFriendRefused('你们已成为好友')));
      await settle(tester);
      expect(find.text('你们已成为好友'), findsOneWidget);
      expect(approvals.posts, isEmpty);
      expect(notifications.events, isEmpty);
    });

    for (final (reason, answer, text) in <(String, Either<ApproveFriendFailure, AddFriendResult>, String Function())>[
      ('a failure', left(ApproveFriendFailure.unknownAfterSubmit), () => atr.failure.unknownAfterSubmit),
      ('a refusal', right(const AddFriendResult(success: false, message: '抱歉，请求不存在')), () => '抱歉，请求不存在'),
    ]) {
      testWidgets('$reason after approving is shown, never as success, and nothing is refreshed', (tester) async {
        final approvals = _Approvals();
        await openWithForm(tester, approvals);
        await tester.tap(approveButton());
        await tester.pump();
        approvals.posts.single.$3.complete(answer);
        await settle(tester);
        expect(find.text(text()), findsOneWidget);
        expect(find.text(atr.approved), findsNothing);
        expect(notifications.events, isEmpty);
      });
    }

    testWidgets('without a logged in account nothing is loaded', (tester) async {
      auth.currentUser = null;
      final approvals = _Approvals();
      await pump(tester, link(_noticeLink), approvals);
      await tester.tap(find.text('open'));
      await settle(tester);
      expect(find.text(atr.failure.notLoggedIn), findsOneWidget);
      expect(approvals.clientsFor, isEmpty);
      expect(approvals.loads, isEmpty);
    });
  });

  group('account switch', () {
    testWidgets('while the group menu is open: both menu and approval close', (tester) async {
      final approvals = _Approvals();
      await openWithForm(tester, approvals);
      await tester.tap(find.byKey(const ValueKey('approve-friend-group')));
      await tester.pumpAndSettle();
      auth.switchTo(_carol);
      await settle(tester);
      expect(find.text(atr.title), findsNothing);
      expect(find.text(atr.failure.accountMismatch), findsOneWidget);
      expect(approvals.posts, isEmpty);
      expect(notifications.events, isEmpty);
    });

    testWidgets('while loading: the dialog closes and the late form is dropped', (tester) async {
      final approvals = _Approvals();
      await pump(tester, link(_noticeLink), approvals);
      await tester.tap(find.text('open'));
      await tester.pump();
      auth.switchTo(_carol);
      await settle(tester);
      expect(find.text(atr.failure.accountMismatch), findsOneWidget);
      approvals.loads.single.$2.complete(right(_form()));
      await settle(tester);
      expect(find.text(atr.title), findsNothing);
      expect(approvals.posts, isEmpty);
    });

    testWidgets('while the dialog is open: it closes and nothing is posted', (tester) async {
      final approvals = _Approvals();
      await openWithForm(tester, approvals);
      auth.switchTo(_carol);
      await settle(tester);
      expect(find.text(atr.title), findsNothing);
      expect(find.text(atr.failure.accountMismatch), findsOneWidget);
      expect(approvals.posts, isEmpty);
    });

    testWidgets('just before approving (no status event seen): nothing is posted', (tester) async {
      final approvals = _Approvals();
      await openWithForm(tester, approvals);
      auth.currentUser = _carol;
      await tester.tap(approveButton());
      await settle(tester);
      expect(approvals.posts, isEmpty);
      expect(find.text(atr.failure.accountMismatch), findsOneWidget);
      expect(notifications.events, isEmpty);
    });

    testWidgets('while submitting: the answer for the previous account is dropped, nothing is refreshed', (
      tester,
    ) async {
      final approvals = _Approvals();
      await openWithForm(tester, approvals);
      await tester.tap(approveButton());
      await tester.pump();
      auth.switchTo(_carol);
      await tester.pump();
      // The post is in flight: the dialog stays until it is answered, its controls disabled.
      expect(tester.widget<FilledButton>(approveButton()).onPressed, isNull);
      approvals.posts.single.$3.complete(right(const AddFriendResult(success: true, message: '您已和Alice成为好友')));
      await settle(tester);
      expect(find.text(atr.title), findsNothing);
      expect(find.text('您已和Alice成为好友'), findsNothing);
      expect(find.text(atr.failure.accountMismatch), findsOneWidget);
      expect(notifications.events, isEmpty);
    });

    testWidgets('after closing, the next approval acts for the account current then', (tester) async {
      final approvals = _Approvals();
      await openWithForm(tester, approvals);
      await tester.tap(cancelButton());
      await settle(tester);
      auth.switchTo(_carol);
      await tester.tap(find.text('open'));
      await tester.pump();
      expect(approvals.clientsFor, [_bob.uid, _carol.uid]);
      expect(approvals.loads, hasLength(2));
      await closeDialog(tester);
    });
  });
}
