import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/widgets/card/notice_card_v2.dart';
import 'package:tsdm_client/widgets/munched_html.dart';
import 'package:universal_html/parsing.dart';

String _data(String name) => File('test/data/$name').readAsStringSync();

/// No network in tests: the avatar of the card must not be fetched.
class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    throw DioException.connectionError(requestOptions: options, reason: 'offline');
  }

  @override
  void close({bool force = false}) {}
}

/// GitHub #46: a thread link in the private message list opened the browser and landed on the forum index.
///
/// The list only carries a summary of each conversation and the server drops the `&` of every url in it
/// (`forum.php?mod=viewthreadtid=1264975`); the summary was rendered with tappable urls, that url is not a route the
/// app knows, so it went to the external browser. The conversation page carries the intact link.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late SettingsRepository settings;
  final launched = <String>[];

  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    final storage = StorageProvider(db, {}, {});
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
    launched.clear();
    for (final channel in ['plugins.flutter.io/url_launcher', 'plugins.flutter.io/url_launcher_linux']) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        MethodChannel(channel),
        (call) async {
          if (call.method == 'launch') {
            launched.add((call.arguments as Map)['url'] as String);
          }
          return true;
        },
      );
    }
  });
  tearDown(() async {
    await getIt.get<ImageCacheProvider>().dispose();
    await getIt.reset();
    await settings.dispose();
    await db.close();
  });

  PersonalMessageV2 summary() {
    final dl = parseHtmlDocument(_data('pm_list_bare_url_x5.html')).querySelector('dl[id^="pmlist_"]')!;
    return PersonalMessage.toV2(dl)!;
  }

  /// Spans of the rendered rich texts that react to a tap.
  List<TextSpan> tappableSpans(WidgetTester tester) {
    final spans = <TextSpan>[];
    for (final text in tester.widgetList<Text>(find.byType(Text))) {
      text.textSpan?.visitChildren((span) {
        if (span is TextSpan && span.recognizer != null) {
          spans.add(span);
        }
        return true;
      });
    }
    return spans;
  }

  test('the list summary has lost the & of the url, the conversation keeps it', () {
    final data = summary();
    expect(data.data, contains('https://www.tsdm39.com/forum.php?mod=viewthreadtid=1264975'));
    expect(data.data, isNot(contains('viewthread&tid')));
    // That text is not a route the app knows, which is why it used to reach the external browser.
    expect('https://www.tsdm39.com/forum.php?mod=viewthreadtid=1264975'.parseUrlToRoute(), isNull);

    // The conversation page has the message as plain text with the url intact; the muncher links bare urls there.
    final message = parseHtmlDocument(
      _data('chat_history_bare_url_x5.html'),
    ).querySelectorAll('dd.ptm').map((e) => e.text ?? '').firstWhere((e) => e.contains('链接测试'));
    final url = RegExp(r'https?://\S+').firstMatch(message)!.group(0)!;
    expect(url, 'https://www.tsdm39.com/forum.php?mod=viewthread&tid=1264975');
    expect(url.parseUrlToRoute()?.screenPath, ScreenPaths.threadV1);
  });

  testWidgets('the summary used to be rendered with a tappable url that launched the browser', (tester) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(home: Scaffold(body: MunchedHtml(summary().data))),
      ),
    );
    await tester.pumpAndSettle();
    final spans = tappableSpans(tester);
    expect(spans.map((e) => e.text), ['https://www.tsdm39.com/forum.php?mod=viewthreadtid=1264975']);
    // Tests run as desktop: a tap-down opens the url.
    (spans.single.recognizer! as TapGestureRecognizer).onTapDown!(TapDownDetails());
    await tester.pumpAndSettle();
    expect(launched, ['https://www.tsdm39.com/forum.php?mod=viewthreadtid=1264975']);
  });

  testWidgets('the message card shows the summary as plain text; a tap opens the conversation, not the browser', (
    tester,
  ) async {
    final data = summary().copyWith(alreadyRead: true);
    final auth = AuthenticationRepository();
    addTearDown(auth.dispose);
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => Scaffold(body: PersonalMessageCardV2(data)),
        ),
        GoRoute(
          path: ScreenPaths.chatHistory,
          name: ScreenPaths.chatHistory,
          builder: (_, state) => Text('chat history ${state.pathParameters['uid']}'),
        ),
      ],
    );
    await tester.pumpWidget(
      TranslationProvider(
        child: RepositoryProvider<AuthenticationRepository>.value(
          value: auth,
          child: MaterialApp.router(routerConfig: router),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.widget<MunchedHtml>(find.byType(MunchedHtml)).options.renderUrl, isFalse);
    expect(tappableSpans(tester), isEmpty);
    final urlText = find.byWidgetPredicate(
      (w) => w is Text && (w.textSpan?.toPlainText().contains('viewthreadtid=1264975') ?? false),
    );
    expect(urlText, findsOneWidget);

    await tester.tap(urlText);
    await tester.pumpAndSettle();
    expect(find.text('chat history 1000'), findsOneWidget);
    expect(launched, isEmpty);
  });
}
