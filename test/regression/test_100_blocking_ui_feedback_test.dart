import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart' show AuthStatus, AuthStatusAuthed;
import 'package:tsdm_client/features/blocking/cubit/user_block_cubit.dart';
import 'package:tsdm_client/features/blocking/models/notice_ignore.dart';
import 'package:tsdm_client/features/blocking/repository/notice_ignore_repository.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/features/blocking/view/user_block_page.dart';
import 'package:tsdm_client/features/blocking/widgets/block_aware_post.dart';
import 'package:tsdm_client/features/blocking/widgets/notice_ignore_actions.dart';
import 'package:tsdm_client/features/blocking/widgets/user_block_failure_listener.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/show_toast.dart';

/// Feedback of the blocking features: a Cloudflare interstitial answered with an error status, a forum rule added
/// from a notice card that goes away while the notice list reloads, a block list that can not be read, and the wording
/// of the manager page. Pages are synthetic, no real account or network.
const _aliceUid = 1000;
const _bobUid = 1001;
const _alice = UserLoginInfo(username: 'Alice', uid: _aliceUid);

Translations get tr => LocaleSettings.instance.currentTranslations;

/// Authentication whose current account the test controls.
final class _Auth extends Fake implements AuthenticationRepository {
  _Auth(this.currentUser);

  @override
  UserLoginInfo? currentUser;

  final _controller = StreamController<AuthStatus>.broadcast(sync: true);

  @override
  Stream<AuthStatus> get status => _controller.stream;

  @override
  int? get effectiveCurrentUid => currentUser?.uid;

  /// The same account reported again, like a login check at start.
  void authedAgain() => _controller.add(AuthStatusAuthed(currentUser!));

  Future<void> close() => _controller.close();
}

/// Settings rows kept in memory; reads of a block list fail while [failures] is positive.
final class _FlakySettings extends Fake implements StorageProvider {
  final rows = <String, List<String>>{};
  int failures = 0;
  int reads = 0;

  @override
  Future<List<String>?> getStringList(String key) async {
    reads++;
    if (failures > 0) {
      failures--;
      throw StateError('database is locked');
    }
    return rows[key];
  }

  @override
  Future<void> saveStringList(String key, List<String> value) async => rows[key] = List.of(value);

  @override
  Future<void> deleteKey(String key) async => rows.remove(key);
}

/// Forum rules answered by the test.
final class _Rules extends NoticeIgnoreRepository {
  _Rules([this.rules = const []]);

  final List<NoticeIgnoreRule> rules;
  final adds = <({NoticeIgnoreTarget target, bool everybody, Completer<NoticeIgnoreResult> answer})>[];

  @override
  Future<NoticeIgnoreResult> fetchRules(NetClientProvider client, {required int uid}) async =>
      NoticeIgnoreResult.success(rules);

  @override
  Future<NoticeIgnoreResult> addRule(
    NetClientProvider client, {
    required int uid,
    required NoticeIgnoreTarget target,
    required bool everybody,
  }) {
    final answer = Completer<NoticeIgnoreResult>();
    adds.add((target: target, everybody: everybody, answer: answer));
    return answer.future;
  }
}

/// Never answers: the rule repository is faked, the client is only built.
final class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

NetClientProvider _client(UserLoginInfo _) => NetClientProvider.buildNoCookie(
  dio: Dio()..httpClientAdapter = _OfflineAdapter(),
  cookie: CookieProvider.buildEmpty(),
);

/// A forum site answering the privacy page and the ignore form with the given answers.
final class _Site implements HttpClientAdapter {
  _Site({required this.privacy, this.ignoreForm, this.post});

  final ResponseBody Function() privacy;
  final ResponseBody Function()? ignoreForm;

  /// Answer to a write, the forum's success page when null.
  final ResponseBody Function()? post;
  int posts = 0;
  int privacyReads = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.method != 'GET') {
      posts++;
      return post?.call() ??
          _answer(200, '<html><body><div id="messagetext" class="alert_right"><p>ok</p></div></body></html>');
    }
    final q = options.uri.queryParameters;
    if (q['ac'] == 'privacy') {
      privacyReads++;
      return privacy();
    }
    return ignoreForm!();
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _answer(int status, String body, {Map<String, List<String>> headers = const {}}) =>
    ResponseBody.fromString(
      body,
      status,
      headers: {
        Headers.contentTypeHeader: ['text/html; charset=utf-8'],
        'server': ['cloudflare'],
        ...headers,
      },
    );

const _privacyPage =
    '''
<html><head><title>隐私筛选</title></head><body>
<div id="um"><p><strong class="vwmy"><a href="home.php?mod=space&amp;uid=$_aliceUid">Alice</a></strong></p></div>
<form method="post" autocomplete="off" action="home.php?mod=spacecp&amp;ac=privacy&amp;op=filter">
<input type="hidden" name="formhash" value="XXXXXXXX" />
<button type="submit" name="privacy2submit" value="true">保存</button>
</form></body></html>''';

/// The forum's form to ignore a notice type of an author (ajax), for Bob's `post` notices.
const _ignoreForm =
    '''
<?xml version="1.0" encoding="utf-8"?>
<root><![CDATA[<h3 class="flb"><em>屏蔽</em></h3>
<form method="post" autocomplete="off" id="ignoreform_x" name="ignoreform_x" action="home.php?mod=spacecp&ac=common&op=ignore&type=post">
<input type="hidden" name="referer" value="home.php?mod=space&do=notice">
<input type="hidden" name="ignoresubmit" value="true" />
<input type="hidden" name="formhash" value="XXXXXXXX" />
<input type="hidden" name="handlekey" value="noticeignore" />
<div class="c"><p><label><input type="radio" name="authorid" value="$_bobUid" checked="checked" />屏蔽该用户</label></p>
<p><label><input type="radio" name="authorid" value="0" />屏蔽所有人</label></p></div>
<p class="o pns"><button type="submit" name="ignoresubmitbtn" value="true" class="pn pnc"><strong>确定</strong></button></p>
</form>]]></root>''';

/// Managed challenge (403): its own title, stage element and challenge options.
const _managedChallenge = '''
<!DOCTYPE html><html lang="en-US"><head><title>Just a moment...</title></head><body>
<div class="main-wrapper"><div id="challenge-stage"></div></div>
<script>(function(){window._cf_chl_opt={cvId: '3',cZone: 'www.tsdm39.com',cType: 'managed'};})();</script>
</body></html>''';

/// Legacy browser check (503), without the `cf-mitigated` header.
const _legacyCheck = '''
<html><head><title>Just a moment...</title></head><body>
<div class="cf-browser-verification cf-im-under-attack"><div id="cf-content"><p>Checking your browser</p></div></div>
</body></html>''';

/// Block page (403, error 1020).
const _blockPage = '''
<html><head><title>Attention Required! | Cloudflare</title></head><body>
<div id="cf-wrapper"><div id="cf-error-details" class="cf-error-details-wrapper"><h1>Access denied</h1>
<p>Error code 1020</p></div></div></body></html>''';

/// A forum page answered with an error status, carrying the background script Cloudflare adds to every page.
const _forumErrorWithBackgroundScript = r'''
<html><head><title>提示信息</title></head><body>
<div id="messagetext" class="alert_error"><p>抱歉，您没有权限访问该页面</p></div>
<script>(function(){window.__CF$cv$params={r:'0',t:'MTc4ODAwMDAwMA=='};var a=document.createElement('script');
a.src='/cdn-cgi/challenge-platform/scripts/jsd/main.js';document.getElementsByTagName('head')[0].appendChild(a);})();
</script><script src="/cdn-cgi/challenge-platform/scripts/jsd/main.js"></script></body></html>''';

/// Stands in for the notice list: the card that opens the flow is replaced by a loading indicator, like the notice
/// page does on every reload (an auto sync).
class _NoticeList extends StatefulWidget {
  const _NoticeList({required this.target, required this.rules, super.key});

  final NoticeIgnoreTarget target;
  final _Rules rules;

  @override
  State<_NoticeList> createState() => _NoticeListState();
}

class _NoticeListState extends State<_NoticeList> {
  bool loading = false;

  void reload() => setState(() => loading = true);

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Text('reloading');
    }
    return Builder(
      builder: (context) => TextButton(
        onPressed: () async =>
            showNoticeIgnoreDialog(context, widget.target, repository: widget.rules, clientFactory: _client),
        child: const Text('ignore'),
      ),
    );
  }
}

/// Pumps frames without waiting for indeterminate progress indicators to end.
Future<void> _frames(WidgetTester tester, [int count = 6]) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Map<String, String> _flatten(Map<String, dynamic> map, [String prefix = '']) => {
  for (final e in map.entries)
    ...switch (e.value) {
      final Map<String, dynamic> inner => _flatten(inner, '$prefix${e.key}.'),
      final Object? value => {'$prefix${e.key}': '$value'},
    },
};

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
  });

  group('Cloudflare interstitial answered with an error status', () {
    setUp(() {
      getIt
        ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
        ..registerSingleton<NetErrorSaver>(NetErrorSaver());
    });

    tearDown(getIt.reset);

    const repo = NoticeIgnoreRepository();

    NetClientProvider clientOf(_Site site) =>
        NetClientProvider.build(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = site);

    final challenges = <String, ResponseBody Function()>{
      '403 managed challenge': () => _answer(
        403,
        _managedChallenge,
        headers: {
          'cf-mitigated': ['challenge'],
        },
      ),
      '403 marked by cf-mitigated only': () => _answer(
        403,
        '',
        headers: {
          'cf-mitigated': ['challenge'],
        },
      ),
      '503 legacy browser check': () => _answer(503, _legacyCheck),
      '403 block page': () => _answer(403, _blockPage),
    };

    for (final MapEntry(key: name, value: answer) in challenges.entries) {
      test('loading the rules reports the challenge: $name', () async {
        final site = _Site(privacy: answer);
        final result = await repo.fetchRules(clientOf(site), uid: _aliceUid);
        expect(result.failure, NoticeIgnoreFailure.challenge);
        expect(site.posts, 0);
      });
    }

    for (final status in [403, 500, 503]) {
      test('a forum page answered $status with the background script is a network failure', () async {
        final site = _Site(privacy: () => _answer(status, _forumErrorWithBackgroundScript));
        final result = await repo.fetchRules(clientOf(site), uid: _aliceUid);
        expect(result.failure, NoticeIgnoreFailure.network);
      });
    }

    test('a write stopped by Cloudflare is reported as the challenge, with the rules read again', () async {
      final site = _Site(
        privacy: () => _answer(200, _privacyPage),
        ignoreForm: () => _answer(200, _ignoreForm),
        post: challenges['403 managed challenge'],
      );
      final result = await repo.addRule(
        clientOf(site),
        uid: _aliceUid,
        target: const NoticeIgnoreTarget(type: 'post', authorId: _bobUid),
        everybody: false,
      );
      expect(result.failure, NoticeIgnoreFailure.challenge);
      expect(result.rules, isEmpty, reason: 'read again: the page shows the rules as they are');
      expect(site.posts, 1);
      expect(site.privacyReads, 2);
    });

    test('a challenge on the ignore form stops the rule before anything is sent', () async {
      final site = _Site(
        privacy: () => _answer(200, _privacyPage),
        ignoreForm: challenges['403 managed challenge'],
      );
      final result = await repo.addRule(
        clientOf(site),
        uid: _aliceUid,
        target: const NoticeIgnoreTarget(type: 'post', authorId: _bobUid),
        everybody: false,
      );
      expect(result.failure, NoticeIgnoreFailure.challenge);
      expect(site.posts, 0);
    });
  });

  group('forum rule added from a notice', () {
    late _Auth auth;

    setUp(() => auth = _Auth(_alice));
    tearDown(() => auth.close());

    Future<GlobalKey<_NoticeListState>> pump(WidgetTester tester, NoticeIgnoreTarget target, _Rules rules) async {
      final list = GlobalKey<_NoticeListState>();
      await tester.pumpWidget(
        TranslationProvider(
          child: RepositoryProvider<AuthenticationRepository>.value(
            value: auth,
            child: MaterialApp(
              scaffoldMessengerKey: snackbarKey,
              home: Scaffold(
                body: Column(
                  children: [
                    _NoticeList(key: list, target: target, rules: rules),
                    const Text('another notice'),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      return list;
    }

    testWidgets('goes on when the notice list reloads, shows its progress and its result', (tester) async {
      final rules = _Rules();
      final list = await pump(tester, const NoticeIgnoreTarget(type: 'post', authorId: _bobUid), rules);
      final serverRules = tr.userBlock.serverRules;
      await tester.tap(find.text('ignore'));
      await tester.pumpAndSettle();

      // An auto sync reloads the notice list while the choice is open: the card that opened the flow is gone.
      list.currentState!.reload();
      await tester.pumpAndSettle();
      expect(find.text('ignore'), findsNothing);
      await tester.tap(find.text(serverRules.ignoreThisUser(type: serverRules.types.post)));
      await tester.pumpAndSettle();
      expect(find.text(serverRules.confirmTitle), findsOneWidget, reason: 'the confirmation is still asked');
      await tester.tap(find.text(tr.general.ok));
      await _frames(tester);
      expect(rules.adds, hasLength(1));
      expect(rules.adds.single.everybody, isFalse);
      expect(find.text(serverRules.submitting), findsOneWidget);

      // A second rule can not be started while the forum answers.
      unawaited(
        showNoticeIgnoreDialog(
          tester.element(find.text('another notice')),
          const NoticeIgnoreTarget(type: 'post', authorId: _bobUid),
          repository: rules,
          clientFactory: _client,
        ),
      );
      await _frames(tester);
      expect(find.text(serverRules.busy), findsOneWidget);
      expect(find.text(serverRules.hint), findsNothing, reason: 'no second choice dialog');
      expect(rules.adds, hasLength(1));
      snackbarKey.currentState!.removeCurrentSnackBar();

      rules.adds.single.answer.complete(const NoticeIgnoreResult.success([]));
      await _frames(tester, 12);
      expect(find.text(serverRules.submitting), findsNothing);
      expect(find.text(serverRules.success), findsOneWidget);
    });

    testWidgets('a rule the forum already has is not reported as updated', (tester) async {
      final rules = _Rules();
      await pump(tester, const NoticeIgnoreTarget(type: 'post', authorId: _bobUid), rules);
      final serverRules = tr.userBlock.serverRules;
      await tester.tap(find.text('ignore'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(serverRules.ignoreEverybody(type: serverRules.types.post)));
      await tester.pumpAndSettle();
      await tester.tap(find.text(tr.general.ok));
      await _frames(tester);
      rules.adds.single.answer.complete(
        const NoticeIgnoreResult.success([NoticeIgnoreRule(type: 'post', authorId: 0)], alreadyApplied: true),
      );
      await _frames(tester, 12);
      expect(find.text(serverRules.alreadyApplied), findsOneWidget);
      expect(find.text(serverRules.success), findsNothing);
    });

    testWidgets('the dialog names notice types, unknown ones keep the forum code', (tester) async {
      final serverRules = tr.userBlock.serverRules;
      await pump(tester, const NoticeIgnoreTarget(type: 'pcomment', authorId: _bobUid), _Rules());
      await tester.tap(find.text('ignore'));
      await tester.pumpAndSettle();
      expect(find.text(serverRules.ignoreThisUser(type: serverRules.types.pcomment)), findsOneWidget);
      expect(find.text(serverRules.ignoreThisUser(type: 'pcomment')), findsNothing);
      await tester.tapAt(Offset.zero);
      await tester.pumpAndSettle();

      await pump(tester, const NoticeIgnoreTarget(type: 'newtype', authorId: _bobUid), _Rules());
      await tester.tap(find.text('ignore'));
      await tester.pumpAndSettle();
      expect(find.text(serverRules.ignoreThisUser(type: 'newtype')), findsOneWidget);
    });
  });

  group('block list that can not be read', () {
    late _Auth auth;
    late _FlakySettings settings;
    late UserBlockRepository blocks;

    setUp(() {
      auth = _Auth(_alice);
      settings = _FlakySettings();
      blocks = UserBlockRepository(settings);
    });

    tearDown(() async {
      await blocks.dispose();
      await auth.close();
    });

    UserBlockCubit cubitWith(List<Duration> retryDelays) {
      final cubit = UserBlockCubit(
        repository: blocks,
        currentUid: () => auth.currentUser?.uid,
        authStatus: auth.status,
        retryDelays: retryDelays,
      );
      addTearDown(cubit.close);
      return cubit;
    }

    const post = Post(
      postID: '2',
      postFloor: 2,
      author: User(name: 'Bob', uid: '$_bobUid', url: 'home.php?mod=space&uid=$_bobUid'),
      publishTime: null,
      data: 'hello from Bob',
      replyAction: null,
      rateAction: null,
      lastEditUsername: null,
      lastEditTime: null,
      shareLink: null,
      page: 1,
      isDraft: false,
      packetAllTaken: false,
    );

    Future<void> pumpPost(WidgetTester tester, UserBlockCubit cubit) => tester.pumpWidget(
      TranslationProvider(
        child: BlocProvider<UserBlockCubit>.value(
          value: cubit,
          child: MaterialApp(
            home: Scaffold(
              body: BlockAwarePost(post: post, postList: const [post], builder: (_, p) => Text(p.data)),
            ),
          ),
        ),
      ),
    );

    testWidgets('a held back floor says the read failed, and the list is read again on its own', (tester) async {
      settings.failures = 1;
      final cubit = cubitWith(const [Duration(seconds: 1)]);
      await pumpPost(tester, cubit);
      await tester.pump();
      expect(cubit.state.status, UserBlockListStatus.failed);
      expect(find.text(tr.userBlock.loadFailed), findsOneWidget);
      expect(find.text(tr.userBlock.listPending), findsNothing, reason: 'a failure is not "reading"');
      expect(find.text('hello from Bob'), findsNothing);

      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(cubit.state.status, UserBlockListStatus.ready);
      expect(find.text('hello from Bob'), findsOneWidget);
    });

    testWidgets('the thread notice says the read failed', (tester) async {
      await tester.pumpWidget(
        TranslationProvider(
          child: const MaterialApp(
            home: Scaffold(
              body: BlockedThreadNotice(uid: _bobUid, username: 'Bob', pending: true, failed: true),
            ),
          ),
        ),
      );
      expect(find.text(tr.userBlock.loadFailed), findsOneWidget);
      expect(find.text(tr.userBlock.listPending), findsNothing);
    });

    testWidgets('automatic reads stop after the last delay, an auth event of the same account reads again', (
      tester,
    ) async {
      settings.failures = 3;
      final cubit = cubitWith(const [Duration(seconds: 1)]);
      await pumpPost(tester, cubit);
      await tester.pump();
      expect(settings.reads, 1);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(settings.reads, 2);
      await tester.pump(const Duration(minutes: 10));
      expect(settings.reads, 2, reason: 'no endless reads of a row that stays unreadable');
      expect(cubit.state.status, UserBlockListStatus.failed);

      settings.failures = 0;
      auth.authedAgain();
      await tester.pump();
      await tester.pump();
      expect(settings.reads, 3);
      expect(cubit.state.status, UserBlockListStatus.ready);
      expect(find.text('hello from Bob'), findsOneWidget);
    });

    /// The app wide failure hint over a page, the cubit created with the tree like in the app, so the listener is
    /// there before the first read ends.
    Future<UserBlockCubit> pumpApp(WidgetTester tester, List<Duration> retryDelays) async {
      late UserBlockCubit cubit;
      await tester.pumpWidget(
        TranslationProvider(
          child: BlocProvider<UserBlockCubit>(
            lazy: false,
            create: (_) => cubit = UserBlockCubit(
              repository: blocks,
              currentUid: () => auth.currentUser?.uid,
              authStatus: auth.status,
              retryDelays: retryDelays,
            ),
            child: UserBlockFailureListener(
              child: MaterialApp(
                scaffoldMessengerKey: snackbarKey,
                home: const Scaffold(body: Text('forum threads')),
              ),
            ),
          ),
        ),
      );
      return cubit;
    }

    void showOther(WidgetTester tester, String message) =>
        showSnackBar(context: tester.element(find.text('forum threads')), message: message);

    final hint = find.text(tr.userBlock.loadFailedHint);

    testWidgets('the app says why lists are empty, with a retry, once per failure', (tester) async {
      settings.failures = 3;
      final cubit = await pumpApp(tester, const [Duration(seconds: 1)]);
      await tester.pumpAndSettle();
      expect(cubit.state.status, UserBlockListStatus.failed);
      expect(find.text(tr.userBlock.loadFailedHint), findsOneWidget);

      // The retry of the hint reads the list again; failing again is told again.
      await tester.tap(find.text(tr.general.retry));
      await tester.pumpAndSettle();
      expect(settings.reads, 2);
      expect(find.text(tr.userBlock.loadFailedHint), findsOneWidget);
      snackbarKey.currentState!.removeCurrentSnackBar();
      await tester.pumpAndSettle();

      // An automatic read that fails again does not repeat the hint.
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(settings.reads, 3);
      expect(cubit.state.status, UserBlockListStatus.failed);
      expect(find.text(tr.userBlock.loadFailedHint), findsNothing);
    });

    testWidgets('the hint goes away once the list is read, later messages show at once', (tester) async {
      settings.failures = 1;
      final cubit = await pumpApp(tester, const [Duration(seconds: 2)]);
      await tester.pumpAndSettle();
      expect(hint, findsOneWidget);

      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(cubit.state.status, UserBlockListStatus.ready);
      expect(hint, findsNothing, reason: 'closed by the read, long before its own timeout');
      showOther(tester, 'other message');
      await tester.pumpAndSettle();
      expect(find.text('other message'), findsOneWidget);
    });

    testWidgets('a list that stays unreadable does not keep the hint or hold up other messages', (tester) async {
      settings.failures = 10;
      await pumpApp(tester, const []);
      await tester.pumpAndSettle();
      expect(hint, findsOneWidget);
      showOther(tester, 'other message');
      await tester.pumpAndSettle();
      expect(find.text('other message'), findsNothing, reason: 'waits behind the hint');

      await tester.pump(UserBlockFailureListener.visibleFor);
      await tester.pumpAndSettle();
      expect(hint, findsNothing);
      expect(find.text('other message'), findsOneWidget);
    });

    void switchToBob() {
      auth
        ..currentUser = const UserLoginInfo(username: 'Bob', uid: _bobUid)
        ..authedAgain();
    }

    testWidgets('the hint of one account goes away when another account is used', (tester) async {
      settings.failures = 1;
      await pumpApp(tester, const []);
      await tester.pumpAndSettle();
      expect(hint, findsOneWidget);

      switchToBob();
      await tester.pumpAndSettle();
      expect(hint, findsNothing);
    });

    testWidgets('a hint waiting behind another message is dropped when the list is read before its turn', (
      tester,
    ) async {
      final cubit = await pumpApp(tester, const [Duration(seconds: 1)]);
      await tester.pumpAndSettle();
      snackbarKey.currentState!.showSnackBar(const SnackBar(content: Text('earlier'), duration: Duration(minutes: 1)));
      await tester.pumpAndSettle();

      settings.failures = 1;
      switchToBob();
      await tester.pump();
      expect(cubit.state.status, UserBlockListStatus.failed);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(cubit.state.status, UserBlockListStatus.ready);

      snackbarKey.currentState!.hideCurrentSnackBar();
      await tester.pumpAndSettle();
      expect(find.text('earlier'), findsNothing);
      expect(hint, findsNothing, reason: 'no longer true when its turn came');
      showOther(tester, 'later');
      await tester.pumpAndSettle();
      expect(find.text('later'), findsOneWidget);
    });

    testWidgets('failing again while the hint waits still shows one hint, once', (tester) async {
      final cubit = await pumpApp(tester, const []);
      await tester.pumpAndSettle();
      snackbarKey.currentState!.showSnackBar(const SnackBar(content: Text('earlier'), duration: Duration(minutes: 1)));
      await tester.pumpAndSettle();

      settings.failures = 10;
      switchToBob();
      await tester.pump();
      // A retry from another page (the manager page) that fails again.
      await cubit.reload();
      await tester.pump();
      expect(settings.reads, 3);
      expect(cubit.state.status, UserBlockListStatus.failed);

      snackbarKey.currentState!.hideCurrentSnackBar();
      await tester.pumpAndSettle();
      expect(hint, findsOneWidget);
      await tester.pump(UserBlockFailureListener.visibleFor);
      await tester.pumpAndSettle();
      expect(hint, findsNothing, reason: 'no second hint behind the first one');
    });

    testWidgets('a hint dropped from the queue by another message clearing it is shown again on the next failure', (
      tester,
    ) async {
      final cubit = await pumpApp(tester, const []);
      await tester.pumpAndSettle();
      snackbarKey.currentState!.showSnackBar(const SnackBar(content: Text('earlier'), duration: Duration(minutes: 1)));
      await tester.pumpAndSettle();

      settings.failures = 100;
      switchToBob();
      await tester.pump();
      expect(cubit.state.status, UserBlockListStatus.failed);
      // The hint waits behind "earlier"; a message that clears previous ones drops it from the queue for good.
      showSnackBar(context: tester.element(find.text('forum threads')), message: 'favorite added', clearPrevious: true);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
      expect(hint, findsNothing);

      // A retry that fails again tells again.
      await cubit.reload();
      await tester.pumpAndSettle();
      expect(cubit.state.status, UserBlockListStatus.failed);
      expect(hint, findsOneWidget);
    });
  });

  group('manager page', () {
    late _Auth auth;
    late UserBlockRepository blocks;

    setUp(() {
      auth = _Auth(_alice);
      blocks = UserBlockRepository(_FlakySettings());
    });

    tearDown(() async {
      await blocks.dispose();
      await auth.close();
    });

    Future<void> pumpPage(WidgetTester tester, _Rules rules) async {
      final cubit = UserBlockCubit(repository: blocks, currentUid: () => _aliceUid, authStatus: auth.status);
      addTearDown(cubit.close);
      await tester.pumpWidget(
        TranslationProvider(
          child: RepositoryProvider<AuthenticationRepository>.value(
            value: auth,
            child: BlocProvider<UserBlockCubit>.value(
              value: cubit,
              child: MaterialApp(
                scaffoldMessengerKey: snackbarKey,
                home: UserBlockPage(noticeIgnoreRepository: rules, clientFactory: _client),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('the hint before loading points at the button above it', (tester) async {
      await pumpPage(tester, _Rules());
      final serverRules = tr.userBlock.serverRules;
      final hint = find.text(serverRules.notLoaded);
      await tester.ensureVisible(hint);
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(hint).dy, greaterThan(tester.getTopLeft(find.text(serverRules.load)).dy));
      expect(serverRules.notLoaded, contains('above'));
    });

    testWidgets('rules are named by notice type and removed under the name shown', (tester) async {
      await pumpPage(
        tester,
        _Rules(const [
          NoticeIgnoreRule(type: 'post', authorId: _bobUid),
          NoticeIgnoreRule(type: 'pcomment', authorId: 0, label: 'forum text'),
          // The privacy page prints the bare type of the types it has no name for.
          NoticeIgnoreRule(type: 'at', authorId: _bobUid, label: 'at (Bob)'),
        ]),
      );
      final serverRules = tr.userBlock.serverRules;
      await tester.tap(find.byIcon(Icons.cloud_sync_outlined));
      await tester.pumpAndSettle();
      final post = '${serverRules.types.post} · ${serverRules.userUid(uid: '$_bobUid')}';
      final pcomment = '${serverRules.types.pcomment} · ${serverRules.everybody}';
      await tester.ensureVisible(find.byKey(const ValueKey('rule-pcomment|0')));
      await tester.pumpAndSettle();
      expect(find.text(post), findsNWidgets(2), reason: 'title and subtitle without a forum text');
      expect(find.text(pcomment), findsOneWidget);
      expect(find.text('forum text'), findsOneWidget);
      expect(find.textContaining('post ·'), findsNothing);

      Future<void> removeAndCancel(String key, String name) async {
        await tester.tap(find.descendant(of: find.byKey(ValueKey(key)), matching: find.text(serverRules.remove)));
        await _frames(tester);
        expect(find.text(serverRules.removeConfirmContent(rule: name)), findsOneWidget);
        await tester.tap(find.text(tr.general.cancel));
        await _frames(tester);
      }

      await removeAndCancel('rule-post|$_bobUid', post);
      await removeAndCancel('rule-pcomment|0', 'forum text');

      final at = '${serverRules.types.at} (Bob)';
      await tester.ensureVisible(find.byKey(const ValueKey('rule-at|$_bobUid')));
      await tester.pumpAndSettle();
      expect(find.text(at), findsOneWidget);
      expect(find.text('at (Bob)'), findsNothing);
      await removeAndCancel('rule-at|$_bobUid', at);
    });
  });

  group('copy', () {
    Map<String, String> strings(String locale) => _flatten(
      (jsonDecode(File('lib/i18n/$locale.i18n.json').readAsStringSync()) as Map<String, dynamic>)['userBlock']
          as Map<String, dynamic>,
    );

    test('the three languages have the same keys and placeholders', () {
      final en = strings('en');
      for (final locale in ['zh-CN', 'zh-TW']) {
        final other = strings(locale);
        expect(other.keys.toSet(), en.keys.toSet(), reason: locale);
        final placeholder = RegExp(r'\$\{\w+\}');
        for (final key in en.keys) {
          Set<String> of(String s) => placeholder.allMatches(s).map((m) => m[0]!).toSet();
          expect(of(other[key]!), of(en[key]!), reason: '$locale $key');
        }
      }
    });

    test('an old notice does not send the user to sync, and the limits of the local block are named', () {
      for (final (locale, sync, guide) in [
        ('en', 'sync', 'homepage guide'),
        ('zh-CN', '同步', '导读'),
        ('zh-TW', '同步', '導讀'),
      ]) {
        final s = strings(locale);
        expect(s['serverRules.notAvailable'], isNot(contains(sync)), reason: locale);
        expect(s['localHint'], contains(guide), reason: locale);
      }
    });

    test('notice type names fit in "... 「type」提醒" without repeating 提醒', () {
      for (final locale in ['zh-CN', 'zh-TW']) {
        final s = strings(locale);
        final types = s.entries.where((e) => e.key.startsWith('serverRules.types.'));
        expect(types, isNotEmpty);
        for (final MapEntry(:key, :value) in types) {
          expect(value, isNot(endsWith('提醒')), reason: '$locale $key');
        }
        for (final key in ['serverRules.ignoreThisUser', 'serverRules.ignoreEverybody']) {
          expect(s[key], contains('」提醒'), reason: '$locale $key');
        }
      }
    });
  });
}
