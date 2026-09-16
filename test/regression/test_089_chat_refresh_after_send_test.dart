import 'dart:async';
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
import 'package:tsdm_client/features/chat/bloc/chat_bloc.dart';
import 'package:tsdm_client/features/chat/bloc/chat_history_bloc.dart';
import 'package:tsdm_client/features/chat/repository/chat_repository.dart';
import 'package:tsdm_client/features/chat/view/chat_page.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
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
import 'package:tsdm_client/widgets/reply_bar/bloc/reply_bloc.dart';
import 'package:tsdm_client/widgets/reply_bar/reply_bar.dart';

/// GitHub #76 (second part): after a private message is sent, the conversation shows it. The dialog page fetches the
/// dialog again and ends on the newest message; the full history page reloads its latest page, replacing what it
/// showed instead of appending a second copy.
const _alice = UserLoginInfo(username: 'Alice', uid: 2000);

String _data(String name) => File('test/data/$name').readAsStringSync();

/// The full history fixture (two messages), the same page with a message just sent, and an older page.
final String _historyPage = _data('chat_history_bare_url_x5.html');
final String _historyWithSent = _historyPage.replaceFirst(
  '<div id="pm_append"',
  [
    '<dl id="pmlist_999" class="bbda cl">',
    '<dd class="m avt"><a href="home.php?mod=space&amp;uid=1001">',
    '<img data-src="./data/avatar/000/00/10/01_avatar_small.jpg"></a></dd>',
    '<dd class="ptm"><span class="xi2 xw1">您</span> &nbsp; <br />回覆 #sent 已送出<br />',
    '<span class="xg1"><span title="2026-9-16 11:00">1&nbsp;秒前</span></span></dd></dl>',
    '<div id="pm_append"',
  ].join(),
);

/// The dialog fixture (one message from Alice), and the same dialog after Bob's reply arrived.
final String _dialogBefore = _data('chat_dialog_x5.xml');
final String _dialogAfter = _dialogBefore.replaceFirst(
  '</ul>',
  '<li class="cl pmm"><div class="pmt">Bob: </div><div class="pmd">回覆 #n2 已送出</div></li></ul>',
);

/// Answers the dialog GET from a queue (an entry may be a future the test completes later, to hold an answer back)
/// and every send POST with the forum's success marker.
final class _ChatAdapter implements HttpClientAdapter {
  _ChatAdapter(this.dialogs);

  final List<FutureOr<String>> dialogs;

  /// Answers for the full history page, in request order; the plain fixture once the queue is empty.
  final List<FutureOr<String>> histories = [];
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (requestStream != null) {
      await requestStream.drain<void>();
    }
    final query = options.uri.queryParameters;
    final String body;
    if (options.method == 'POST' && query['op'] == 'send') {
      body = '<?xml version="1.0" encoding="utf-8"?><root><![CDATA[succeedhandle_pmsend(\'\', \'\');]]></root>';
    } else if (query['op'] == 'showmsg') {
      body = dialogs.isEmpty ? fail('unexpected dialog request #${requests.length}') : await dialogs.removeAt(0);
    } else if (query['subop'] == 'view') {
      body = histories.isEmpty ? _historyPage : await histories.removeAt(0);
    } else {
      fail('unexpected request: ${options.uri}');
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

/// Avatars are not part of this test: every image request fails at once.
final class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

void main() {
  late AppDatabase db;
  late StorageProvider storage;
  late SettingsRepository settings;
  late _ChatAdapter adapter;

  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
    adapter = _ChatAdapter([_dialogBefore, _dialogAfter]);
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings)
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
      ..registerFactory<NetClientProvider>(
        () => NetClientProvider.build(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = adapter),
      )
      ..registerSingleton<ImageCacheProvider>(
        ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _OfflineAdapter())),
      );
    await settings.init();
  });

  tearDown(() async {
    await getIt.reset();
    await settings.dispose();
    await db.close();
  });

  testWidgets('the dialog page fetches the conversation again after a message was sent', (tester) async {
    final auth = AuthenticationRepository(user: _alice);
    addTearDown(auth.dispose);
    await tester.pumpWidget(
      RepositoryProvider<AuthenticationRepository>.value(
        value: auth,
        child: TranslationProvider(
          child: const MaterialApp(
            home: ChatPage(username: 'Bob', uid: '1000'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('私訊 #n1'), findsOneWidget);
    expect(find.textContaining('回覆 #n2'), findsNothing);
    expect(adapter.requests.where((r) => r.uri.queryParameters['op'] == 'showmsg'), hasLength(1));

    // The bar's own send path ends in this event; the editor UI is not part of what is tested here.
    BlocProvider.of<ReplyBloc>(
      tester.element(find.byType(ReplyBar)),
    ).add(const ReplyChatRequested('1000', {'formhash': 'XXXXXXXX', 'message': 'hi', 'pmsubmit': 'true'}));
    await tester.pumpAndSettle();

    expect(adapter.requests.where((r) => r.method == 'POST'), hasLength(1));
    expect(
      adapter.requests.where((r) => r.uri.queryParameters['op'] == 'showmsg'),
      hasLength(2),
      reason: 'the dialog is fetched again after the send',
    );
    expect(find.textContaining('私訊 #n1'), findsOneWidget);
    expect(find.textContaining('回覆 #n2'), findsOneWidget, reason: 'the message just sent is on screen');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a slow refresh started before the send cannot put the old dialog back over the new message', (
    tester,
  ) async {
    // Initial load, then a pull to refresh whose answer is held back, then the reload after the send.
    final slowRefresh = Completer<String>();
    adapter.dialogs
      ..clear()
      ..addAll([_dialogBefore, slowRefresh.future, _dialogAfter]);
    final auth = AuthenticationRepository(user: _alice);
    addTearDown(auth.dispose);
    await tester.pumpWidget(
      RepositoryProvider<AuthenticationRepository>.value(
        value: auth,
        child: TranslationProvider(
          child: const MaterialApp(
            home: ChatPage(username: 'Bob', uid: '1000'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final barContext = tester.element(find.byType(ReplyBar));
    // The user pulls to refresh; the forum is slow to answer.
    BlocProvider.of<ChatBloc>(barContext).add(const ChatFetchHistoryRequested('1000'));
    await tester.pump();
    // Meanwhile the message is sent and the reload after it comes back first.
    BlocProvider.of<ReplyBloc>(
      barContext,
    ).add(const ReplyChatRequested('1000', {'formhash': 'XXXXXXXX', 'message': 'hi', 'pmsubmit': 'true'}));
    await tester.pumpAndSettle();
    expect(find.textContaining('回覆 #n2'), findsOneWidget, reason: 'the reload after the send is on screen');

    // Now the slow, older answer arrives: it must not replace the newer dialog.
    slowRefresh.complete(_dialogBefore);
    await tester.pumpAndSettle();
    expect(find.textContaining('回覆 #n2'), findsOneWidget, reason: 'a stale answer must not hide the sent message');
    expect(find.textContaining('私訊 #n1'), findsOneWidget);
    expect(adapter.requests.where((r) => r.uri.queryParameters['op'] == 'showmsg'), hasLength(3));
    expect(tester.takeException(), isNull);
  });

  test('a reload of the latest page is not thrown away when an older page is asked for meanwhile', () async {
    // The reload after a send is still in flight when the user pulls up for older messages. The older page must
    // wait for the reload: applying it first and dropping the reload as stale hid the message just sent (PR #81
    // review).
    final heldReload = Completer<String>();
    adapter.histories.addAll([heldReload.future, _historyPage]);
    final bloc = ChatHistoryBloc(const ChatRepository());
    addTearDown(bloc.close);
    Iterable<RequestOptions> views() => adapter.requests.where((r) => r.uri.queryParameters['subop'] == 'view');

    bloc.add(const ChatHistoryLoadHistoryRequested(uid: '1000', page: null));
    await pumpEventQueue();
    bloc.add(const ChatHistoryLoadHistoryRequested(uid: '1000', page: 2));
    await pumpEventQueue();
    expect(views(), hasLength(1), reason: 'the older page waits for the reload of the latest page');

    heldReload.complete(_historyWithSent);
    final settled = await bloc.stream
        .firstWhere((s) => s.status == ChatHistoryStatus.success && s.pageNumber == 2)
        .timeout(const Duration(seconds: 5));
    expect(views().map((r) => r.uri.queryParameters['page']), [null, '2']);
    expect(settled.messages.map((m) => m.message).join('\n'), contains('回覆 #sent'));
    // Latest page (3 messages, newest first) followed by the older page (2 messages).
    expect(settled.messages, hasLength(5));
    expect(settled.messages.first.message, contains('回覆 #sent'));
  });

  test('reloading the latest history page replaces the list instead of appending to it', () async {
    final bloc = ChatHistoryBloc(const ChatRepository());
    addTearDown(bloc.close);
    Future<ChatHistoryState> load(int? page) {
      final done = bloc.stream.firstWhere((s) => s.status == ChatHistoryStatus.success);
      bloc.add(ChatHistoryLoadHistoryRequested(uid: '1000', page: page));
      return done.timeout(const Duration(seconds: 5));
    }

    final first = await load(null);
    final pageSize = first.messages.length;
    expect(pageSize, greaterThan(0));
    // An earlier page is appended, as before.
    final more = await load(2);
    expect(more.messages, hasLength(pageSize * 2));
    // The latest page again (after a message was sent): shown once, not stacked on the older copies.
    final reloaded = await load(null);
    expect(reloaded.messages, hasLength(pageSize));
    expect(reloaded.pageNumber, isNull);
  });
}
