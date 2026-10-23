/// The small user experience fixes of the 2026-10-23 audit (`fix/ux-small`), one group each:
///
/// 1. leaving the post editor with content not sent asks first (discard, save as a draft, keep editing);
/// 2. replies and private messages are posted once, a failure after the request left says "may have been sent";
/// 3. a private message that failed always says so and keeps the editor;
/// 4. `goto=lastpost` opens the last page on its last floor;
/// 5. the image cache is looked up by key;
/// 6. the text scale is the system font size times the app's own scale, within its limits;
/// 7. a forum page that failed to go on with the list keeps the list;
/// 8. the search and "my threads" tell their failures, the search its rate limit;
/// 9. the last page of a thread ends with "the last floor", no snack bar at every pull;
/// 10. the next page is the one after the last loaded, the floors appended once (by pid);
/// 11. back on another home tab goes to the homepage first;
/// 12. the notification permission is asked with a card, after a login or on the notice page, never for a guest;
/// 14. a saved image is named with the extension of its type;
/// 15. zh-TW wording; the app bar of the thread page hides while scrolling down;
/// and avatars answering 404 are not asked again in the same run, the image cache is cleaned up by default.
library;

// Answers of the forum are split into lines at tag boundaries.
// ignore_for_file: missing_whitespace_between_adjacent_strings

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart' hide State;
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/blocking/cubit/user_block_cubit.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/features/blocking/utils/thread_author_cache.dart';
import 'package:tsdm_client/features/chat/view/chat_history_page.dart';
import 'package:tsdm_client/features/chat/view/chat_page.dart';
import 'package:tsdm_client/features/favorite/repository/favorite_repository.dart';
import 'package:tsdm_client/features/forum/bloc/forum_bloc.dart';
import 'package:tsdm_client/features/forum/models/models.dart';
import 'package:tsdm_client/features/forum/repository/forum_repository.dart';
import 'package:tsdm_client/features/forum/utils/forum_page_parser.dart';
import 'package:tsdm_client/features/home/cubit/home_cubit.dart';
import 'package:tsdm_client/features/jump_page/cubit/jump_page_cubit.dart';
import 'package:tsdm_client/features/local_notice/notification_permission_prompt.dart';
import 'package:tsdm_client/features/my_thread/bloc/my_thread_bloc.dart';
import 'package:tsdm_client/features/my_thread/repository/my_thread_repository.dart';
import 'package:tsdm_client/features/my_thread/view/my_thread_page.dart';
import 'package:tsdm_client/features/notification/bloc/notification_bloc.dart';
import 'package:tsdm_client/features/notification/bloc/notification_state_cubit.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/features/notification/repository/notification_info_repository.dart';
import 'package:tsdm_client/features/notification/view/notification_detail_page.dart';
import 'package:tsdm_client/features/offline_thread/repository/offline_thread_repository.dart';
import 'package:tsdm_client/features/post/bloc/post_edit_bloc.dart';
import 'package:tsdm_client/features/post/models/models.dart';
import 'package:tsdm_client/features/post/repository/post_edit_repository.dart';
import 'package:tsdm_client/features/post/view/post_edit_page.dart';
import 'package:tsdm_client/features/post/widgets/leave_edit_dialog.dart';
import 'package:tsdm_client/features/root/view/root_page.dart';
import 'package:tsdm_client/features/search/bloc/search_bloc.dart';
import 'package:tsdm_client/features/search/repository/search_repository.dart';
import 'package:tsdm_client/features/search/view/search_page.dart';
import 'package:tsdm_client/features/settings/bloc/android_permission_cubit.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/thread/v1/bloc/thread_bloc.dart';
import 'package:tsdm_client/features/thread/v1/repository/thread_repository.dart';
import 'package:tsdm_client/features/thread/v1/utils/parse_thread_document.dart';
import 'package:tsdm_client/features/thread/v1/view/thread_page.dart';
import 'package:tsdm_client/features/thread/v1/widgets/collapsing_app_bar.dart';
import 'package:tsdm_client/features/thread/v1/widgets/post_list.dart';
import 'package:tsdm_client/features/thread_visit_history/bloc/thread_visit_history_bloc.dart';
import 'package:tsdm_client/features/thread_visit_history/repository/thread_visit_history_repository.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/models/models.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider_android.dart'
    show KotlinHttpClient, KotlinHttpClientAdapter, singleAttemptHttpRequestKey;
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/shared/repositories/fragments_repository/fragments_repository.dart';
import 'package:tsdm_client/utils/app_text_scale.dart';
import 'package:tsdm_client/utils/image_file_name.dart';
import 'package:tsdm_client/utils/load_failure.dart';
import 'package:tsdm_client/widgets/failure_view.dart';
import 'package:tsdm_client/widgets/list_footer.dart';
import 'package:tsdm_client/widgets/reply_bar/bloc/reply_bloc.dart';
import 'package:tsdm_client/widgets/reply_bar/reply_bar.dart';
import 'package:tsdm_client/widgets/reply_bar/repository/reply_repository.dart';

const _alice = UserLoginInfo(username: 'Alice', uid: 31);

/// A request the fake forum saw.
typedef _Request = ({String method, Uri uri, String body, bool singleAttempt});

/// An answer of the fake forum: a body, or an exception thrown as the transport would.
typedef _Answer = ({String body, int status, String contentType, Object? error});

_Answer _html(String body, {int status = 200}) =>
    (body: body, status: status, contentType: 'text/html; charset=utf-8', error: null);

_Answer _xml(String body) => (body: body, status: 200, contentType: 'text/xml; charset=utf-8', error: null);

_Answer _json(Object json) =>
    (body: jsonEncode(json), status: 200, contentType: 'application/json; charset=utf-8', error: null);

_Answer _throws(DioExceptionType type) => (body: '', status: 0, contentType: '', error: type);

/// The forum: answers every request through [answer], and records them.
final class _Forum implements HttpClientAdapter {
  _Forum(this.answer);

  FutureOr<_Answer> Function(_Request request) answer;
  final requests = <_Request>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    var body = '';
    if (requestStream != null) {
      body = utf8.decode(await requestStream.fold<List<int>>([], (a, b) => a..addAll(b)), allowMalformed: true);
    }
    final request = (
      method: options.method,
      uri: options.uri,
      body: body,
      singleAttempt: options.extra[singleAttemptHttpRequestKey] == true,
    );
    requests.add(request);
    final a = await answer(request);
    if (a.error case final DioExceptionType type) {
      throw DioException(requestOptions: options, type: type, message: 'fake ${type.name}');
    }
    return ResponseBody.fromString(
      a.body,
      a.status,
      headers: {
        Headers.contentTypeHeader: [a.contentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Every image request fails at once.
final class _OfflineAdapter implements HttpClientAdapter {
  int requests = 0;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) {
    requests++;
    throw DioException.connectionError(requestOptions: options, reason: 'offline');
  }

  @override
  void close({bool force = false}) {}
}

/// A platform scaler that grows small text more than large text, as Android 14 does.
final class _NonlinearScaler extends TextScaler {
  const _NonlinearScaler();

  @override
  double scale(double fontSize) => fontSize * (fontSize < 20 ? 1.3 : 1.1);

  @override
  @Deprecated('Use scale instead.')
  double get textScaleFactor => 1.3;
}

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

/// The permission plugin, as the Android system answers it.
final class _Gateway implements AndroidPermissionGateway {
  _Gateway(this.notification);

  PermissionStatus notification;
  PermissionStatus answer = PermissionStatus.granted;
  int requests = 0;

  @override
  Future<PermissionStatus> status(Permission permission) async =>
      permission == Permission.notification ? notification : PermissionStatus.granted;

  @override
  Future<PermissionStatus> request(Permission permission) async {
    requests++;
    notification = answer;
    return answer;
  }

  int settingsOpened = 0;

  /// Whether the system would still show its dialog (false: switched off in the system settings).
  bool rationale = true;

  @override
  Future<bool> openSettings() async {
    settingsOpened++;
    return true;
  }

  @override
  Future<bool> shouldShowRationale(Permission permission) async => rationale;
}

String _floor(int pid, {int? floor}) =>
    '''
<div id="post_$pid"><table><tbody><tr>
<td class="pls"></td>
<td class="plc"><div class="pi"><strong><a href="forum.php?mod=redirect&goto=findpost&pid=$pid"><em>${floor ?? pid}</em></a>
</strong><div class="authi"><a href="home.php?mod=space&amp;uid=1000" class="xi2">Bob</a></div></div>
<div class="pct"><div class="pcb"><div class="t_f" id="postmessage_$pid">floor $pid text</div></div></div></td>
</tr></tbody></table></div>''';

/// A thread page with [pids], page [page] of [pages] (no pager for a thread of one page, as the forum prints it).
String _threadPage(List<int> pids, {int page = 1, int pages = 1}) {
  final pager = pages <= 1
      ? ''
      : '<div class="pg">${[
          for (var i = 1; i <= pages; i++) i == page ? '<strong>$i</strong>' : '<a href="forum.php?mod=viewthread&tid=1264975&page=$i">$i</a>',
        ].join()}<label><input type="text" name="custompage"/><span title="共 $pages 页"> / $pages 页</span></label></div>';
  return '''
<html><head><link rel="canonical" href="forum.php?mod=viewthread&tid=1264975" /></head><body>
$pager
<div id="postlist"><h1 class="ts"><span id="thread_subject">Thread title</span></h1><div class="bm">
${pids.map(_floor).join('\n')}
</div></div>
</body></html>''';
}

Post _post(String pid, {int page = 1, bool hot = false}) => Post(
  postID: pid,
  postFloor: int.tryParse(pid),
  author: const User(name: 'u', url: 'u'),
  publishTime: DateTime(2026, 10, 23),
  data: 'body $pid',
  replyAction: null,
  rateAction: null,
  lastEditUsername: null,
  lastEditTime: null,
  shareLink: null,
  page: page,
  isDraft: false,
  packetAllTaken: false,
  hot: hot,
);

final class _FakeForumRepository extends ForumRepository {
  _FakeForumRepository();

  bool failing = false;
  final asked = <int>[];

  @override
  AsyncEither<ForumPageData> fetchForum({required String fid, required FilterState filterState, int pageNumber = 1}) =>
      AsyncEither(() async {
        asked.add(pageNumber);
        if (failing) return left(HttpHandshakeFailedException('offline', connectionFailed: true));
        return right(
          ForumPageData(
            title: 'forum',
            rulesElement: null,
            normalThreadList: [
              for (final tid in [pageNumber * 10, pageNumber * 10 + 1])
                NormalThread(
                  title: 'thread $tid',
                  url: '$baseUrl/forum.php?mod=viewthread&tid=$tid',
                  threadID: '$tid',
                  author: const User(name: 'a', url: ''),
                  publishDate: null,
                  latestReplyAuthor: const User(name: 'a', url: ''),
                  latestReplyTime: null,
                  iconUrl: '',
                  threadType: null,
                  replyCount: 0,
                  viewCount: 0,
                  price: null,
                  css: null,
                  stateSet: const {},
                  privilege: null,
                  isRecentThread: false,
                ),
            ],
            stickThreadList: const [],
            subredditList: const [],
            needLogin: false,
            havePermission: true,
            permissionDeniedMessage: null,
            canLoadMore: pageNumber < 3,
            currentPage: pageNumber,
            totalPages: 3,
            filterTypeList: const [],
            filterSpecialTypeList: const [],
            filterOrderList: const [],
            filterDatelineList: const [],
          ),
        );
      });
}

const _replyParameters = ReplyParameters(
  fid: '2',
  tid: '9600001',
  postTime: '1700000000',
  formHash: 'f1f2f3f4',
  subject: '',
  viewerUid: 31,
);

void main() {
  late AppDatabase db;
  late StorageProvider storage;
  late SettingsRepository settings;
  late SettingsBloc settingsBloc;
  late _Forum forum;
  late _OfflineAdapter images;

  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.zhTw);
  });

  setUp(() async {
    TsdmAppApi.reset();
    db = AppDatabase(NativeDatabase.memory());
    storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
    forum = _Forum((r) => fail('unexpected request: ${r.method} ${r.uri}'));
    images = _OfflineAdapter();
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings)
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
      ..registerFactory<NetClientProvider>(
        () => NetClientProvider.buildNoCookie(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum),
      )
      ..registerSingleton<ImageCacheProvider>(
        ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = images)),
      );
    await settings.init();
    settingsBloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository());
    ThreadAuthorCache.clear();
  });

  tearDown(() async {
    await settingsBloc.close();
    await getIt.get<ImageCacheProvider>().dispose();
    await getIt.reset();
    await settings.dispose();
    await db.close();
  });

  /// [child] under the providers of the app.
  Widget app(Widget child, {AuthenticationRepository? auth}) => TranslationProvider(
    child: RepositoryProvider<AuthenticationRepository>.value(
      value: auth ?? AuthenticationRepository(user: _alice),
      child: BlocProvider<SettingsBloc>.value(value: settingsBloc, child: child),
    ),
  );

  group('1. leaving the post editor', () {
    Future<GoRouter> pumpEditor(WidgetTester tester) async {
      final form = jsonDecode(File('test/data/tsdmapp/post_v16_newthread.json').readAsStringSync());
      forum.answer = (r) => _json(form as Object);
      final auth = AuthenticationRepository(user: _alice);
      addTearDown(auth.dispose);
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => const Scaffold(body: Text('below the editor')),
            routes: [
              GoRoute(
                path: 'edit',
                builder: (_, _) => const PostEditPage(editType: PostEditType.newThread, fid: '7', tid: null, pid: null),
              ),
            ],
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        app(
          MaterialApp.router(routerConfig: router, scaffoldMessengerKey: snackbarKey),
          auth: auth,
        ),
      );
      unawaited(router.push('/edit'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pumpAndSettle();
      return router;
    }

    Future<void> back(WidgetTester tester) async {
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
    }

    testWidgets('an empty editor is left at once', (tester) async {
      await pumpEditor(tester);
      expect(find.byType(PostEditPage), findsOneWidget);
      await back(tester);
      expect(find.text(t.postEditPage.leaveDialog.title), findsNothing);
      expect(find.text('below the editor'), findsOneWidget);
    });

    testWidgets('with a title typed: discard, save as a draft or keep editing', (tester) async {
      await pumpEditor(tester);
      await tester.enterText(find.byType(TextFormField).first, '標題');
      await tester.pump();
      await back(tester);
      expect(find.text(t.postEditPage.leaveDialog.title), findsOneWidget);
      expect(find.byKey(const ValueKey('leave-edit-discard')), findsOneWidget);
      // The form offers drafts (`draft.can_save`).
      expect(find.byKey(const ValueKey('leave-edit-save-draft')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('leave-edit-keep')));
      await tester.pumpAndSettle();
      expect(find.byType(PostEditPage), findsOneWidget, reason: 'keep editing stays');
      expect(find.text('標題'), findsWidgets, reason: 'the content stays');

      await back(tester);
      await tester.tap(find.byKey(const ValueKey('leave-edit-discard')));
      await tester.pumpAndSettle();
      expect(find.text('below the editor'), findsOneWidget);
      expect(forum.requests.where((r) => r.method == 'POST'), isEmpty, reason: 'nothing was sent');
    });

    testWidgets('the dialog offers no draft when the form takes none', (tester) async {
      LeaveEditChoice? choice;
      await tester.pumpWidget(
        app(
          MaterialApp(
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () async => choice = await showLeaveEditDialog(context, canSaveDraft: false),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('leave-edit-save-draft')), findsNothing);
      // Dismissed: keep editing.
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(choice, LeaveEditChoice.keepEditing);
    });
  });

  group('2. replies and private messages are posted once', () {
    const stored = '<?xml version="1.0" encoding="utf-8"?><root><![CDATA[succeedhandle_pmsend(\'\', \'\');]]></root>';

    test('the reply to the thread, the old reply window and both private messages: one attempt each', () async {
      forum.answer = (r) {
        if (r.method == 'GET') {
          // The reply window of the forum itself (no app API form): the old path.
          return _xml(_replyWindow);
        }
        return _xml(r.uri.queryParameters['action'] == 'reply' ? _replyStored : stored);
      };
      const repository = ReplyRepository();
      await repository.replyToThread(replyParameters: _replyParameters, replyMessage: 'hi').run();
      await repository
          .replyToPost(
            replyParameters: _replyParameters,
            replyAction: 'forum.php?mod=post&action=reply&fid=2&tid=9600001&repquote=9700002&extra=page%3D1&page=1',
            replyMessage: 'hi',
          )
          .run();
      await repository
          .replyHistoryPersonalMessage(
            targetUrl: '$baseUrl/home.php?mod=spacecp&ac=pm&op=send&pmid=1&daterange=0&pmsubmit=yes&inajax=1',
            formHash: 'f1f2f3f4',
            message: 'hi',
          )
          .run();
      await repository.replyPersonalMessage('1000', {'formhash': 'f1f2f3f4', 'message': 'hi'}).run();
      final posts = forum.requests.where((r) => r.method == 'POST').toList();
      expect(posts, hasLength(4));
      expect(posts.map((r) => r.singleAttempt), everyElement(isTrue));
    });

    test('a failure after the request left may have been sent; one before it never was', () async {
      Future<ReplyState> failWith(_Answer answer) async {
        forum.answer = (r) => answer;
        final bloc = ReplyBloc(replyRepository: const ReplyRepository());
        addTearDown(bloc.close);
        final done = bloc.stream.firstWhere((s) => s.status == ReplyStatus.failure);
        bloc.add(const ReplyToThreadRequested(replyParameters: _replyParameters, replyMessage: 'hi'));
        return done;
      }

      // The answer did not come back in time: the forum may have stored the reply.
      final timedOut = await failWith(_throws(DioExceptionType.receiveTimeout));
      expect(timedOut.networkFailure, isTrue);
      expect(timedOut.maybeSent, isTrue);
      // The forum was never reached: nothing was sent.
      final offline = await failWith(_throws(DioExceptionType.connectionError));
      expect(offline.networkFailure, isTrue);
      expect(offline.maybeSent, isFalse);
      // The forum refused it.
      final refused = await failWith(
        _xml(
          '<?xml version="1.0" encoding="utf-8"?><root><![CDATA[<script>'
          "errorhandle_fastpost('抱歉，您兩次發表間隔少於 15 秒', {});</script>]]></root>",
        ),
      );
      expect(refused.maybeSent, isFalse);
      expect(refused.networkFailure, isFalse);
    });

    testWidgets('the thread page says so, with a refresh of the floors', (tester) async {
      var pages = 0;
      forum.answer = (r) {
        if (r.method == 'POST') return _throws(DioExceptionType.receiveTimeout);
        pages++;
        return _html(_threadPage([1, 2]));
      };
      await _pumpThread(tester, app);
      final bar = tester.element(find.byType(ReplyBar));
      final parameters = BlocProvider.of<ThreadBloc>(bar).state.replyParameters;
      BlocProvider.of<ReplyBloc>(bar).add(
        ReplyToThreadRequested(replyParameters: parameters ?? _replyParameters, replyMessage: 'hi'),
      );
      await tester.pumpAndSettle();
      expect(find.text(t.threadPage.replyMaybeSent), findsOneWidget);
      final before = pages;
      await tester.tap(find.text(t.threadPage.refreshToCheck));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();
      expect(pages, before + 1, reason: 'the floors are loaded again to check');
      expect(
        forum.requests.last.uri.queryParameters['page'],
        '$lastPageAsked',
        reason: 'the last page, which a new reply may have opened',
      );
      await _unpump(tester);
    });
  });

  group('3. a private message that failed', () {
    Future<void> pumpChat(WidgetTester tester, Widget page) async {
      final auth = AuthenticationRepository(user: _alice);
      addTearDown(auth.dispose);
      await tester.pumpWidget(
        app(
          MaterialApp(scaffoldMessengerKey: snackbarKey, home: page),
          auth: auth,
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('the dialog page: a timeout says it may have been sent, with a refresh', (tester) async {
      final dialog = File('test/data/chat_dialog_x5.xml').readAsStringSync();
      var dialogs = 0;
      forum.answer = (r) {
        if (r.method == 'POST') return _throws(DioExceptionType.receiveTimeout);
        dialogs++;
        return _xml(dialog);
      };
      await pumpChat(tester, const ChatPage(username: 'Bob', uid: '1000'));
      BlocProvider.of<ReplyBloc>(
        tester.element(find.byType(ReplyBar)),
      ).add(const ReplyChatRequested('1000', {'formhash': 'XXXXXXXX', 'message': 'hi', 'pmsubmit': 'true'}));
      await tester.pumpAndSettle();
      expect(find.text(t.chatPage.maybeSent), findsOneWidget);
      expect(forum.requests.where((r) => r.method == 'POST').single.singleAttempt, isTrue);
      final before = dialogs;
      await tester.tap(find.text(t.chatPage.refresh));
      await tester.pumpAndSettle();
      expect(dialogs, before + 1, reason: 'the refresh fetches the dialog again');
    });

    testWidgets('the history page: an unreachable forum is told, the editor stays open', (tester) async {
      final history = File('test/data/chat_history_bare_url_x5.html').readAsStringSync();
      forum.answer = (r) => r.method == 'POST' ? _throws(DioExceptionType.connectionError) : _xml(history);
      await pumpChat(tester, const ChatHistoryPage(uid: '1000'));
      final barContext = tester.element(find.byType(ReplyBar));
      // The expanded editor, as the user sends from it.
      final controller = tester.widget<ReplyBar>(find.byType(ReplyBar)).controller..setHintText('reply');
      await tester.pumpAndSettle();
      expect(controller.showingEditor, isTrue);
      BlocProvider.of<ReplyBloc>(barContext).add(
        const ReplyChatHistoryRequested(targetUrl: '$baseUrl/home.php?mod=spacecp&ac=pm', formHash: 'x', message: 'hi'),
      );
      await tester.pumpAndSettle();
      expect(find.text(t.chatPage.failedNetwork), findsOneWidget, reason: 'used to say nothing at all');
      expect(controller.showingEditor, isTrue, reason: 'the editor stays with the message');
    });
  });

  group('4. goto=lastpost', () {
    test('routes to the last floor, in the order of the thread itself', () {
      final route = '$baseUrl/forum.php?mod=redirect&tid=1264975&goto=lastpost#lastpost'.parseUrlToRoute()!;
      expect(route.screenPath, ScreenPaths.threadV1);
      expect(route.queryParameters, {'tid': '1264975', 'lastPost': '1', 'overrideReverseOrder': 'false'});
      final plain = '$baseUrl/forum.php?mod=redirect&tid=1264975'.parseUrlToRoute()!;
      expect(plain.queryParameters.containsKey('lastPost'), isFalse);
    });

    testWidgets('asks a page past the last one and lands on the last floor', (tester) async {
      final asked = <String?>[];
      forum.answer = (r) {
        asked.add(r.uri.queryParameters['page']);
        // The forum answers its last page (3) for a page past it.
        return _html(_threadPage([21, 22, 23, 24, 25, 26, 27, 28], page: 3, pages: 3));
      };
      await _pumpThread(tester, app, lastPost: true);
      expect(asked, ['$lastPageAsked']);
      final bloc = BlocProvider.of<ThreadBloc>(tester.element(find.byType(PostList)));
      expect(bloc.state.currentPage, 3);
      expect(bloc.state.totalPages, 3);
      final position = tester.state<ScrollableState>(find.byType(Scrollable).first).position;
      expect(position.pixels, greaterThan(0));
      expect(find.textContaining('floor 28 text', findRichText: true), findsOneWidget, reason: 'the last floor');
      await _unpump(tester);
    });

    testWidgets('a thread of one page (no pager) is page 1, not the page asked', (tester) async {
      forum.answer = (r) => _html(_threadPage([1, 2]));
      await _pumpThread(tester, app, lastPost: true);
      final bloc = BlocProvider.of<ThreadBloc>(tester.element(find.byType(PostList)));
      expect(bloc.state.currentPage, 1);
      expect(bloc.state.totalPages, 1);
      await _unpump(tester);
    });
  });

  group('5. the image cache', () {
    test('is looked up by key, also in a large table', () async {
      // Since the cold start work the table is never read whole: a row is looked up by its url in the table.
      await db.batch(
        (b) => b.insertAll(db.image, [
          for (var i = 0; i < 150000; i++)
            ImageCompanion.insert(
              url: 'https://img.example/$i.png',
              fileName: '$i',
              lastCachedTime: DateTime(2026),
              lastUsedTime: DateTime(2026),
            ),
        ]),
      );
      final provider = StorageProvider(db, {}, {});
      final watch = Stopwatch()..start();
      for (var i = 0; i < 2000; i++) {
        expect((await provider.getImageCache('https://img.example/${149999 - i}.png'))?.fileName, '${149999 - i}');
      }
      watch.stop();
      expect(await provider.getImageCache('https://img.example/none.png'), isNull);
      // Walking the table for every lookup took seconds here (minutes for 2000 lookups of the table).
      expect(watch.elapsedMilliseconds, lessThan(5000));
    });
  });

  group('6. the text scale', () {
    test('the system font size times the app scale, within the limits', () {
      expect(appTextScaler(TextScaler.noScaling, 1).scale(10), 10);
      expect(appTextScaler(const TextScaler.linear(1.3), 1).scale(10), closeTo(13, 1e-9), reason: 'was 10');
      expect(appTextScaler(const TextScaler.linear(1.1), 1.2).scale(10), closeTo(13.2, 1e-9));
      // An app scale raised before to make up for the system font: not twice as large, the old limit holds.
      expect(appMaxTextScale, 1.5);
      expect(appTextScaler(const TextScaler.linear(1.3), 1.3).scale(10), closeTo(15, 1e-9));
      expect(appTextScaler(const TextScaler.linear(2), 1.5).scale(10), closeTo(10 * appMaxTextScale, 1e-9));
      expect(appTextScaler(const TextScaler.linear(0.85), 0.7).scale(10), closeTo(10 * appMinTextScale, 1e-9));
    });

    test('the nonlinear scaling of the platform (Android 14) is kept', () {
      // Small text grows by 30 %, large text by 10 %.
      const system = _NonlinearScaler();
      final scaler = appTextScaler(system, 1.1);
      expect(scaler.scale(10), closeTo(10 * 1.3 * 1.1, 1e-9));
      expect(scaler.scale(30), closeTo(30 * 1.1 * 1.1, 1e-9), reason: 'not the linear factor of the body text');
      expect(appTextScaler(system, 1.1), appTextScaler(system, 1.1));
    });

    testWidgets('a large system font: the breadcrumbs of the thread page grow with it, nothing overflows', (
      tester,
    ) async {
      forum.answer = (r) => _html(_threadPage([1, 2]));
      await _pumpThread(tester, app);
      final normal = tester.getSize(find.byType(CollapsingAppBar)).height;
      await _unpump(tester);
      await _pumpThread(tester, app, textScale: 2);
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(CollapsingAppBar)).height, greaterThan(normal + 5));
      await _unpump(tester);
    });

    test('the app no longer replaces the system scale with a clamp that did nothing', () {
      final source = File('lib/app.dart').readAsStringSync();
      expect(source, contains('appTextScaler(data.textScaler, textScaleFactor)'));
      expect(source, isNot(contains('..clamp(')));
    });
  });

  group('7. a forum page that failed to go on with the list', () {
    test('keeps the threads, and the retry goes on from there', () async {
      final repository = _FakeForumRepository();
      final bloc = ForumBloc(fid: '7', forumRepository: repository)..add(const ForumLoadMoreRequested(1));
      addTearDown(bloc.close);
      await bloc.stream.firstWhere((s) => s.status == ForumStatus.success);
      repository.failing = true;
      bloc.add(const ForumLoadMoreRequested(2));
      final failed = await bloc.stream.firstWhere((s) => s.loadMoreFailed);
      expect(failed.status, ForumStatus.success, reason: 'the list used to become a retry card');
      expect(failed.normalThreadList.map((e) => e.threadID), ['10', '11']);
      repository.failing = false;
      bloc.add(const ForumRetryRequested());
      final more = await bloc.stream.firstWhere((s) => s.currentPage == 2);
      expect(more.loadMoreFailed, isFalse);
      expect(more.normalThreadList.map((e) => e.threadID), ['10', '11', '20', '21']);
      expect(repository.asked, [1, 2, 2]);
    });

    test('the first page that failed still gets the retry card', () async {
      final repository = _FakeForumRepository()..failing = true;
      final bloc = ForumBloc(fid: '7', forumRepository: repository)..add(const ForumLoadMoreRequested(1));
      addTearDown(bloc.close);
      final failed = await bloc.stream.firstWhere((s) => s.status == ForumStatus.failure);
      expect(failed.loadMoreFailed, isFalse);
    });

    testWidgets('the footer tells the failure and retries', (tester) async {
      var retried = 0;
      await tester.pumpWidget(
        app(
          MaterialApp(
            home: Scaffold(
              body: ListFooter(
                status: ListFooterStatus.failed,
                failure: LoadFailure(LoadFailureKind.noNetwork),
                onRetry: () => retried++,
              ),
            ),
          ),
        ),
      );
      // The shared end of the lists (test_244): the failure with its reason, and the retry.
      expect(find.text(t.loadState.footer.failed(reason: t.loadState.failure.noNetwork.title)), findsOneWidget);
      await tester.tap(find.text(t.general.retry));
      expect(retried, 1);
    });
  });

  group('8. search and my threads tell their failures', () {
    test('the rate limit of the forum is read from its message', () {
      expect(searchRateLimitSeconds('抱歉，您在 20 秒内只能进行一次搜索'), 20);
      expect(searchRateLimitSeconds('抱歉，您在 15 秒内只能进行一次搜索'), 15);
      expect(searchRateLimitSeconds('抱歉，您的搜索过于频繁'), 20);
      expect(searchRateLimitSeconds('抱歉，站点设置每分钟系统最多响应搜索请求 10 次，请稍候再试'), 60);
      expect(searchRateLimitSeconds('抱歉，您所在的用户组没有搜索权限'), isNull);
      // A forum in traditional Chinese.
      expect(searchRateLimitSeconds('抱歉，您在 20 秒內只能進行一次搜尋'), 20);
      expect(searchRateLimitSeconds('抱歉，您的搜尋過於頻繁'), 20);
      expect(searchRateLimitSeconds('抱歉，站點設置每分鐘系統最多響應搜索請求 10 次，請稍候再試'), 60);
    });

    testWidgets('before a search: a hint, not "no data"', (tester) async {
      await tester.pumpWidget(app(const MaterialApp(home: SearchPage())));
      await tester.pumpAndSettle();
      expect(find.text(t.searchPage.result.hint), findsOneWidget);
      expect(find.text(t.searchPage.result.noData), findsNothing);
    });

    testWidgets('a search too early: the limit and a countdown before the retry', (tester) async {
      var searches = 0;
      forum.answer = (r) {
        searches++;
        return _html('<div id="messagetext"><p>抱歉，您在 20 秒内只能进行一次搜索</p></div>');
      };
      await tester.pumpWidget(app(const MaterialApp(home: SearchPage())));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).first, 'k');
      await tester.tap(find.byIcon(Icons.search_outlined));
      await _settle(tester);
      expect(searches, 1);
      // The shared failure view (test_244): the limit in words, the forum's own message, a countdown on the retry.
      expect(find.text(t.loadState.failure.rateLimited.title), findsOneWidget);
      expect(find.text(t.loadState.failure.rateLimited.hintSeconds(seconds: 20)), findsOneWidget);
      expect(find.text('抱歉，您在 20 秒内只能进行一次搜索'), findsOneWidget);
      final retry = find.byKey(failureRetryKey);
      expect(tester.widget<FilledButton>(retry).onPressed, isNull, reason: 'not before the forum takes it');
      expect(find.text(t.loadState.retryIn(seconds: 20)), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      expect(find.text(t.loadState.retryIn(seconds: 15)), findsOneWidget);
      await tester.pump(const Duration(seconds: 16));
      expect(tester.widget<FilledButton>(retry).onPressed, isNotNull);
      forum.answer = (r) {
        searches++;
        return _html('<div id="messagetext"><p>没有找到匹配结果</p></div>');
      };
      await tester.ensureVisible(retry);
      await tester.pump();
      await tester.tap(retry);
      await _settle(tester);
      expect(searches, 2, reason: 'the retry asks the same search again');
      expect(find.text(t.searchPage.result.noData), findsOneWidget);
    });

    test('the search bloc keeps the reason and the wait', () async {
      forum.answer = (r) => _html('<div id="messagetext"><p>抱歉，您的搜索过于频繁</p></div>');
      final bloc = SearchBloc(searchRepository: SearchRepository());
      addTearDown(bloc.close);
      bloc.add(const SearchRequested(keyword: 'k', fid: '0', uid: '0', pageNumer: 1));
      final failed = await bloc.stream.firstWhere((s) => s.status == SearchStatus.failed);
      expect(failed.failedMessage, '抱歉，您的搜索过于频繁');
      expect(failed.retryAfterSeconds, 20);
      expect(failed.failedAt, isNotNull);
    });

    testWidgets('my threads: a tab that failed offers its retry instead of "no data"', (tester) async {
      var failing = true;
      forum.answer = (r) => failing ? _throws(DioExceptionType.connectionError) : _html('<html><body></body></html>');
      await tester.pumpWidget(app(const MaterialApp(home: MyThreadPage())));
      await tester.pumpAndSettle();
      expect(find.text(t.general.retry), findsOneWidget);
      expect(find.text(t.myThreadPage.threadTab.empty), findsNothing);
      // What failed, in words (test_244).
      expect(find.text(t.loadState.failure.noNetwork.title), findsOneWidget);
      failing = false;
      await tester.tap(find.text(t.general.retry));
      await tester.pumpAndSettle();
      expect(find.text(t.myThreadPage.threadTab.empty), findsOneWidget, reason: 'an empty list once it loaded');
    });
  });

  group('7 and 8. my threads', () {
    test('the next page that failed keeps the list, the retry goes on', () async {
      Object json(String name) =>
          jsonDecode(File('test/data/tsdmapp/mythread_v9_$name.json').readAsStringSync()) as Object;
      var failing = false;
      forum.answer = (r) {
        final query = r.uri.queryParameters;
        if (query['page'] == '2') {
          return failing ? _throws(DioExceptionType.connectionError) : _json(json('thread_p2'));
        }
        return _json(json(query['type'] == 'reply' ? 'reply' : 'thread'));
      };
      final bloc = MyThreadBloc(myThreadRepository: MyThreadRepository())..add(MyThreadLoadInitialDataRequested());
      addTearDown(bloc.close);
      final loaded = await bloc.stream.firstWhere((s) => s.status == MyThreadStatus.success);
      expect(loaded.threadList, hasLength(20));
      expect(loaded.nextThreadPageUrl, isNotNull);
      failing = true;
      bloc.add(const MyThreadLoadMoreThreadRequested());
      final failed = await bloc.stream.firstWhere((s) => s.threadLoadMoreFailed);
      expect(failed.status, MyThreadStatus.success, reason: 'the list stays');
      expect(failed.threadList, hasLength(20));
      expect(failed.replyLoadMoreFailed, isFalse);
      failing = false;
      bloc.add(const MyThreadLoadMoreThreadRequested());
      final more = await bloc.stream.firstWhere((s) => s.threadPageNumber == 2);
      expect(more.threadLoadMoreFailed, isFalse);
      expect(more.threadList.length, greaterThan(20));
    });

    test('one tab that failed does not fail the other', () async {
      forum.answer = (r) => r.uri.queryParameters['type'] == 'reply'
          ? _throws(DioExceptionType.connectionError)
          : _json(jsonDecode(File('test/data/tsdmapp/mythread_v9_thread.json').readAsStringSync()) as Object);
      final bloc = MyThreadBloc(myThreadRepository: MyThreadRepository())..add(MyThreadLoadInitialDataRequested());
      addTearDown(bloc.close);
      final state = await bloc.stream.firstWhere((s) => s.status != MyThreadStatus.loading);
      expect(state.status, MyThreadStatus.success);
      expect(state.threadList, hasLength(20));
      expect(state.threadFailed, isFalse);
      expect(state.replyFailed, isTrue);
    });
  });

  group('9 and 10. the pages of a thread', () {
    test('the floors appended once, a hot reply kept once more', () {
      final previous = [_post('1', hot: true), _post('1'), _post('2'), _post('3')];
      final loaded = [_post('3', page: 2), _post('4', page: 2), _post('1', page: 2, hot: true), _post('', page: 2)];
      expect(appendFloors(previous, loaded).map((e) => '${e.hot ? 'hot ' : ''}${e.postID}'), [
        'hot 1',
        '1',
        '2',
        '3',
        '4',
        '',
      ]);
      expect(appendFloors(const [], loaded), same(loaded));
    });

    testWidgets('the last page ends with the last floor and has nothing to pull', (tester) async {
      forum.answer = (r) => _html(_threadPage([1, 2, 3]));
      await _pumpThread(tester, app);
      expect(find.byKey(const ValueKey('thread-last-floor-footer')), findsNothing, reason: 'below the screen');
      await tester.drag(find.byType(PostList), const Offset(0, -3000));
      await tester.pumpAndSettle();
      expect(find.text(t.threadPage.lastFloorReached), findsOneWidget);
      // Pulling up at the end used to show "no more" every time.
      await tester.drag(find.byType(PostList), const Offset(0, -400));
      await tester.pumpAndSettle();
      expect(find.text(t.general.noMoreData), findsNothing);
      expect(forum.requests, hasLength(1));
      await _unpump(tester);
    });

    testWidgets('the next page is the one after the last loaded, not after the one in view', (tester) async {
      final asked = <String?>[];
      forum.answer = (r) {
        final page = int.tryParse(r.uri.queryParameters['page'] ?? '') ?? 1;
        asked.add('$page');
        return _html(_threadPage([for (var i = 1; i <= 3; i++) page * 10 + i], page: page, pages: 3));
      };
      await _pumpThread(tester, app);
      // The pages after are asked for before the end is reached (reading progress round): three short pages are all
      // on screen at once.
      final bloc = BlocProvider.of<ThreadBloc>(tester.element(find.byType(PostList)));
      expect(bloc.state.currentPage, 3);
      // The page in view is page 1 again: asking for page 2 asks nothing, it is on screen.
      BlocProvider.of<JumpPageCubit>(tester.element(find.byType(PostList))).setPageInfo(currentPage: 1);
      bloc.add(const ThreadLoadMoreRequested(2));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(PostList), const Offset(0, -6000));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(PostList), const Offset(0, -400));
      await tester.pumpAndSettle();
      expect(asked, ['1', '2', '3']);
      expect(bloc.state.postList.map((e) => e.postID), ['11', '12', '13', '21', '22', '23', '31', '32', '33']);
      await _unpump(tester);
    });
  });

  group('11. back on another home tab', () {
    testWidgets('goes to the homepage first', (tester) async {
      final cubit = HomeCubit()..setTab(HomeTab.topic);
      addTearDown(cubit.close);
      final router = GoRouter(
        initialLocation: ScreenPaths.topic,
        routes: [
          GoRoute(
            path: ScreenPaths.homepage,
            name: ScreenPaths.homepage,
            builder: (_, _) => const RootPage(ScreenPaths.homepage, Text('homepage')),
          ),
          GoRoute(
            path: ScreenPaths.topic,
            name: ScreenPaths.topic,
            builder: (_, _) => const RootPage(ScreenPaths.topic, Text('topics')),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        app(
          BlocProvider.value(
            value: cubit,
            child: MaterialApp.router(routerConfig: router),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('topics'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('homepage'), findsOneWidget, reason: 'used to leave the app');
      expect(cubit.state.tab, HomeTab.home);
    });
  });

  group('12. the notification permission', () {
    Future<BuildContext> pumpContext(WidgetTester tester) async {
      await tester.pumpWidget(app(const MaterialApp(home: Scaffold(body: Text('page')))));
      return tester.element(find.text('page'));
    }

    testWidgets('is not asked before the first frame any more', (tester) async {
      final source = File('lib/main.dart').readAsStringSync();
      expect(source, isNot(contains('requestNotificationsPermission')));
    });

    testWidgets('a guest is never asked', (tester) async {
      final context = await pumpContext(tester);
      final gateway = _Gateway(PermissionStatus.denied);
      final asked = await askNotificationPermission(
        context,
        trigger: NotificationPermissionTrigger.noticePage,
        loggedIn: false,
        gateway: gateway,
        enabled: true,
      );
      expect(asked, isFalse);
      expect(find.text(t.settingsPage.behaviorSection.notificationPermission.promptTitle), findsNothing);
      expect(gateway.requests, 0);
    });

    testWidgets('after a login: the card first, then the system dialog, once', (tester) async {
      final context = await pumpContext(tester);
      final gateway = _Gateway(PermissionStatus.denied);
      final result = askNotificationPermission(
        context,
        trigger: NotificationPermissionTrigger.login,
        loggedIn: true,
        gateway: gateway,
        enabled: true,
      );
      await tester.pumpAndSettle();
      expect(find.text(t.settingsPage.behaviorSection.notificationPermission.promptTitle), findsOneWidget);
      expect(gateway.requests, 0, reason: 'the card comes before the system dialog');
      await tester.tap(find.byKey(const ValueKey('notification-permission-allow')));
      await tester.pumpAndSettle();
      expect(await result, isTrue);
      expect(gateway.requests, 1);
      expect(settings.currentSettings.notificationPermissionPrompted, isTrue);

      // The notice page later: not again.
      gateway.notification = PermissionStatus.denied;
      final again = askNotificationPermission(
        context,
        trigger: NotificationPermissionTrigger.noticePage,
        loggedIn: true,
        gateway: gateway,
        enabled: true,
      );
      await tester.pumpAndSettle();
      expect(await again, isFalse);
      expect(find.text(t.settingsPage.behaviorSection.notificationPermission.promptTitle), findsNothing);

      // Turning the sync on in the settings asks whenever it is missing.
      final fromSettings = askNotificationPermission(
        context,
        trigger: NotificationPermissionTrigger.settings,
        loggedIn: true,
        gateway: gateway,
        enabled: true,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('notification-permission-later')));
      await tester.pumpAndSettle();
      expect(await fromSettings, isFalse);
      expect(gateway.requests, 1, reason: '"not now" asks nothing');
    });

    testWidgets('not asked with the sync off, nor when granted already', (tester) async {
      final context = await pumpContext(tester);
      final gateway = _Gateway(PermissionStatus.granted);
      expect(
        await askNotificationPermission(
          context,
          trigger: NotificationPermissionTrigger.noticePage,
          loggedIn: true,
          gateway: gateway,
          enabled: true,
        ),
        isFalse,
      );
      await tester.runAsync(() => settings.setValue(SettingsKeys.notificationPermissionPrompted, false));
      await tester.runAsync(() => settings.setValue(SettingsKeys.autoSyncNoticeSeconds, 0));
      gateway.notification = PermissionStatus.denied;
      expect(
        await askNotificationPermission(
          context,
          trigger: NotificationPermissionTrigger.login,
          loggedIn: true,
          gateway: gateway,
          enabled: true,
        ),
        isFalse,
      );
      expect(gateway.requests, 0);
    });
  });

  group('14. saving an image', () {
    final jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0, 0, 0, 0, 0]);
    final png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0]);
    final gif = Uint8List.fromList('GIF89a\x00\x00\x00\x00\x00\x00'.codeUnits);
    final webp = Uint8List.fromList([...'RIFF'.codeUnits, 0, 0, 0, 0, ...'WEBP'.codeUnits]);
    final now = DateTime.fromMicrosecondsSinceEpoch(42);

    test('is named with the extension of its type', () {
      expect(imageFileNameOf('$baseUrl/forum.php?mod=attachment&aid=abc', png, now: now), 'tsdm_client_image_42.png');
      expect(imageFileNameOf('https://img.example/a/photo.jpg', jpeg, now: now), 'photo.jpg');
      expect(imageFileNameOf('https://img.example/a/photo.JPEG', jpeg, now: now), 'photo.jpeg');
      expect(imageFileNameOf('https://img.example/a/photo.jpg', webp, now: now), 'photo.webp');
      expect(imageFileNameOf('https://img.example/a/anim', gif, now: now), 'anim.gif');
      expect(imageFileNameOf('https://img.example/', png, now: now), 'tsdm_client_image_42.png');
      expect(imageFileNameOf('https://img.example/x.bmp', Uint8List(4), now: now), 'x.bmp');
      expect(imageFileNameOf('https://img.example/x', Uint8List(4), now: now), 'x.jpg');
    });
  });

  group('15. wording and the app bar of the thread page', () {
    test('zh-TW reads right', () {
      final zhTw = File('lib/i18n/zh-TW.i18n.json').readAsStringSync();
      for (final wrong in ['顯示顯示', '視窗劇中', 'BBCode parser', '。。。', '導入', '導出', '論壇卡可跳轉', '帖子已关闭']) {
        expect(zhTw, isNot(contains(wrong)), reason: wrong);
      }
      expect(t.settingsPage.advancedSection.importData.title, '匯入資料');
    });

    testWidgets('hides while scrolling down, comes back when scrolling up', (tester) async {
      forum.answer = (r) => _html(_threadPage([for (var i = 1; i <= 10; i++) i]));
      await _pumpThread(tester, app);
      double barHeight() => tester.getSize(find.byType(CollapsingAppBar)).height;
      final full = barHeight();
      expect(full, greaterThan(56));
      final gesture = await tester.startGesture(tester.getCenter(find.byType(PostList)));
      await gesture.moveBy(const Offset(0, -300));
      await tester.pumpAndSettle();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(barHeight(), lessThan(1), reason: 'hidden: more room for the floors');
      await tester.drag(find.byType(PostList), const Offset(0, 100));
      await tester.pumpAndSettle();
      expect(barHeight(), full);
      await _unpump(tester);
    });

    testWidgets('stays with the setting off', (tester) async {
      await tester.runAsync(() => settings.setValue(SettingsKeys.collapseAppBarWhenScroll, false));
      forum.answer = (r) => _html(_threadPage([for (var i = 1; i <= 10; i++) i]));
      await _pumpThread(tester, app);
      final full = tester.getSize(find.byType(CollapsingAppBar)).height;
      await tester.drag(find.byType(PostList), const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(CollapsingAppBar)).height, full);
      await _unpump(tester);
    });
  });

  group('review follow-ups', () {
    const sendTimeout = DioExceptionType.receiveTimeout;

    Future<ReplyState> replyFailing(FutureOr<_Answer> Function(_Request) answer, {bool toPost = false}) async {
      forum.answer = answer;
      final bloc = ReplyBloc(replyRepository: const ReplyRepository());
      addTearDown(bloc.close);
      final done = bloc.stream.firstWhere((s) => s.status == ReplyStatus.failure);
      bloc.add(
        toPost
            ? const ReplyToPostRequested(
                replyParameters: _replyParameters,
                replyAction: 'forum.php?mod=post&action=reply&fid=2&tid=9600001&repquote=9700002&extra=page%3D1&page=1',
                replyMessage: 'hi',
              )
            : const ReplyToThreadRequested(replyParameters: _replyParameters, replyMessage: 'hi'),
      );
      return done;
    }

    test('M1. a server error or a redirect may come after the reply was stored, a client error not', () async {
      expect((await replyFailing((r) => _html('', status: 502))).maybeSent, isTrue);
      expect((await replyFailing((r) => _html('', status: 500))).maybeSent, isTrue);
      expect((await replyFailing((r) => _html('', status: 302))).maybeSent, isTrue);
      expect((await replyFailing((r) => _html('', status: 403))).maybeSent, isFalse);
      expect((await replyFailing((r) => _html('', status: 404))).maybeSent, isFalse);
    });

    group('M2. the Android client', () {
      const channel = MethodChannel('kzs.th000.tsdm_client/httpChannel');
      late List<MethodCall> calls;

      void platformFails(String code) {
        calls = [];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
          call,
        ) async {
          calls.add(call);
          throw PlatformException(code: code, message: 'failed', details: 'socket');
        });
        addTearDown(
          () =>
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null),
        );
        // The reply goes through the Android client, as in the app.
        getIt.registerFactory<NetClientProvider>(
          () => NetClientProvider.buildNoCookie(
            dio: Dio(BaseOptions(baseUrl: baseUrl))
              ..httpClientAdapter = KotlinHttpClientAdapter(KotlinHttpClient(android: true)),
          ),
        );
      }

      setUp(() async => getIt.unregister<NetClientProvider>());

      test('a reply that never reached the forum: not sent', () async {
        platformFails('KT_HTTP_UNREACHABLE');
        final bloc = ReplyBloc(replyRepository: const ReplyRepository());
        addTearDown(bloc.close);
        final done = bloc.stream.firstWhere((s) => s.status == ReplyStatus.failure);
        bloc.add(const ReplyToThreadRequested(replyParameters: _replyParameters, replyMessage: 'hi'));
        final state = await done;
        expect(calls.single.method, 'postForm');
        expect((calls.single.arguments as Map)['singleAttempt'], isTrue);
        expect(state.networkFailure, isTrue);
        expect(state.maybeSent, isFalse, reason: 'used to say "may have been sent" for no network at all');
      });

      test('a reply that failed after the connect: may have been sent', () async {
        platformFails('KT_HTTP_ERROR');
        final bloc = ReplyBloc(replyRepository: const ReplyRepository());
        addTearDown(bloc.close);
        final done = bloc.stream.firstWhere((s) => s.status == ReplyStatus.failure);
        bloc.add(const ReplyToThreadRequested(replyParameters: _replyParameters, replyMessage: 'hi'));
        expect((await done).maybeSent, isTrue);
      });

      test('the Kotlin side tells an unreachable host for every POST', () {
        final source = File('android/app/src/main/kotlin/kzs/th000/tsdm_client/MainActivity.kt').readAsStringSync();
        expect(source, isNot(contains('result.error("KT_HTTP_ERROR"')));
        expect(RegExp(r'result\.error\(HttpClient\.errorCode\(e\)').allMatches(source), hasLength(4));
      });
    });

    testWidgets('M3. the notice page: "refresh to check" opens the last floor of the thread', (tester) async {
      forum.answer = (r) => r.method == 'POST' ? _throws(sendTimeout) : _html(_threadPage([1, 2]));
      Map<String, String>? opened;
      await _pumpRoutes(
        tester,
        app,
        home: const NoticeDetailPage(
          url: '$baseUrl/forum.php?mod=redirect&goto=findpost&pid=2&ptid=1264975',
          noticeType: NoticeType.reply,
        ),
        routes: [
          GoRoute(
            path: ScreenPaths.threadV1,
            name: ScreenPaths.threadV1,
            builder: (_, state) {
              opened = state.uri.queryParameters;
              return const Text('thread page');
            },
          ),
        ],
      );
      BlocProvider.of<ReplyBloc>(
        tester.element(find.byType(ReplyBar)),
      ).add(const ReplyToThreadRequested(replyParameters: _replyParameters, replyMessage: 'hi'));
      await _settle(tester);
      await tester.tap(find.text(t.threadPage.refreshToCheck));
      await tester.pumpAndSettle();
      expect(opened, {'tid': '1264975', 'lastPost': '1', 'overrideReverseOrder': 'false'});
      await _unpump(tester);
    });

    testWidgets('M4. the last floor of a thread the forum refuses: page 1, not the page asked', (tester) async {
      forum.answer = (r) => _json({
        'ok': 0,
        'api': 1,
        'uid': 31,
        'error': 'message',
        'login': 0,
        'type': 'thread',
        'schema': 3,
        'message': '抱歉，您没有权限访问该版块',
      });
      await _pumpThread(tester, app, lastPost: true);
      final bloc = BlocProvider.of<ThreadBloc>(tester.element(find.byType(Scaffold).last));
      expect(bloc.state.currentPage, 1);
      expect(bloc.state.totalPages, 1);
      expect(find.textContaining('$lastPageAsked'), findsNothing);
      await _unpump(tester);
    });

    testWidgets('M5. leaving the editor while it sends: told to wait', (tester) async {
      final form = jsonDecode(File('test/data/tsdmapp/post_v16_newthread.json').readAsStringSync()) as Object;
      final held = Completer<_Answer>();
      forum.answer = (r) => r.method == 'POST' ? held.future : _json(form);
      final auth = AuthenticationRepository(user: _alice);
      addTearDown(auth.dispose);
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => const Scaffold(body: Text('below the editor')),
            routes: [
              GoRoute(
                path: 'edit',
                builder: (_, _) => const PostEditPage(editType: PostEditType.newThread, fid: '7', tid: null, pid: null),
              ),
            ],
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        app(
          MaterialApp.router(routerConfig: router, scaffoldMessengerKey: snackbarKey),
          auth: auth,
        ),
      );
      unawaited(router.push('/edit'));
      await _settle(tester);
      final bloc = BlocProvider.of<PostEditBloc>(
        tester.element(find.descendant(of: find.byType(PostEditPage), matching: find.byType(Scaffold)).first),
      );
      final content = bloc.state.content!;
      bloc.add(
        ThreadPubPostThread(
          ThreadPublishInfo(
            formHash: content.formHash,
            postTime: content.postTime,
            delAttachOp: '0',
            wysiwyg: '0',
            fid: '7',
            threadType: null,
            checkbox: '0',
            subject: '標題',
            message: '內文內文內文內文內文',
            perm: null,
            price: null,
            save: '',
            options: const [],
          ),
        ),
      );
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
      expect(bloc.state.status, PostEditStatus.uploading);
      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      // Asked, not left: the user decides, knowing the result will not be known.
      expect(find.text(t.postEditPage.leaveDialog.sending), findsOneWidget);
      await tester.tap(find.text(t.general.cancel));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(PostEditPage), findsOneWidget, reason: 'used to leave while sending');
      await tester.binding.handlePopRoute();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text(t.general.ok));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('below the editor'), findsOneWidget, reason: 'left on purpose');
      held.complete(_json({'ok': 0, 'api': 1, 'error': 'message', 'message': 'x'}));
      await _settle(tester);
      await _unpump(tester);
    });

    test('N4. an exception while sending is a failed upload, not "uploading" for good', () async {
      final form = jsonDecode(File('test/data/tsdmapp/post_v16_newthread.json').readAsStringSync()) as Object;
      final repository = PostEditRepository.withTransport(
        currentUid: () => 31,
        getPage: (url) async => right(
          Response<dynamic>(requestOptions: RequestOptions(), data: jsonEncode(form), statusCode: 200),
        ),
        sendForm: (url, body) async => throw StateError('broken'),
      );
      final bloc = PostEditBloc(postEditRepository: repository);
      addTearDown(bloc.close);
      bloc.add(const ThreadPubFetchInfoRequested(fid: '7'));
      final loaded = await bloc.stream.firstWhere((s) => s.status != PostEditStatus.loading);
      final content = loaded.content!;
      bloc.add(
        ThreadPubPostThread(
          ThreadPublishInfo(
            formHash: content.formHash,
            postTime: content.postTime,
            delAttachOp: '0',
            wysiwyg: '0',
            fid: '7',
            threadType: null,
            checkbox: '0',
            subject: '標題',
            message: '內文內文內文內文內文',
            perm: null,
            price: null,
            save: '',
            options: const [],
          ),
        ),
      );
      final failed = await bloc.stream.firstWhere((s) => s.status == PostEditStatus.failedToUpload);
      expect(failed.status, PostEditStatus.failedToUpload);
      expect(bloc.canSubmit, isTrue, reason: 'can be sent again');
    });

    test('N3. the reply window that failed to load: the reply was never posted', () async {
      forum.answer = (r) => r.method == 'GET' ? _throws(DioExceptionType.receiveTimeout) : fail('posted');
      final bloc = ReplyBloc(replyRepository: const ReplyRepository());
      addTearDown(bloc.close);
      final done = bloc.stream.firstWhere((s) => s.status == ReplyStatus.failure);
      bloc.add(
        const ReplyToPostRequested(
          replyParameters: _replyParameters,
          replyAction: 'forum.php?mod=post&action=reply&fid=2&tid=9600001&repquote=9700002&extra=page%3D1&page=1',
          replyMessage: 'hi',
        ),
      );
      final state = await done;
      expect(state.maybeSent, isFalse, reason: 'only the GET of the window went out');
      expect(state.networkFailure, isTrue);
      final windowFailed = await replyFailing(
        (r) => r.method == 'GET' ? _html('', status: 502) : fail('posted'),
        toPost: true,
      );
      expect(windowFailed.maybeSent, isFalse);
      expect(windowFailed.failedReason, 'HTTP 502');
      expect(forum.requests.where((r) => r.method == 'POST'), isEmpty);
    });

    testWidgets('N1. a check after a reply that failed does not land the next loads on a last floor', (tester) async {
      var failing = false;
      forum.answer = (r) {
        if (r.method == 'POST') return _throws(sendTimeout);
        if (failing) return _throws(DioExceptionType.connectionError);
        final page = int.tryParse(r.uri.queryParameters['page'] ?? '') ?? 1;
        return _html(
          _threadPage(
            [for (var i = 1; i <= 8; i++) (page > 3 ? 3 : page) * 10 + i],
            page: page > 3 ? 3 : page,
            pages: 3,
          ),
        );
      };
      await _pumpThread(tester, app);
      BlocProvider.of<ReplyBloc>(
        tester.element(find.byType(ReplyBar)),
      ).add(const ReplyToThreadRequested(replyParameters: _replyParameters, replyMessage: 'hi'));
      await _settle(tester);
      failing = true;
      await tester.tap(find.text(t.threadPage.refreshToCheck));
      // A frame while loading, as the network takes its time.
      await tester.pump();
      await _settle(tester);
      failing = false;
      final bloc = BlocProvider.of<ThreadBloc>(tester.element(find.byType(PostList)))
        ..add(const ThreadJumpPageRequested(2));
      await tester.pump();
      await tester.pump();
      expect(find.byType(PostList), findsNothing, reason: 'loading');
      await _settle(tester);
      expect(bloc.state.currentPage, 2);
      final position = tester.widget<PostList>(find.byType(PostList)).scrollController.position;
      expect(position.maxScrollExtent, greaterThan(0));
      // The start of the list: its zero offset is at the first floor, the title above it (reading progress round).
      expect(
        position.pixels,
        position.minScrollExtent,
        reason: 'a jump starts at the top, not on the last floor of the page',
      );
      await _unpump(tester);
    });

    test('N5. offline, a page asked past the last one reads the last page saved', () async {
      await storage.saveCookie(username: 'Alice', uid: 31, cookie: {'Ystv_2132_auth': 'x31'});
      await settings.setValue(SettingsKeys.offlineThreads, true);
      final offline = OfflineThreadRepository(storage: storage, settings: settings, currentUid: () => 31);
      final repository = ThreadRepository(offline: offline);
      final answer =
          jsonDecode(File('test/data/tsdmapp/thread_v3_plain.json').readAsStringSync()) as Map<String, dynamic>
            ..['uid'] = 31
            ..['page'] = 3
            ..['pages'] = 3;
      final tid = '${(answer['thread'] as Map<String, dynamic>)['tid']}';
      var failing = false;
      forum.answer = (r) => failing ? _throws(DioExceptionType.connectionError) : _json(answer);
      Future<Either<AppException, ThreadPageInfo>> lastPost() =>
          repository.fetchThreadPage(tid: tid, pageNumber: lastPageAsked, pageFallback: 1).run();

      final online = (await lastPost()).getOrElse((e) => fail('$e'));
      expect(online.currentPage, 3);
      await offline.pendingWrites;
      final rows = await storage.fetchAllOfflineThreadPages();
      expect(rows.map((e) => e.page), [3], reason: 'saved as the page the forum answered (L2)');

      failing = true;
      final copy = (await lastPost()).getOrElse((e) => fail('no copy: $e'));
      expect(copy.offlineSavedAt, isNotNull);
      expect(copy.currentPage, 3);
      expect(copy.postList, isNotEmpty);
      // A page asked as such finds only its own copy.
      expect((await repository.fetchThreadPage(tid: tid, pageNumber: 5).run()).isLeft(), isTrue);
    });

    Map<String, dynamic> reversed({required int Function(int asked) page, required int pages}) {
      final json = jsonDecode(File('test/data/tsdmapp/thread_v3_long_reverse.json').readAsStringSync());
      final map = json as Map<String, dynamic>
        ..['page'] = page(0)
        ..['pages'] = pages;
      // No images here: the medals and avatars of the authors are not part of these tests.
      for (final post in (map['posts'] as List).cast<Map<String, dynamic>>()) {
        post
          ..['author_html'] = ''
          ..['avatar'] = ''
          ..['signature_html'] = '';
      }
      return map;
    }

    testWidgets('L1. a thread its author shows newest first: the last floor is on the first page', (tester) async {
      final asked = <String?>[];
      forum.answer = (r) {
        final page = int.tryParse(r.uri.queryParameters['page'] ?? '') ?? 1;
        asked.add('$page');
        return _json(reversed(page: (_) => page > 31 ? 31 : page, pages: 31));
      };
      await _pumpThread(tester, app, lastPost: true);
      expect(asked, ['$lastPageAsked', '1']);
      final bloc = BlocProvider.of<ThreadBloc>(tester.element(find.byType(PostList)));
      expect(bloc.state.currentPage, 1);
      expect(bloc.state.newestFirst, isTrue);
      await _unpump(tester);
    });

    testWidgets('L2. the url to copy names the page the forum answered', (tester) async {
      forum.answer = (r) => _html(_threadPage([21, 22], page: 3, pages: 3));
      await _pumpThread(tester, app, lastPost: true);
      final repository = RepositoryProvider.of<ThreadRepository>(tester.element(find.byType(PostList)));
      expect(repository.threadUrl, endsWith('&page=3'));
      expect(repository.threadUrl, isNot(contains('$lastPageAsked')));
      await _unpump(tester);
    });

    testWidgets('L4. newest first, the end of the list is the oldest floor', (tester) async {
      forum.answer = (r) => _json(reversed(page: (_) => 1, pages: 1));
      await _pumpThread(tester, app);
      await tester.drag(find.byType(PostList), const Offset(0, -20000));
      await tester.pumpAndSettle();
      expect(find.text(t.threadPage.firstFloorReached), findsOneWidget);
      expect(find.text(t.threadPage.lastFloorReached), findsNothing);
      await _unpump(tester);
    });

    testWidgets('L5. a list hardly longer than the screen keeps the app bar', (tester) async {
      forum.answer = (r) => _html(_threadPage([1]));
      await _pumpThread(tester, app);
      final full = tester.getSize(find.byType(CollapsingAppBar)).height;
      await tester.drag(find.byType(PostList), const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(CollapsingAppBar)).height, full);
      await _unpump(tester);
    });

    testWidgets('L6. "refresh to check" with one author only says the reply may not be shown', (tester) async {
      forum.answer = (r) => r.method == 'POST' ? _throws(sendTimeout) : _html(_threadPage([1, 2]));
      await _pumpThread(tester, app, onlyVisibleUid: '1000');
      BlocProvider.of<ReplyBloc>(
        tester.element(find.byType(ReplyBar)),
      ).add(const ReplyToThreadRequested(replyParameters: _replyParameters, replyMessage: 'hi'));
      await _settle(tester);
      await tester.tap(find.text(t.threadPage.refreshToCheck));
      // After the snack bar of the failure goes.
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text(t.threadPage.replyCheckFiltered), findsOneWidget);
      await _settle(tester);
      await _unpump(tester);
    });

    testWidgets('L8. my threads: every failed refresh of a list on screen is told', (tester) async {
      Object json(String name) =>
          jsonDecode(File('test/data/tsdmapp/mythread_v9_$name.json').readAsStringSync()) as Object;
      var failing = false;
      forum.answer = (r) => failing
          ? _throws(DioExceptionType.connectionError)
          : _json(json(r.uri.queryParameters['type'] == 'reply' ? 'reply' : 'thread'));
      await tester.pumpWidget(app(MaterialApp(scaffoldMessengerKey: snackbarKey, home: const MyThreadPage())));
      await _settle(tester);
      failing = true;
      final bloc = BlocProvider.of<MyThreadBloc>(tester.element(find.byType(Scaffold).first));
      for (var i = 0; i < 2; i++) {
        bloc.add(MyThreadRefreshThreadRequested());
        await _settle(tester);
        // The reason with the failure (test_244).
        expect(
          find.text(t.loadState.refreshFailed(reason: t.loadState.failure.noNetwork.title)),
          findsOneWidget,
          reason: 'refresh ${i + 1}',
        );
        ScaffoldMessenger.of(tester.element(find.byType(Scaffold).first)).removeCurrentSnackBar();
        await tester.pumpAndSettle();
      }
    });

    group('L9. the notification permission the system asks no more', () {
      Future<BuildContext> pumpContext(WidgetTester tester) async {
        await tester.pumpWidget(app(const MaterialApp(home: Scaffold(body: Text('page')))));
        return tester.element(find.text('page'));
      }

      testWidgets('permanently denied: the card leads to the app settings', (tester) async {
        final context = await pumpContext(tester);
        final gateway = _Gateway(PermissionStatus.permanentlyDenied);
        final asked = askNotificationPermission(
          context,
          trigger: NotificationPermissionTrigger.settings,
          loggedIn: true,
          gateway: gateway,
          enabled: true,
        );
        await tester.pumpAndSettle();
        final tr = t.settingsPage.behaviorSection.notificationPermission;
        expect(find.text(tr.promptSettingsMessage), findsOneWidget);
        expect(find.text(tr.promptMessage), findsNothing, reason: 'no system dialog comes');
        await tester.tap(find.text(tr.promptOpenSettings));
        await tester.pumpAndSettle();
        await asked;
        expect(gateway.settingsOpened, 1);
        expect(gateway.requests, 0);
      });

      testWidgets('denied right now (or no dialog came): not asked again at once; from the settings later, the '
          'card leads to the app settings', (tester) async {
        final context = await pumpContext(tester);
        final gateway = _Gateway(PermissionStatus.denied)
          ..answer = PermissionStatus.denied
          ..rationale = false;
        // The settings page's permission state, which remembers that the system will not ask again.
        final cubit = AndroidPermissionCubit(gateway: gateway, enabled: true);
        addTearDown(cubit.close);
        final asked = askNotificationPermission(
          context,
          trigger: NotificationPermissionTrigger.login,
          loggedIn: true,
          cubit: cubit,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('notification-permission-allow')));
        await tester.pumpAndSettle();
        await asked;
        final tr = t.settingsPage.behaviorSection.notificationPermission;
        expect(find.text(tr.promptSettingsMessage), findsNothing, reason: 'no second card right after the answer');
        expect(gateway.settingsOpened, 0);

        final again = askNotificationPermission(
          context,
          trigger: NotificationPermissionTrigger.settings,
          loggedIn: true,
          cubit: cubit,
        );
        await tester.pumpAndSettle();
        expect(find.text(tr.promptSettingsMessage), findsOneWidget);
        await tester.tap(find.text(tr.promptOpenSettings));
        await tester.pumpAndSettle();
        await again;
        expect(gateway.settingsOpened, 1);
      });
    });
  });

  group('the image cache by default', () {
    test('an avatar answering 404 is not asked again in this run; a reload asks', () async {
      final adapter = _Forum((r) => _html('', status: 404));
      final provider = ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = adapter));
      addTearDown(provider.dispose);
      const request = ImageCacheUserAvatarRequest(username: 'Bob', imageUrl: 'https://img.example/avatar/1000.jpg');
      expect((await provider.getOrMakeCache(request)).isNone(), isTrue);
      expect((await provider.getOrMakeCache(request)).isNone(), isTrue);
      expect(adapter.requests, hasLength(1), reason: 'every card of the author asked again');
      expect(provider.isKnownMissingAvatar(request.imageUrl), isTrue);
      await provider.getOrMakeCache(request, force: true);
      expect(adapter.requests, hasLength(2));
    });

    test('an avatar answering 404 is asked again after a while: one uploaded since shows', () async {
      var now = DateTime(2026, 10, 23, 12);
      ImageCacheProvider.clock = () => now;
      addTearDown(() => ImageCacheProvider.clock = DateTime.now);
      final adapter = _Forum((r) => _html('', status: 404));
      final provider = ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = adapter));
      addTearDown(provider.dispose);
      const request = ImageCacheUserAvatarRequest(username: 'Bob', imageUrl: 'https://img.example/avatar/1000.jpg');
      await provider.getOrMakeCache(request);
      now = now.add(const Duration(minutes: 9));
      await provider.getOrMakeCache(request);
      expect(adapter.requests, hasLength(1));
      now = now.add(const Duration(minutes: 2));
      expect(provider.isKnownMissingAvatar(request.imageUrl), isFalse);
      await provider.getOrMakeCache(request);
      expect(adapter.requests, hasLength(2));
    });

    test('an avatar that failed otherwise (offline) is asked again', () async {
      final adapter = _Forum((r) => _throws(DioExceptionType.connectionError));
      final provider = ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = adapter));
      addTearDown(provider.dispose);
      const request = ImageCacheUserAvatarRequest(username: 'Bob', imageUrl: 'https://img.example/avatar/1000.jpg');
      await provider.getOrMakeCache(request);
      await provider.getOrMakeCache(request);
      expect(adapter.requests, hasLength(2));
    });

    test(
      'the clean up of the image cache is on by default again, in the background (cold start); a saved choice stays',
      () async {
        expect(SettingsKeys.enableAutoClearImageCache.defaultValue, isTrue);
        expect(settings.currentSettings.enableAutoClearImageCache, isTrue);
        await settings.setValue(SettingsKeys.enableAutoClearImageCache, false);
        final again = SettingsRepository(storage);
        await again.init();
        addTearDown(again.dispose);
        expect(again.currentSettings.enableAutoClearImageCache, isFalse);
      },
    );
  });
}

/// The reply window of the forum itself for the old reply path.
const _replyWindow = '''
<?xml version="1.0" encoding="utf-8"?>
<root><![CDATA[<form method="post" id="postform" action="forum.php?mod=post&amp;action=reply&amp;fid=2&amp;tid=9600001&amp;extra=page%3D1&amp;replysubmit=yes&amp;infloat=yes&amp;handlekey=reply">
<input type="hidden" name="formhash" value="f1f2f3f4" />
<input type="hidden" name="handlekey" value="reply" />
<input type="hidden" name="noticeauthor" value="x" />
<input type="hidden" name="noticetrimstr" value="y" />
<input type="hidden" name="noticeauthormsg" value="z" />
<input type="hidden" name="reppid" value="9700002" />
<input type="hidden" name="reppost" value="9700002" />
<input type="hidden" name="usesig" value="1" />
</form>]]></root>''';

/// The forum's answer to a stored reply.
const _replyStored =
    '<?xml version="1.0" encoding="utf-8"?><root><![CDATA[<script type="text/javascript" reload="1">'
    "succeedhandle_reply('forum.php?mod=viewthread&tid=9600001&pid=9700009&page=1#pid9700009', "
    "'非常感謝，回覆發佈成功', {'fid':'2','tid':'9600001','pid':'9700009'});</script>]]></root>";

/// Pump the thread page of tid 1264975 under the providers of the app, settled.
Future<void> _pumpThread(
  WidgetTester tester,
  Widget Function(Widget child, {AuthenticationRepository? auth}) app, {
  bool lastPost = false,
  double textScale = 1,
  String? onlyVisibleUid,
}) => _pumpRoutes(
  tester,
  app,
  home: ThreadPage(
    threadID: '1264975',
    findPostID: null,
    pageNumber: '1',
    overrideReverseOrder: false,
    overrideWithExactOrder: null,
    lastPost: lastPost,
    onlyVisibleUid: onlyVisibleUid,
  ),
  textScale: textScale,
);

/// Pump [home] at `/` under the providers of the app, with [routes] beside it, settled.
Future<void> _pumpRoutes(
  WidgetTester tester,
  Widget Function(Widget child, {AuthenticationRepository? auth}) app, {
  required Widget home,
  List<RouteBase> routes = const [],
  double textScale = 1,
}) async {
  final auth = AuthenticationRepository(user: _alice);
  final blocks = UserBlockRepository(getIt.get<StorageProvider>());
  final info = NotificationInfoRepository();
  final counts = NotificationStateCubit(info);
  final cubit = UserBlockCubit(repository: blocks, currentUid: () => _alice.uid, authStatus: auth.status);
  final history = ThreadVisitHistoryBloc(ThreadVisitHistoryRepo(getIt.get<StorageProvider>()));
  final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (_, _) => home),
      ...routes,
    ],
  );
  addTearDown(() async {
    router.dispose();
    await cubit.close();
    await history.close();
    await info.dispose();
    await counts.close();
    await blocks.dispose();
    await auth.dispose();
  });
  await tester.pumpWidget(
    app(
      MultiRepositoryProvider(
        providers: [RepositoryProvider<FavoriteRepository>(create: (_) => FavoriteRepository())],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<UserBlockCubit>.value(value: cubit),
            BlocProvider<ThreadVisitHistoryBloc>.value(value: history),
            BlocProvider<NotificationBloc>.value(
              value: _Notifications(const NotificationState(status: NotificationStatus.success)),
            ),
            BlocProvider<NotificationStateCubit>.value(value: counts),
          ],
          // The text scale of the app (`appTextScaler` in `lib/app.dart`) above the app.
          child: MediaQuery(
            data: MediaQueryData.fromView(tester.view).copyWith(textScaler: TextScaler.linear(textScale)),
            child: MaterialApp.router(routerConfig: router, scaffoldMessengerKey: snackbarKey),
          ),
        ),
      ),
      auth: auth,
    ),
  );
  await _settle(tester);
}

/// Let the requests of the page (real futures of the client) and its frames finish.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pumpAndSettle();
}

/// Take the page down and let the timers of its indicators run out.
Future<void> _unpump(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 2));
}
