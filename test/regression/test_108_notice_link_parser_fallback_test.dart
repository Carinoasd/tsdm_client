import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/notification/bloc/notification_bloc.dart';
import 'package:tsdm_client/features/notification/bloc/notification_state_cubit.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/features/notification/repository/notification_info_repository.dart';
import 'package:tsdm_client/features/open_in_app/view/open_in_app_page.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/widgets/card/notice_card_v2.dart';
import 'package:tsdm_client/widgets/munched_html.dart';

/// GitHub #105, reporter feedback: on a device where another build of the app is installed, tapping the report link
/// of a notice asked the system which app should open it, before the app's own "Open in app" page was ever shown.
///
/// The link is a forum link the app has no page for (`forum.php?mod=modcp&action=report`); the url dispatcher handed
/// every such link to the platform, and on Android the platform offers it to every app claiming forum links. Now an
/// unsupported forum link opens the "Open in app" page with the link filled in and nothing else; the browser is only
/// started by its button, through the app's own main channel.
///
/// Links are tapped in the real notice card ([NoticeCardV2]) and the real html renderer ([MunchedHtml]); the "Open in
/// app" route is built like in the app router. Every launch channel is answered by the test and a launch nobody asked
/// for fails the test. Widget tests run as Android (the flutter_test default).
Translations get tr => LocaleSettings.instance.currentTranslations;

const _mainChannel = MethodChannel('kzs.th000.tsdm_client/mainChannel');

/// The channels a generic launch (url_launcher) may use.
const _launcherChannels = [
  MethodChannel('plugins.flutter.io/url_launcher'),
  MethodChannel('plugins.flutter.io/url_launcher_android'),
  MethodChannel('plugins.flutter.io/url_launcher_linux'),
];

/// The report link of a moderator notice, as the forum writes it: relative, an encoded value in the query, a fragment.
const _reportHref = 'forum.php?mod=modcp&amp;action=report&amp;fid=247&amp;op=list&amp;extra=page%3D1#reports';

/// [_reportHref] on the forum host.
const _report = 'https://www.tsdm39.com/forum.php?mod=modcp&action=report&fid=247&op=list&extra=page%3D1#reports';

/// A report notice: the reporter, the reported thread and the link to the report list.
const _noticeHtml =
    '<a href="home.php?mod=space&amp;uid=1000" target="_blank">Alice</a> 举报了帖子 '
    '<a href="forum.php?mod=viewthread&amp;tid=123&amp;page=2" target="_blank">测试帖</a>， '
    '<a href="$_reportHref" target="_blank">查看举报</a>';

final class _Auth extends Fake implements AuthenticationRepository {
  @override
  UserLoginInfo? get currentUser => const UserLoginInfo(username: 'Bob', uid: 1001);
}

/// Records what the card sends when a link is opened.
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

/// Let the platform answers and route changes land, then show what they caused (snack bars included).
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 20));
  }
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
}

void main() {
  late AppDatabase db;
  late SettingsRepository settings;
  late GoRouter router;

  /// Urls handed to url_launcher, whatever the method.
  final generic = <String>[];

  /// Calls on the main channel (the Android browser launch).
  final mainCalls = <MethodCall>[];

  /// Launches nobody asked for; must stay empty.
  final unexpected = <String>[];

  /// Whether the test tapped the browser button: only then may the main channel be used.
  var browserTapped = false;

  /// Whether the test dispatches a link that is meant for url_launcher (foreign, or explicitly external).
  var genericExpected = false;

  /// "Open in app" pages built, once per page however often it is built: their query parameters.
  final parserPages = <LocalKey, Map<String, String>>{};

  /// Other in-app pages opened, once per page.
  final opened = <LocalKey, (String, Map<String, String>)>{};

  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
  });

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    final storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings);
    await settings.init();

    generic.clear();
    mainCalls.clear();
    unexpected.clear();
    parserPages.clear();
    opened.clear();
    browserTapped = false;
    genericExpected = false;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final channel in _launcherChannels) {
      messenger.setMockMethodCallHandler(channel, (call) async {
        final url = '${(call.arguments as Map<Object?, Object?>)['url']}';
        generic.add(url);
        if (!genericExpected) {
          unexpected.add('${channel.name} ${call.method} $url');
        }
        return true;
      });
    }
    messenger.setMockMethodCallHandler(_mainChannel, (call) async {
      mainCalls.add(call);
      if (!browserTapped) {
        unexpected.add('${_mainChannel.name} ${call.method} ${call.arguments}');
      }
      return true;
    });
  });

  tearDown(() async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final channel in [..._launcherChannels, _mainChannel]) {
      messenger.setMockMethodCallHandler(channel, null);
    }
    expect(unexpected, isEmpty, reason: 'nothing is launched before the user asks for the browser');
    await getIt.reset();
    await settings.dispose();
    await db.close();
  });

  /// The app shell: [home] at `/`, the "Open in app" route built like in the app router, and two in-app pages.
  Future<void> pumpApp(WidgetTester tester, Widget home) async {
    GoRoute page(String path) => GoRoute(
      path: path,
      name: path,
      builder: (context, state) {
        opened[state.pageKey] = (path, state.uri.queryParameters);
        return Scaffold(body: Text('in app $path'));
      },
    );
    router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => Scaffold(body: home),
        ),
        GoRoute(
          path: ScreenPaths.openInApp,
          name: ScreenPaths.openInApp,
          builder: (context, state) {
            parserPages[state.pageKey] = state.uri.queryParameters;
            return OpenInAppPage(
              initialUrl: state.uri.queryParameters['url'],
              autoOpen: state.uri.queryParameters['autoOpen'] == 'true',
            );
          },
        ),
        page(ScreenPaths.threadV1),
        page(ScreenPaths.profile),
      ],
    );
    addTearDown(router.dispose);
    final info = NotificationInfoRepository();
    final counts = NotificationStateCubit(info);
    addTearDown(() async {
      await counts.close();
      await info.dispose();
    });
    await tester.pumpWidget(
      TranslationProvider(
        child: RepositoryProvider<AuthenticationRepository>.value(
          value: _Auth(),
          child: MultiBlocProvider(
            providers: [
              BlocProvider<NotificationBloc>.value(value: _Notifications()),
              BlocProvider<NotificationStateCubit>.value(value: counts),
            ],
            child: MaterialApp.router(routerConfig: router, scaffoldMessengerKey: snackbarKey),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Widget noticeCard([String html = _noticeHtml]) =>
      ListView(children: [NoticeCardV2(NoticeV2(id: 1, timestamp: 1788000000, data: html))]);

  /// A button dispatching [url] the way the app's other callers do.
  Widget link(String url, {bool external = false}) => Builder(
    builder: (context) => TextButton(
      onPressed: () async => context.dispatchAsUrl(url, external: external),
      child: const Text('open'),
    ),
  );

  Future<void> tapText(WidgetTester tester, String text) async {
    await tester.tapOnText(find.textRange.ofSubstring(text));
    await settle(tester);
  }

  Finder browserButton() => find.byKey(const ValueKey('open-in-app-browser'));

  Future<void> tapBrowser(WidgetTester tester) async {
    browserTapped = true;
    await tester.ensureVisible(browserButton());
    await tester.tap(browserButton());
    await settle(tester);
  }

  String fieldText(WidgetTester tester) => tester.widget<TextFormField>(find.byType(TextFormField)).controller!.text;

  /// The "Open in app" page shows [url] and nothing was launched to get there.
  void expectParserPage(WidgetTester tester, String url) {
    expect(find.byType(OpenInAppPage), findsOneWidget);
    expect(parserPages.values.last, {'url': url, 'autoOpen': 'false'}, reason: 'the link is passed once encoded');
    expect(fieldText(tester), url, reason: 'query and fragment as written');
    expect(opened, isEmpty);
    expect(generic, isEmpty);
    expect(mainCalls, isEmpty);
  }

  group('notice card', () {
    testWidgets('the report link opens the "Open in app" page first, the browser only on its button', (tester) async {
      await pumpApp(tester, noticeCard());
      await tapText(tester, '查看举报');
      expectParserPage(tester, _report);

      // Still nothing on its own, also after a while.
      await settle(tester);
      await settle(tester);
      expect(generic, isEmpty);
      expect(mainCalls, isEmpty);

      // Opening in the app is refused as unsupported, and does not launch anything either.
      await tester.tap(find.text(tr.openInAppPage.open));
      await settle(tester);
      expect(find.text(tr.openInAppPage.url.unsupportedUrl), findsOneWidget);
      expect(generic, isEmpty);
      expect(mainCalls, isEmpty);

      await tapBrowser(tester);
      expect(mainCalls.single.method, 'openInBrowser');
      expect(mainCalls.single.arguments, {'url': _report});
      expect(generic, isEmpty, reason: 'never the generic launch on Android: it may reach another installed app');
      expect(find.byType(OpenInAppPage), findsOneWidget);
    });

    testWidgets('back returns to the notice and the link opens the page again', (tester) async {
      await pumpApp(tester, noticeCard());
      await tapText(tester, '查看举报');
      expectParserPage(tester, _report);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(OpenInAppPage), findsNothing);
      expect(find.byType(NoticeCardV2), findsOneWidget);

      await tapText(tester, '查看举报');
      expect(parserPages, hasLength(2), reason: 'a new page for the second tap');
      expectParserPage(tester, _report);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(NoticeCardV2), findsOneWidget);
      expect(generic, isEmpty);
      expect(mainCalls, isEmpty);
    });

    testWidgets('the link icon, which dispatches the href as written, lands on the same forum link', (tester) async {
      await pumpApp(tester, noticeCard('<a href="$_reportHref">查看举报</a>'));
      await tester.tap(find.byIcon(Icons.link));
      await settle(tester);
      expectParserPage(tester, _report);
    });

    testWidgets('thread and profile links still open in the app', (tester) async {
      await pumpApp(tester, noticeCard());
      await tapText(tester, '测试帖');
      expect(opened.values.single.$1, ScreenPaths.threadV1);
      expect(opened.values.single.$2, containsPair('tid', '123'));
      expect(opened.values.single.$2, containsPair('pageNumber', '2'));

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tapText(tester, 'Alice');
      expect(opened.values.last.$1, ScreenPaths.profile);
      expect(opened.values.last.$2, {'uid': '1000'});
      expect(opened, hasLength(2));
      expect(parserPages, isEmpty);
      expect(generic, isEmpty);
      expect(mainCalls, isEmpty);
    });
  });

  group('rendered links', () {
    for (final url in [
      'https://www.tsdm39.com/forum.php?mod=modcp&action=report&fid=247#reports',
      'http://www.tsdm39.com/forum.php?mod=modcp&action=report&fid=247#reports',
      'https://tsdm39.com/forum.php?mod=modcp&action=report&fid=247#reports',
      'http://tsdm39.com/forum.php?mod=modcp&action=report&fid=247#reports',
      'https://www.tsdm39.com/plugin.php?id=tsdmtitle:tsdmtitle&kw=%E4%B8%AD%20x&r=a%26b%3Dc',
    ]) {
      testWidgets('unsupported forum link $url opens the page as written', (tester) async {
        await pumpApp(tester, MunchedHtml('<a href="$url">report</a>'));
        await tapText(tester, 'report');
        expectParserPage(tester, url);
      });
    }

    for (final url in [
      'https://www.tsdm39.com.evil.example/forum.php?mod=modcp&action=report',
      'https://evil.example/forum.php?mod=viewthread&tid=1',
      'https://www.tsdm39.com@evil.example/forum.php?mod=modcp&action=report',
      'https://example.com/a?b=1#c',
    ]) {
      testWidgets('foreign link $url still goes to the browser directly', (tester) async {
        genericExpected = true;
        await pumpApp(tester, MunchedHtml('<a href="$url">foreign</a>'));
        await tapText(tester, 'foreign');
        expect(generic, [url]);
        expect(parserPages, isEmpty);
        expect(opened, isEmpty);
        expect(mainCalls, isEmpty);
      });
    }
  });

  group('dispatched links', () {
    for (final (url, expected) in [
      (
        'forum.php?mod=modcp&action=report&fid=247#reports',
        'https://www.tsdm39.com/forum.php?mod=modcp&action=report&fid=247#reports',
      ),
      (
        '/forum.php?mod=modcp&action=report&fid=247#reports',
        'https://www.tsdm39.com/forum.php?mod=modcp&action=report&fid=247#reports',
      ),
      (
        'plugin.php?id=tsdmtitle:tsdmtitle&action=shop',
        'https://www.tsdm39.com/plugin.php?id=tsdmtitle:tsdmtitle&action=shop',
      ),
    ]) {
      testWidgets('relative $url is resolved on the forum host', (tester) async {
        await pumpApp(tester, link(url));
        await tapText(tester, 'open');
        expectParserPage(tester, expected);
      });
    }

    testWidgets('an explicitly external link still goes to the browser directly', (tester) async {
      genericExpected = true;
      await pumpApp(tester, link(_report, external: true));
      await tapText(tester, 'open');
      expect(generic, [_report]);
      expect(parserPages, isEmpty);
      expect(mainCalls, isEmpty);
    });

    testWidgets('a supported link is opened in the app, not on the "Open in app" page', (tester) async {
      await pumpApp(tester, link('https://tsdm39.com/forum.php?mod=viewthread&tid=9'));
      await tapText(tester, 'open');
      expect(opened.values.single.$1, ScreenPaths.threadV1);
      expect(opened.values.single.$2, {'tid': '9'});
      expect(parserPages, isEmpty);
      expect(generic, isEmpty);
    });
  });
}
