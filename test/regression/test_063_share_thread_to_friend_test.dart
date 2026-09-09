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
import 'package:tsdm_client/features/editor/repository/mention_repository.dart';
import 'package:tsdm_client/features/friend/models/models.dart';
import 'package:tsdm_client/features/friend/widgets/friend_picker_sheet.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/thread/v1/repository/share_thread_repository.dart';
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

String _data(String name) => File('test/data/$name').readAsStringSync();

const _sendOk =
    '<?xml version="1.0" encoding="utf-8"?><root><![CDATA[<script type="text/javascript" reload="1"> '
    "if(typeof succeedhandle_pmsend=='function') {succeedhandle_pmsend('', '', {'pmid':'1'});}</script>]]></root>";
const _sendFailed =
    '<?xml version="1.0" encoding="utf-8"?><root><![CDATA[<script type="text/javascript" reload="1"> '
    "if(typeof errorhandle_showmsg_1000=='function') {errorhandle_showmsg_1000('抱歉，您两次发表间隔少于 10 秒', {});} "
    '</script>]]></root>';
const _atUsers = '<?xml version="1.0" encoding="utf-8"?>\n<root><![CDATA[]]></root>';

/// Answers the chat dialog, the send endpoint, the own friends list and the `@` list; records every request.
final class _Adapter implements HttpClientAdapter {
  _Adapter({this.sendAnswer = _sendOk});

  final String sendAnswer;
  final requests = <(Uri uri, String method, String body)>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    var body = '';
    if (requestStream != null) {
      body = String.fromCharCodes(await requestStream.fold<List<int>>([], (a, b) => a..addAll(b)));
    }
    final uri = options.uri;
    requests.add((uri, options.method, Uri.decodeQueryComponent(body)));
    final q = uri.queryParameters;
    String answer;
    var type = 'text/html; charset=utf-8';
    if (uri.path == '/home.php' && q['ac'] == 'pm' && q['op'] == 'showmsg') {
      answer = _data('chat_dialog_x5.xml');
      type = 'text/xml; charset=utf-8';
    } else if (uri.path == '/home.php' && q['ac'] == 'pm' && q['op'] == 'send') {
      answer = sendAnswer;
      type = 'text/xml; charset=utf-8';
    } else if (uri.path == '/home.php' && q['do'] == 'friend') {
      answer = _data('friend_list_own_x5.html');
    } else if (uri.path == '/misc.php') {
      answer = _atUsers;
      type = 'text/xml; charset=utf-8';
    } else {
      answer = '<html></html>';
    }
    return ResponseBody.fromString(
      answer,
      200,
      headers: {
        Headers.contentTypeHeader: [type],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

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
  late _Adapter adapter;

  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  Future<void> register(_Adapter a) async {
    adapter = a;
    db = AppDatabase(NativeDatabase.memory());
    storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings)
      ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
      ..registerFactory<NetClientProvider>(
        () => NetClientProvider.build(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = adapter),
      );
    await settings.init();
  }

  tearDown(() async {
    await getIt.reset();
    await settings.dispose();
    await db.close();
  });

  group('ShareThreadRepository', () {
    test('opens the chat dialog for the form values, then posts the message to the friend', () async {
      await register(_Adapter());
      final result = await const ShareThreadRepository()
          .sendToFriend(uid: '1000', message: '分享帖子：标题\n$baseUrl/forum.php?mod=viewthread&tid=1264975')
          .run();
      expect(result.isRight(), isTrue, reason: '$result');
      expect(adapter.requests, hasLength(2));
      final (dialogUri, dialogMethod, _) = adapter.requests.first;
      expect(dialogMethod, 'GET');
      expect(dialogUri.queryParameters, containsPair('op', 'showmsg'));
      expect(dialogUri.queryParameters, containsPair('touid', '1000'));
      final (sendUri, sendMethod, body) = adapter.requests.last;
      expect(sendMethod, 'POST');
      expect(sendUri.queryParameters, containsPair('op', 'send'));
      expect(sendUri.queryParameters, containsPair('touid', '1000'));
      expect(body, contains('formhash=XXXXXXXX'));
      expect(body, contains('handlekey=showmsg_1000'));
      expect(body, contains('pmsubmit=true'));
      expect(body, contains('message=分享帖子：标题\n$baseUrl/forum.php?mod=viewthread&tid=1264975'));
    });

    test('the forum refusing the message (flood control) is a failure with its reason', () async {
      await register(_Adapter(sendAnswer: _sendFailed));
      final result = await const ShareThreadRepository().sendToFriend(uid: '1000', message: 'x').run();
      expect(result.isLeft(), isTrue);
      expect('${result.getLeft().toNullable()}', contains('10 秒'));
    });
  });

  group('FriendPickerSheet', () {
    tearDown(() async => getIt.get<ImageCacheProvider>().dispose());

    testWidgets('lists the own friends and pops the tapped one', (tester) async {
      await register(_Adapter());
      // The avatar of every row goes through the image cache; offline here.
      getIt.registerSingleton<ImageCacheProvider>(
        ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _OfflineAdapter())),
      );
      Friend? picked;
      final auth = AuthenticationRepository(user: const UserLoginInfo(username: 'Alice', uid: 1000));
      addTearDown(auth.dispose);
      await tester.pumpWidget(
        TranslationProvider(
          child: RepositoryProvider<AuthenticationRepository>.value(
            value: auth,
            child: MaterialApp(
              home: Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () async => picked = await showFriendPicker(context, repository: MentionRepository()),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Bob'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'zz');
      await tester.pumpAndSettle();
      expect(find.text('Bob'), findsNothing);
      await tester.enterText(find.byType(TextField), 'bo');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Bob'));
      await tester.pumpAndSettle();
      expect(picked?.uid, '1001');
      expect(picked?.username, 'Bob');
      expect(tester.takeException(), isNull);
    });
  });
}
