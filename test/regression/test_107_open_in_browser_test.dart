import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/open_in_app/models/openable_forum_resource_model.dart';
import 'package:tsdm_client/features/open_in_app/view/open_in_app_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/browser_launcher.dart';

/// GitHub #105: links the app can not open itself (report notices of moderators, for example) end on the "Open in
/// app" page as unsupported. The page offers to open the entered link in the external browser.
///
/// Link policy tested here ([parseBrowserLink]):
///
/// * input is trimmed; whitespace left inside rejects it;
/// * absolute `http`/`https` links with a host are opened as typed, query and fragment included, whether the app
///   supports them or not, forum or not;
/// * a forum script link without host (`home.php?...`, `/forum.php?...`) is opened on `https://www.tsdm39.com`;
/// * everything else is rejected with a hint: empty, other schemes, no host, usernames, ids, host without scheme.
///
/// Launch path ([openInExternalBrowser]): on Android the app's main channel starts a browser only, because the app
/// itself catches forum links and a generic view intent could come back to it; there is no fallback to url_launcher.
/// Elsewhere url_launcher opens the link in the external application.
///
/// No browser is started: both platform channels are answered by the test. Widget tests run as Android (the
/// flutter_test default) unless a [TargetPlatformVariant] says otherwise.
Translations get tr => LocaleSettings.instance.currentTranslations;

const _channel = MethodChannel('plugins.flutter.io/url_launcher');

const _mainChannel = MethodChannel('kzs.th000.tsdm_client/mainChannel');

/// Every platform other than Android, where url_launcher is used.
const _nonAndroid = TargetPlatformVariant({
  TargetPlatform.iOS,
  TargetPlatform.macOS,
  TargetPlatform.windows,
  TargetPlatform.linux,
  TargetPlatform.fuchsia,
});

const _supported = 'https://www.tsdm39.com/forum.php?mod=viewthread&tid=123&page=2#pid456';
const _report = 'https://www.tsdm39.com/forum.php?mod=modcp&action=report&fid=247&op=list#reports';
const _foreign = 'https://example.com/path/a?b=1&c=%E4%B8%AD#frag';

Finder get _browser => find.byKey(const ValueKey('open-in-app-browser'));

Finder get _field => find.byType(TextFormField);

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
  /// Links handed to a platform to open, whichever channel took them.
  final launched = <String>[];

  /// The channel of each launch, in order: `main` (Android browser only) or `url_launcher`.
  final via = <String>[];

  /// Raw calls on the main channel, to check method and arguments exactly.
  final mainCalls = <MethodCall>[];

  /// What the platform answers to a launch: a value, a thrown error or a future the test completes.
  late Future<Object?> Function() answer;

  late GoRouter router;

  /// In-app pages opened, once per page however often it is built.
  final opened = <LocalKey, (String, Map<String, String>)>{};

  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(useConsoleLogs: false));
    await LocaleSettings.setLocale(AppLocale.en);
  });

  setUp(() {
    launched.clear();
    via.clear();
    mainCalls.clear();
    opened.clear();
    answer = () async => true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      ..setMockMethodCallHandler(_channel, (call) async {
        launched.add((call.arguments as Map<Object?, Object?>)['url']! as String);
        via.add('url_launcher');
        return answer();
      })
      ..setMockMethodCallHandler(_mainChannel, (call) async {
        mainCalls.add(call);
        launched.add((call.arguments as Map<Object?, Object?>)['url']! as String);
        via.add('main');
        return answer();
      });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      ..setMockMethodCallHandler(_channel, null)
      ..setMockMethodCallHandler(_mainChannel, null);
  });

  /// The app shell: a home page, the page under test pushed on it and two in-app destinations.
  Future<void> pumpApp(WidgetTester tester, {String? initialUrl, bool autoOpen = false, Size? size}) async {
    if (size != null) {
      tester.view
        ..physicalSize = size
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }
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
          builder: (context, state) => const Scaffold(body: Text('home')),
        ),
        GoRoute(
          path: ScreenPaths.openInApp,
          name: ScreenPaths.openInApp,
          builder: (context, state) => OpenInAppPage(initialUrl: initialUrl, autoOpen: autoOpen),
        ),
        page(ScreenPaths.threadV1),
        page(ScreenPaths.profile),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp.router(routerConfig: router, scaffoldMessengerKey: snackbarKey),
      ),
    );
    unawaited(router.pushNamed(ScreenPaths.openInApp));
    await tester.pumpAndSettle();
  }

  Future<void> enter(WidgetTester tester, String text) async {
    await tester.enterText(_field, text);
    await tester.pump();
  }

  Future<void> tapBrowser(WidgetTester tester) async {
    await tester.ensureVisible(_browser);
    await tester.tap(_browser);
    await settle(tester);
  }

  Future<void> tapOpen(WidgetTester tester) async {
    await tester.tap(find.text(tr.openInAppPage.open));
    await settle(tester);
  }

  bool enabled(WidgetTester tester) => tester.widget<OutlinedButton>(_browser).onPressed != null;

  group('parseBrowserLink', () {
    test('keeps http(s) links as typed, trimmed, query and fragment included', () {
      for (final (input, expected) in [
        (_supported, _supported),
        (_report, _report),
        (_foreign, _foreign),
        ('  $_foreign\n', _foreign),
        ('http://www.tsdm39.com/home.php?mod=space&do=notice', 'http://www.tsdm39.com/home.php?mod=space&do=notice'),
        ('HTTPS://Example.com/A?x=1', 'https://example.com/A?x=1'),
      ]) {
        expect(parseBrowserLink(input)?.toString(), expected, reason: input);
      }
    });

    test('puts forum script links without host on the canonical forum host', () {
      expect(
        parseBrowserLink('home.php?mod=space&do=notice&view=manage#n')?.toString(),
        'https://www.tsdm39.com/home.php?mod=space&do=notice&view=manage#n',
      );
      expect(
        parseBrowserLink(' /forum.php?mod=modcp&action=report ')?.toString(),
        'https://www.tsdm39.com/forum.php?mod=modcp&action=report',
      );
      expect(parseBrowserLink('forum.php')?.toString(), 'https://www.tsdm39.com/forum.php');
    });

    test('rejects everything that is not a web link', () {
      for (final input in [
        null,
        '',
        '   ',
        'javascript:alert(1)',
        'JavaScript:alert(1)',
        'data:text/html,hi',
        'file:///etc/passwd',
        'tsdm://thread/1',
        'mailto:someone@example.com',
        'ftp://example.com/a',
        'https://',
        'http:///path',
        'https:example.com',
        '12345',
        'Alice',
        'Alice Bob',
        'www.tsdm39.com/forum.php?mod=viewthread&tid=1',
        '//www.tsdm39.com/forum.php',
        'https://exa mple.com/',
        'https://example.com/a b',
        'https://[bad',
        'home.php?mod=space&do=notice extra',
        '../forum.php',
      ]) {
        expect(parseBrowserLink(input), isNull, reason: '$input');
      }
    });
  });

  group('parseBrowserLink with malformed links', () {
    test('never throws; anything accepted is http(s) with a host and survives a round trip', () {
      for (final input in [
        'https://example.com:99999/',
        'https://example.com:abc/',
        'https://example.com:/',
        'https://:80/',
        'https://%zz/',
        'https://%E4%B8%AD.example/',
        'https://example.com/?q=%zz',
        'https://example.com/?q=%FF%FE',
        'https://example.com/#%',
        'https://[::1]:8080/a?b#c',
        'https://[::1/',
        'https://user:pass@example.com/',
        'https://example.com/%',
        'https://www.tsdm39.com/forum.php?mod=viewthread&tid=%FF',
        'http://a',
        'https://.',
        'forum.php?%',
        'forum.php#%FF',
      ]) {
        final Uri? uri;
        try {
          uri = parseBrowserLink(input);
        } on Object catch (e) {
          fail('"$input" threw $e');
        }
        if (uri == null) {
          continue;
        }
        expect(uri.isScheme('http') || uri.isScheme('https'), isTrue, reason: input);
        expect(uri.host, isNotEmpty, reason: input);
        expect(Uri.tryParse(uri.toString()), isNotNull, reason: input);
      }
    });
  });

  group('openInExternalBrowser', () {
    // flutter_test reports Android as the target platform by default.
    test('Android: the main channel opens the exact link in a browser, url_launcher is not used', () async {
      expect(defaultTargetPlatform, TargetPlatform.android);
      for (final url in [_supported, _report, _foreign]) {
        expect(await openInExternalBrowser(parseBrowserLink(url)!), isTrue);
      }
      expect(mainCalls.map((e) => e.method), everyElement('openInBrowser'));
      expect(mainCalls.map((e) => e.arguments), [
        {'url': _supported},
        {'url': _report},
        {'url': _foreign},
      ]);
      expect(via, ['main', 'main', 'main']);
    });

    test('Android: a refusal is false and nothing else is tried', () async {
      answer = () async => false;
      expect(await openInExternalBrowser(Uri.parse(_supported)), isFalse);
      answer = () async => null;
      expect(await openInExternalBrowser(Uri.parse(_supported)), isFalse, reason: 'no answer is not a success');
      expect(via, ['main', 'main']);
    });

    test('Android: platform errors are thrown, never answered by a generic launch', () async {
      answer = () async => throw PlatformException(code: 'error', message: 'no browser');
      await expectLater(openInExternalBrowser(Uri.parse(_supported)), throwsA(isA<PlatformException>()));

      // An engine without the handler (MissingPluginException) is not a reason to use a generic view intent either.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_mainChannel, null);
      await expectLater(openInExternalBrowser(Uri.parse(_supported)), throwsA(isA<MissingPluginException>()));
      expect(via, ['main'], reason: 'url_launcher is never used on Android');
    });

    for (final platform in _nonAndroid.values) {
      test('${platform.name}: url_launcher opens the exact link, the main channel is not used', () async {
        debugDefaultTargetPlatformOverride = platform;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        expect(await openInExternalBrowser(parseBrowserLink(_supported)!), isTrue);
        answer = () async => false;
        expect(await openInExternalBrowser(parseBrowserLink(_foreign)!), isFalse);
        answer = () async => throw PlatformException(code: 'error');
        await expectLater(openInExternalBrowser(parseBrowserLink(_report)!), throwsA(isA<PlatformException>()));
        expect(launched, [_supported, _foreign, _report]);
        expect(via, everyElement('url_launcher'));
        expect(mainCalls, isEmpty);
      });
    }
  });

  group('browser button per platform', () {
    testWidgets('Android: a forum link the app itself catches goes to the browser through the main channel', (
      tester,
    ) async {
      await pumpApp(tester);
      await enter(tester, _supported);
      await tapBrowser(tester);
      expect(via, ['main']);
      expect(mainCalls.single.method, 'openInBrowser');
      expect(mainCalls.single.arguments, {'url': _supported}, reason: 'query and fragment are sent as typed');
      expect(find.text(tr.openInAppPage.browserLaunchFailed), findsNothing);
      expect(opened, isEmpty);
    });

    testWidgets('Android: no handler for the main channel shows a failure, no generic launch', (tester) async {
      await pumpApp(tester);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_mainChannel, null);
      await enter(tester, _report);
      await tapBrowser(tester);
      expect(via, isEmpty);
      expect(find.text(tr.openInAppPage.browserLaunchFailed), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(enabled(tester), isTrue);
    });

    testWidgets('url_launcher opens the link and failures are shown', (tester) async {
      await pumpApp(tester);
      await enter(tester, _supported);
      await tapBrowser(tester);
      expect(launched, [_supported]);
      expect(via, ['url_launcher']);
      expect(mainCalls, isEmpty);
      expect(find.text(tr.openInAppPage.browserLaunchFailed), findsNothing);

      answer = () async => false;
      await tapBrowser(tester);
      expect(find.text(tr.openInAppPage.browserLaunchFailed), findsOneWidget);
      expect(via, ['url_launcher', 'url_launcher']);
      expect(mainCalls, isEmpty);
    }, variant: _nonAndroid);

    testWidgets('malformed links show a hint or a result, never an error', (tester) async {
      await pumpApp(tester);
      for (final input in [
        'https://example.com:abc/',
        'https://%zz/',
        'https://[::1/',
        'https://www.tsdm39.com/forum.php?mod=viewthread&tid=%FF',
        'https://example.com/?q=%FF%FE',
      ]) {
        final before = launched.length;
        await enter(tester, input);
        await tapBrowser(tester);
        expect(tester.takeException(), isNull, reason: input);
        final hinted = find.text(tr.openInAppPage.invalidBrowserLink).evaluate().isNotEmpty;
        expect(hinted || launched.length == before + 1, isTrue, reason: '$input: a hint or a launch');
        expect(enabled(tester), isTrue, reason: input);

        // The in-app route check of the same text must not throw either.
        await tester.tap(find.text(tr.openInAppPage.open));
        await settle(tester);
        expect(tester.takeException(), isNull, reason: input);
        if (find.byType(OpenInAppPage).evaluate().isEmpty) {
          // Recognized as a forum route and opened: come back for the next input.
          router.pop();
          await tester.pumpAndSettle();
          unawaited(router.pushNamed(ScreenPaths.openInApp));
          await tester.pumpAndSettle();
        }
      }
    });
  });

  group('browser button', () {
    testWidgets('a link the app supports opens in the browser as typed, and still opens in the app', (tester) async {
      await pumpApp(tester);
      await enter(tester, _supported);
      await tapBrowser(tester);
      expect(launched, [_supported]);
      expect(opened, isEmpty, reason: 'the browser button never routes in the app');
      expect(find.byType(OpenInAppPage), findsOneWidget);

      await tapOpen(tester);
      expect(launched, hasLength(1), reason: 'Open never starts the browser');
      expect(opened.values.single.$1, ScreenPaths.threadV1);
      expect(opened.values.single.$2, containsPair('tid', '123'));
      expect(opened.values.single.$2, containsPair('pageNumber', '2'));
      expect(opened.values.single.$2, containsPair('pid', '456'));
      expect(find.byType(OpenInAppPage), findsNothing);
    });

    for (final (name, url) in [('report notice', _report), ('foreign site', _foreign)]) {
      testWidgets('an unsupported $name link is refused in the app but opens in the browser', (tester) async {
        await pumpApp(tester);
        await enter(tester, url);
        await tapOpen(tester);
        expect(find.text(tr.openInAppPage.url.unsupportedUrl), findsOneWidget);
        expect(opened, isEmpty);
        expect(launched, isEmpty);

        await tapBrowser(tester);
        expect(launched, [url]);
        expect(find.byType(OpenInAppPage), findsOneWidget);
        expect(find.text(tr.openInAppPage.browserLaunchFailed), findsNothing);
      });
    }

    testWidgets('input is trimmed and a forum script link goes to the forum host', (tester) async {
      await pumpApp(tester);
      await enter(tester, '   $_report  ');
      await tapBrowser(tester);
      await enter(tester, 'home.php?mod=space&do=notice&view=manage&type=report#top');
      await tapBrowser(tester);
      expect(launched, [_report, 'https://www.tsdm39.com/home.php?mod=space&do=notice&view=manage&type=report#top']);
    });

    for (final input in [
      '',
      '   ',
      'javascript:alert(1)',
      'data:text/html,x',
      'tsdm://x',
      '1000',
      'Alice',
      'https://',
    ]) {
      testWidgets('"$input" is refused with a hint, nothing is launched', (tester) async {
        await pumpApp(tester);
        await enter(tester, input);
        await tapBrowser(tester);
        expect(launched, isEmpty);
        expect(find.text(tr.openInAppPage.invalidBrowserLink), findsOneWidget);
        expect(enabled(tester), isTrue);
      });
    }

    testWidgets('a launch answered false shows a failure and the button works again', (tester) async {
      await pumpApp(tester);
      answer = () async => false;
      await enter(tester, _report);
      await tapBrowser(tester);
      expect(launched, [_report]);
      expect(find.text(tr.openInAppPage.browserLaunchFailed), findsOneWidget);
      expect(enabled(tester), isTrue);

      answer = () async => true;
      await tapBrowser(tester);
      expect(launched, [_report, _report]);
    });

    testWidgets('browser refusal is recorded without copying the private URL into diagnostics', (tester) async {
      final historyStart = talker.history.length;
      await pumpApp(tester);
      answer = () async => false;
      await enter(tester, 'https://example.com/?secret=private-token#private-fragment');
      await tapBrowser(tester);
      final log = talker.history.skip(historyStart).map((entry) => entry.generateTextMessage()).join('\n');
      expect(log, contains('browser launch'));
      expect(log, contains('refused'));
      expect(log, isNot(contains('private-token')));
      expect(log, isNot(contains('private-fragment')));
      expect(find.text(tr.openInAppPage.browserLaunchFailed), findsOneWidget);
    });

    testWidgets('native browser failure reason reaches the exported log', (tester) async {
      final historyStart = talker.history.length;
      await pumpApp(tester);
      answer = () async => throw PlatformException(
        code: 'BROWSER_NOT_ALLOWED',
        message: 'Android refused the browser launch',
        details: {'sdk': 30, 'strategy': 'web-selector-v4'},
      );
      await enter(tester, _report);
      await tapBrowser(tester);
      final log = talker.history.skip(historyStart).map((entry) => entry.generateTextMessage()).join('\n');
      expect(log, contains('BROWSER_NOT_ALLOWED'));
      expect(log, contains('web-selector-v4'));
      expect(enabled(tester), isTrue);
      expect(find.text(tr.openInAppPage.browserLaunchFailed), findsOneWidget);
    });

    testWidgets('a launch that throws shows a failure and the button works again', (tester) async {
      await pumpApp(tester);
      answer = () async => throw PlatformException(code: 'ACTIVITY_NOT_FOUND', message: 'no browser');
      await enter(tester, _foreign);
      await tapBrowser(tester);
      expect(launched, [_foreign]);
      expect(find.text(tr.openInAppPage.browserLaunchFailed), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(enabled(tester), isTrue);

      answer = () async => true;
      await tapBrowser(tester);
      expect(launched, hasLength(2));
    });

    testWidgets('rapid taps while the browser starts launch once', (tester) async {
      await pumpApp(tester);
      final pending = Completer<Object?>();
      answer = () => pending.future;
      await enter(tester, _report);
      await tester.ensureVisible(_browser);
      // Deliver two activations before the rebuild disables the button.
      final press = tester.widget<OutlinedButton>(_browser).onPressed!;
      press();
      press();
      await tester.pump();
      await tester.tap(_browser, warnIfMissed: false);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
      expect(launched, [_report]);
      expect(enabled(tester), isFalse);

      pending.complete(true);
      await settle(tester);
      expect(enabled(tester), isTrue);
      expect(find.text(tr.openInAppPage.browserLaunchFailed), findsNothing);
      expect(launched, hasLength(1));
    });

    testWidgets('leaving the page while the browser starts is safe and reports nothing', (tester) async {
      await pumpApp(tester);
      final pending = Completer<Object?>();
      answer = () => pending.future;
      await enter(tester, _report);
      await tester.ensureVisible(_browser);
      await tester.tap(_browser);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
      expect(launched, hasLength(1));

      router.pop();
      await tester.pumpAndSettle();
      expect(find.byType(OpenInAppPage), findsNothing);
      pending.complete(false);
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.text(tr.openInAppPage.browserLaunchFailed), findsNothing);

      // A new page works from scratch.
      answer = () async => true;
      unawaited(router.pushNamed(ScreenPaths.openInApp));
      await tester.pumpAndSettle();
      await enter(tester, _foreign);
      await tapBrowser(tester);
      expect(launched, [_report, _foreign]);
    });
  });

  group('resources and edits', () {
    testWidgets('the browser button is only offered for links', (tester) async {
      await pumpApp(tester);
      expect(_browser, findsOneWidget);
      for (final name in [
        tr.openInAppPage.username.title,
        tr.openInAppPage.uid.title,
        tr.openInAppPage.fid.title,
        tr.openInAppPage.tid.title,
        tr.openInAppPage.pid.title,
      ]) {
        await tester.tap(find.widgetWithText(FilterChip, name));
        await tester.pump();
        expect(_browser, findsNothing, reason: name);
      }
      await tester.tap(find.widgetWithText(FilterChip, tr.openInAppPage.url.title));
      await tester.pump();
      expect(_browser, findsOneWidget);
    });

    testWidgets('a link recognized before a switch to uid does not leak into the uid route', (tester) async {
      await pumpApp(tester);
      await enter(tester, _supported);
      await tester.tap(find.widgetWithText(FilterChip, tr.openInAppPage.uid.title));
      await tester.pump();
      await tapOpen(tester);
      expect(opened, isEmpty, reason: 'a link is not a uid');
      expect(find.text(tr.openInAppPage.uid.invalidUid), findsOneWidget);

      await enter(tester, '42');
      await tapOpen(tester);
      expect(opened.values.single.$1, ScreenPaths.profile);
      expect(opened.values.single.$2, {'uid': '42'});
    });

    testWidgets('an edited link is the one opened, in the app and in the browser', (tester) async {
      await pumpApp(tester);
      await enter(tester, _supported);
      await enter(tester, _report);
      await tapOpen(tester);
      expect(opened, isEmpty, reason: 'the supported link was replaced by an unsupported one');
      await tapBrowser(tester);
      expect(launched, [_report]);

      await enter(tester, 'https://www.tsdm39.com/forum.php?mod=viewthread&tid=9');
      await tapOpen(tester);
      expect(opened.values.single.$2, containsPair('tid', '9'));
    });
  });

  group('deep link', () {
    testWidgets('a supported link opens in the app on its own, the browser is not started', (tester) async {
      await pumpApp(tester, initialUrl: _supported, autoOpen: true);
      await settle(tester);
      expect(opened.values.single.$1, ScreenPaths.threadV1);
      expect(opened.values.single.$2, containsPair('tid', '123'));
      expect(launched, isEmpty);
    });

    testWidgets('an unknown link stays on the page, is not launched on its own, and can be opened in the browser', (
      tester,
    ) async {
      await pumpApp(tester, initialUrl: _report, autoOpen: true);
      await settle(tester);
      await settle(tester);
      expect(find.byType(OpenInAppPage), findsOneWidget);
      expect(find.text(_report), findsOneWidget);
      expect(opened, isEmpty);
      expect(launched, isEmpty, reason: 'never launched without a tap');

      await tapBrowser(tester);
      expect(launched, [_report]);
      expect(find.byType(OpenInAppPage), findsOneWidget);
    });

    testWidgets('without autoOpen a supported link waits for the user', (tester) async {
      await pumpApp(tester, initialUrl: _supported);
      await settle(tester);
      expect(opened, isEmpty);
      expect(launched, isEmpty);
      expect(find.text(_supported), findsOneWidget);
    });
  });

  for (final (name, size) in [('phone', const Size(360, 640)), ('tablet', const Size(1024, 768))]) {
    testWidgets('$name layout: both buttons are reachable and work', (tester) async {
      await pumpApp(tester, size: size);
      await enter(tester, _report);
      await tapBrowser(tester);
      expect(launched, [_report]);
      await enter(tester, _supported);
      await tester.ensureVisible(find.text(tr.openInAppPage.open));
      await tapOpen(tester);
      expect(opened.values.single.$1, ScreenPaths.threadV1);
      expect(tester.takeException(), isNull);
    });
  }
}
