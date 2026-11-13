// The search page opens a forum link pasted into its keyword field (a link token: "【天使动漫】<title> <link>
// 点击链接直接打开"), with no clipboard read and whatever the clipboard setting says: right away when pasted at once,
// on submit, or from the line above the results when typed by hand. A link of another site stays a keyword.
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/search/view/search_page.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/shared/repositories/fragments_repository/fragments_repository.dart';
import 'package:tsdm_client/widgets/debounce_buttons.dart';

const _alice = UserLoginInfo(username: 'Alice', uid: 31);

const _token = '【天使动漫】某某标题 https://www.tsdm39.com/forum.php?mod=viewthread&tid=123 点击链接直接打开';
const _link = 'https://www.tsdm39.com/forum.php?mod=viewthread&tid=456';
const _foreign = 'https://example.com/forum.php?mod=viewthread&tid=789';

/// A forum answering every request with the page of a refused search, recording it.
final class _Forum implements HttpClientAdapter {
  final requests = <Uri>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options.uri);
    return ResponseBody.fromString(
      File('test/data/search_ctrl_x5.html').readAsStringSync(),
      200,
      headers: {
        Headers.contentTypeHeader: ['text/html; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late _Forum forum;
  late AppDatabase db;
  late StorageProvider storage;
  late SettingsRepository settings;
  late SettingsBloc settingsBloc;
  late List<String> opened;
  late GoRouter router;
  late List<MethodCall> clipboardCalls;

  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
  });

  setUp(() async {
    await LocaleSettings.setLocale(AppLocale.zhCn);
    TsdmAppApi.reset();
    forum = _Forum();
    db = AppDatabase(NativeDatabase.memory());
    storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
    getIt
      ..allowReassignment = true
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
      ..registerFactory<NetClientProvider>(
        () => NetClientProvider.buildNoCookie(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum),
      )
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings);
    await settings.init();
    settingsBloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository());
    opened = [];
    router = GoRouter(
      initialLocation: ScreenPaths.search,
      routes: [
        GoRoute(path: ScreenPaths.search, builder: (_, _) => const SearchPage()),
        for (final path in [ScreenPaths.threadV1, ScreenPaths.openInApp, ScreenPaths.inAppBrowser])
          GoRoute(
            path: path,
            name: path,
            builder: (_, state) {
              opened.add('$path ${state.uri.queryParameters}');
              return const Scaffold(body: Text('opened'));
            },
          ),
      ],
    );
  });

  tearDown(() async {
    await settingsBloc.close();
    await settings.dispose();
    await db.close();
    await getIt.reset();
    getIt.allowReassignment = false;
  });

  Future<void> pumpPage(WidgetTester tester) async {
    clipboardCalls = [];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') {
        clipboardCalls.add(call);
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(
      TranslationProvider(
        child: RepositoryProvider<AuthenticationRepository>.value(
          value: AuthenticationRepository(user: _alice),
          child: BlocProvider<SettingsBloc>.value(
            value: settingsBloc,
            child: MaterialApp.router(routerConfig: router),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder keywordField() => find.byType(TextFormField).first;

  String keyword(WidgetTester tester) => tester.widget<TextFormField>(keywordField()).controller!.text;

  Future<void> type(WidgetTester tester, String before, String text) async {
    for (var i = 1; i <= text.length; i++) {
      await tester.enterText(keywordField(), before + text.substring(0, i));
      await tester.pump();
    }
  }

  Future<void> goBack(WidgetTester tester) async {
    router.pop();
    await tester.pumpAndSettle();
  }

  testWidgets('a pasted token opens its thread; back on the page the field is as before and nothing opens again', (
    tester,
  ) async {
    await pumpPage(tester);
    await tester.enterText(keywordField(), _token);
    await tester.pumpAndSettle();
    expect(opened, ['${ScreenPaths.threadV1} {tid: 123}']);

    await goBack(tester);
    expect(find.byType(SearchPage), findsOneWidget);
    expect(keyword(tester), '');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(opened, hasLength(1));
    expect(find.byKey(const ValueKey('search-open-link')), findsNothing);
    expect(forum.requests, isEmpty);
    expect(clipboardCalls, isEmpty, reason: 'the clipboard is never read');
  });

  testWidgets('a link pasted after typed words opens it, the words stay', (tester) async {
    await pumpPage(tester);
    await type(tester, '', 'ab');
    await tester.enterText(keywordField(), 'ab$_link');
    await tester.pumpAndSettle();
    expect(opened, ['${ScreenPaths.threadV1} {tid: 456}']);
    await goBack(tester);
    expect(keyword(tester), 'ab');
  });

  testWidgets('a forum link the app has no page for opens as other forum links do', (
    tester,
  ) async {
    await pumpPage(tester);
    await tester.enterText(keywordField(), '看 https://www.tsdm39.com/plugin.php?id=xyz 吧');
    await tester.pumpAndSettle();
    expect(opened, hasLength(1));
    // The in-app browser where the platform has one (the setting is on by default), else the "open in app" page.
    expect(opened.single, anyOf(startsWith(ScreenPaths.inAppBrowser), startsWith(ScreenPaths.openInApp)));
    expect(opened.single, contains('plugin.php?id=xyz'));
  });

  testWidgets('a link of another site stays a keyword and is searched', (tester) async {
    await pumpPage(tester);
    await tester.enterText(keywordField(), _foreign);
    await tester.pumpAndSettle();
    expect(opened, isEmpty);
    expect(keyword(tester), _foreign);
    expect(find.byKey(const ValueKey('search-open-link')), findsNothing);

    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(opened, isEmpty);
    expect(forum.requests, isNotEmpty);
    expect(forum.requests.first.queryParameters['srchtxt'], _foreign);
  });

  testWidgets('the name of the site in words is no link: searched as typed', (tester) async {
    await pumpPage(tester);
    await tester.enterText(keywordField(), '有人能上tsdm39.com?');
    await tester.pumpAndSettle();
    expect(opened, isEmpty);
    await tester.enterText(keywordField(), 'tsdm39.com 打不开');
    await tester.pumpAndSettle();
    expect(opened, isEmpty);
    expect(find.byKey(const ValueKey('search-open-link')), findsNothing);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(opened, isEmpty);
    expect(forum.requests.first.queryParameters['srchtxt'], 'tsdm39.com 打不开');
  });

  testWidgets('a link pasted over the whole selected text opens, also over a shorter link', (tester) async {
    await pumpPage(tester);
    const one = 'https://www.tsdm39.com/forum.php?mod=viewthread&tid=4';
    await type(tester, '', one);
    tester.widget<TextFormField>(keywordField()).controller!.selection = const TextSelection(
      baseOffset: 0,
      extentOffset: one.length,
    );
    await tester.pump();
    await tester.enterText(keywordField(), '${one}56');
    await tester.pumpAndSettle();
    expect(opened, ['${ScreenPaths.threadV1} {tid: 456}']);
    await goBack(tester);
    expect(keyword(tester), one);
  });

  testWidgets('a link typed by hand does not open by itself: the line above the results opens it', (tester) async {
    await pumpPage(tester);
    await type(tester, '', _link);
    await tester.pumpAndSettle();
    expect(opened, isEmpty);
    expect(keyword(tester), _link);
    final row = find.byKey(const ValueKey('search-open-link'));
    expect(row, findsOneWidget);
    expect(find.descendant(of: row, matching: find.text(t.linkToken.openThread)), findsOneWidget);

    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(opened, ['${ScreenPaths.threadV1} {tid: 456}']);
    await goBack(tester);
    expect(opened, hasLength(1));
    expect(forum.requests, isEmpty);
  });

  testWidgets('a forum page typed by hand is offered as a page', (tester) async {
    await pumpPage(tester);
    await type(tester, '', 'tsdm39.com/forum.php?mod=forumdisplay&fid=8');
    await tester.pumpAndSettle();
    final row = find.byKey(const ValueKey('search-open-link'));
    expect(find.descendant(of: row, matching: find.text(t.linkToken.openPage)), findsOneWidget);
  });

  testWidgets('submitting a link opens it instead of searching, by the keyboard and by the button', (tester) async {
    await pumpPage(tester);
    await type(tester, '', _link);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(opened, ['${ScreenPaths.threadV1} {tid: 456}']);
    await goBack(tester);

    await tester.tap(find.byType(DebounceFilledButton));
    await tester.pumpAndSettle();
    expect(opened, hasLength(2));
    await goBack(tester);
    expect(forum.requests, isEmpty, reason: 'no search asked');
    expect(opened, hasLength(2));
  });
}
