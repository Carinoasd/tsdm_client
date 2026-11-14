/// The in-app browser: which links it opens, what it does with the links followed in it, and the forum cookies it
/// gets.
///
/// Forum pages the app has no page for (the bank's loans, plugin pages) used to go to the "Open in app" page and from
/// there to the external browser, which is not signed in. Now they open in the in-app browser (`inAppBrowserForForum`,
/// on by default) with the session of the account in use; every web link can go there too (`inAppBrowserForAll`, off
/// by default). Platforms without the web view (Linux) keep the previous routes. The web view itself is not tested.
library;

import 'dart:io' as io;

import 'package:cookie_jar/cookie_jar.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/in_app_browser/utils/forum_cookies.dart';
import 'package:tsdm_client/features/in_app_browser/utils/link_routing.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

/// The channels a generic launch (url_launcher) may use.
const _launcherChannels = [
  MethodChannel('plugins.flutter.io/url_launcher'),
  MethodChannel('plugins.flutter.io/url_launcher_android'),
  MethodChannel('plugins.flutter.io/url_launcher_linux'),
];

/// A cookie jar storage in memory, counting writes.
final class _MemoryStorage implements Storage {
  final data = <String, String>{};
  int writes = 0;

  @override
  Future<void> init(bool persistSession, bool ignoreExpires) async {}

  @override
  Future<String?> read(String key) async => data[key];

  @override
  Future<void> write(String key, String value) async {
    writes++;
    data[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    writes++;
    data.remove(key);
  }

  @override
  Future<void> deleteAll(List<String> keys) async {
    writes++;
    keys.forEach(data.remove);
  }
}

void main() {
  group('linkTargetOf', () {
    LinkTarget target(
      String url, {
      bool forumPages = true,
      bool allLinks = false,
      bool supported = true,
      bool explicitBrowser = false,
    }) => linkTargetOf(
      Uri.parse(url),
      forumPages: forumPages,
      allLinks: allLinks,
      supported: supported,
      explicitBrowser: explicitBrowser,
    );

    const forumPage = 'https://www.tsdm39.com/plugin.php?id=bank:loan';

    test('forum pages go to the in-app browser by default, the other sites outside', () {
      expect(target(forumPage), LinkTarget.inAppBrowser);
      expect(target('http://tsdm39.com/home.php?mod=spacecp'), LinkTarget.inAppBrowser);
      expect(target('forum.php?mod=modcp&action=report'), LinkTarget.inAppBrowser, reason: 'relative: the forum');
      expect(target(forumPage, explicitBrowser: true), LinkTarget.inAppBrowser);
      expect(target('https://example.com/'), LinkTarget.external);
      expect(target('https://example.com/', explicitBrowser: true), LinkTarget.external);
    });

    test('hosts that only look like the forum are other sites', () {
      expect(target('https://www.tsdm39.com.evil.com/forum.php'), LinkTarget.external);
      expect(target('https://evil.com/?u=www.tsdm39.com'), LinkTarget.external);
      expect(target('https://www.tsdm39.com@evil.com/'), LinkTarget.external);
    });

    test('with the forum switch off, forum links go where they went before', () {
      expect(target(forumPage, forumPages: false), LinkTarget.openInAppPage);
      expect(target(forumPage, forumPages: false, explicitBrowser: true), LinkTarget.external);
    });

    test('all links: the other sites too, the forum pages even with the forum switch off', () {
      expect(target('https://example.com/', allLinks: true), LinkTarget.inAppBrowser);
      expect(target(forumPage, forumPages: false, allLinks: true), LinkTarget.inAppBrowser);
    });

    test('links of other apps never go to the in-app browser', () {
      for (final url in ['mailto:a@b.c', 'intent://x#Intent;end', 'weixin://dl/x', 'tel:123']) {
        expect(target(url, allLinks: true), LinkTarget.external, reason: url);
      }
    });

    test('without the web view (Linux) nothing changes', () {
      expect(target(forumPage, allLinks: true, supported: false), LinkTarget.openInAppPage);
      expect(target(forumPage, supported: false, explicitBrowser: true), LinkTarget.external);
      expect(target('https://example.com/', allLinks: true, supported: false), LinkTarget.external);
    });

    test('platforms with the web view', () {
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      for (final platform in TargetPlatform.values) {
        debugDefaultTargetPlatformOverride = platform;
        expect(
          inAppBrowserSupported,
          const {
            TargetPlatform.android,
            TargetPlatform.iOS,
            TargetPlatform.macOS,
            TargetPlatform.windows,
          }.contains(platform),
          reason: '$platform',
        );
      }
    });
  });

  group('browserNavigationOf', () {
    BrowserNavigation nav(String url, {bool mainFrame = true, bool initial = false}) =>
        browserNavigationOf(Uri.parse(url), mainFrame: mainFrame, initial: initial);

    test('a forum page the app has a page for opens in the app', () {
      final n = nav('https://www.tsdm39.com/forum.php?mod=viewthread&tid=123&page=2');
      expect(n, isA<BrowserNavigationOpenInApp>());
      final route = (n as BrowserNavigationOpenInApp).route;
      expect(route.screenPath, ScreenPaths.threadV1);
      expect(route.queryParameters, containsPair('tid', '123'));
      expect(nav('https://www.tsdm39.com/home.php?mod=space&uid=1000'), isA<BrowserNavigationOpenInApp>());
    });

    test('the page the browser was opened with, frames, other pages and other sites load here', () {
      const thread = 'https://www.tsdm39.com/forum.php?mod=viewthread&tid=123';
      expect(nav(thread, initial: true), isA<BrowserNavigationAllow>());
      expect(nav(thread, mainFrame: false), isA<BrowserNavigationAllow>());
      expect(nav('https://www.tsdm39.com/plugin.php?id=bank:loan'), isA<BrowserNavigationAllow>());
      expect(nav('https://example.com/forum.php?mod=viewthread&tid=123'), isA<BrowserNavigationAllow>());
      expect(nav('https://www.tsdm39.com.evil.com/forum.php?mod=viewthread&tid=1'), isA<BrowserNavigationAllow>());
      expect(nav('about:blank'), isA<BrowserNavigationAllow>());
    });

    test('links of other apps leave the web view, the initial one too', () {
      expect(nav('mailto:a@b.c'), isA<BrowserNavigationExternal>());
      expect(nav('intent://x#Intent;scheme=weixin;end', initial: true), isA<BrowserNavigationExternal>());
      expect(nav('weixin://dl/x', mainFrame: false), isA<BrowserNavigationExternal>());
    });
  });

  group('links of other apps followed in the in-app browser', () {
    test('mail, phone and app schemes go to their app', () {
      for (final url in ['mailto:a@b.c', 'tel:123', 'weixin://dl/x', 'market://details?id=x']) {
        final launch = externalLaunchOf(Uri.parse(url));
        expect(launch, isA<ExternalLaunchApp>(), reason: url);
        expect((launch as ExternalLaunchApp).uri, Uri.parse(url));
      }
    });

    test('an intent link loads its web fallback, or nothing', () {
      final launch = externalLaunchOf(
        Uri.parse(
          'intent://dl/x#Intent;scheme=weixin;package=com.x;'
          'S.browser_fallback_url=https%3A%2F%2Fexample.com%2Fdl%3Fa%3D1;end',
        ),
      );
      expect(launch, isA<ExternalLaunchFallback>());
      expect((launch as ExternalLaunchFallback).uri, Uri.parse('https://example.com/dl?a=1'));
      expect(externalLaunchOf(Uri.parse('intent://dl/x#Intent;scheme=weixin;end')), isA<ExternalLaunchNone>());
      expect(
        externalLaunchOf(Uri.parse('intent://x#Intent;S.browser_fallback_url=javascript%3Aalert(1);end')),
        isA<ExternalLaunchNone>(),
      );
    });

    test('local files are never opened', () {
      expect(externalLaunchOf(Uri.parse('file:///etc/hosts')), isA<ExternalLaunchNone>());
      expect(externalLaunchOf(Uri.parse('content://x/y')), isA<ExternalLaunchNone>());
    });

    test('only navigations by the user start other apps', () {
      expect(userStartedNavigation(hasGesture: true, linkActivated: false), isTrue);
      expect(userStartedNavigation(hasGesture: false, linkActivated: true), isFalse, reason: 'Android tells');
      expect(userStartedNavigation(hasGesture: null, linkActivated: true), isTrue, reason: 'iOS: a tapped link');
      expect(userStartedNavigation(hasGesture: null, linkActivated: false), isFalse, reason: 'unknown: not the user');
    });

    test('the browser page loads absolute web urls only', () {
      expect(isInAppBrowserUrl(Uri.parse('https://www.tsdm39.com/forum.php')), isTrue);
      expect(isInAppBrowserUrl(Uri.parse('http://example.com')), isTrue);
      for (final url in ['', 'forum.php?mod=x', 'javascript:alert(1)', 'file:///etc/hosts', 'https:']) {
        expect(isInAppBrowserUrl(Uri.parse(url)), isFalse, reason: url);
      }
      expect(isInAppBrowserUrl(null), isFalse);
    });
  });

  group('forumWebViewCookies', () {
    Future<_MemoryStorage> jarWith(Map<String, List<io.Cookie>> cookies) async {
      final storage = _MemoryStorage();
      final jar = PersistCookieJar(ignoreExpires: true, storage: storage);
      for (final MapEntry(:key, :value) in cookies.entries) {
        await jar.saveFromResponse(Uri.parse(key), value);
      }
      return storage;
    }

    test('the session of the forum hosts, host-only and domain cookies as stored, nothing of other sites', () async {
      final storage = await jarWith({
        // X5: host-only, http-only.
        'https://www.tsdm39.com/forum.php': [
          io.Cookie('s_2132_auth', 'a%2Fb')..httpOnly = true,
          io.Cookie('s_2132_saltkey', 'salt')..httpOnly = true,
          io.Cookie('s_2132_lastvisit', '1700000000')..httpOnly = false,
        ],
        'https://tsdm39.com/': [
          io.Cookie('s_2132_sid', 'sid')
            ..domain = '.tsdm39.com'
            ..httpOnly = false,
        ],
        'https://www.tsdm39.com.evil.com/': [io.Cookie('evil_host', '1')..httpOnly = false],
        'https://evil.com/': [
          io.Cookie('evil_domain', '1')
            ..domain = '.evil.com'
            ..httpOnly = false,
        ],
      });
      final writes = storage.writes;
      final before = Map.of(storage.data);

      final cookies = await forumWebViewCookies(storage);
      expect(storage.writes, writes, reason: 'reading for the web view does not change what the app holds');
      expect(storage.data, before);

      Map<String, WebViewCookie> of(String host) => {
        for (final c in cookies.where((c) => c.url.host == host)) c.name: c,
      };
      final www = of('www.tsdm39.com');
      expect(www.keys, unorderedEquals(['s_2132_auth', 's_2132_saltkey', 's_2132_lastvisit', 's_2132_sid']));
      expect(www['s_2132_auth']!.value, 'a%2Fb');
      expect(www['s_2132_auth']!.domain, isNull, reason: 'host-only stays host-only');
      expect(www['s_2132_auth']!.httpOnly, isTrue);
      expect(www['s_2132_auth']!.path, '/');
      expect(www['s_2132_auth']!.url, Uri.parse('https://www.tsdm39.com/'));
      expect(www['s_2132_lastvisit']!.httpOnly, isFalse);
      expect(www['s_2132_sid']!.domain, '.tsdm39.com');

      expect(of('tsdm39.com').keys, ['s_2132_sid'], reason: 'the host-only cookies of www are not sent there');
      expect(cookies.map((c) => c.url.host).toSet(), {'www.tsdm39.com', 'tsdm39.com'});
      expect(cookies.map((c) => c.name), isNot(contains(startsWith('evil'))));
    });

    test('no session, no cookies', () async {
      expect(await forumWebViewCookies(_MemoryStorage()), isEmpty);
    });

    test('the stale cookies removed first cover host-only and domain ones of both hosts', () {
      expect(forumHosts, ['www.tsdm39.com', 'tsdm39.com']);
      expect(forumCookieDomains, containsAll(<String?>[null, '.tsdm39.com']));
    });
  });

  group('settings', () {
    test('forum pages in the in-app browser by default, other sites not', () {
      expect(SettingsKeys.inAppBrowserForForum.defaultValue, isTrue);
      expect(SettingsKeys.inAppBrowserForAll.defaultValue, isFalse);
    });

    test('every language has the switches and the page actions', () async {
      for (final locale in AppLocale.values) {
        final t = await locale.build();
        final s = t.settingsPage.othersSection;
        final p = t.inAppBrowserPage;
        for (final text in [s.inAppBrowserForForum, s.inAppBrowserForAll, p.back, p.forward, p.refresh]) {
          expect(text, isNotEmpty, reason: '$locale');
        }
        expect([p.openExternal, p.copyUrl], everyElement(isNotEmpty), reason: '$locale');
      }
    });
  });

  group('dispatchAsUrl', () {
    late AppDatabase db;
    late SettingsRepository settings;
    late GoRouter router;
    final launched = <String>[];

    /// Pages pushed: path and query parameters.
    final pushed = <(String, Map<String, String>)>[];

    setUpAll(() {
      talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    });

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      final storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      getIt
        ..registerSingleton<StorageProvider>(storage)
        ..registerSingleton<SettingsRepository>(settings);
      await settings.init();
      launched.clear();
      pushed.clear();
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      for (final channel in _launcherChannels) {
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'launch' || call.method == 'openUrl') {
            launched.add('${(call.arguments as Map<Object?, Object?>)['url']}');
          }
          return true;
        });
      }
    });

    tearDown(() async {
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      for (final channel in _launcherChannels) {
        messenger.setMockMethodCallHandler(channel, null);
      }
      debugDefaultTargetPlatformOverride = null;
      await getIt.reset();
      await settings.dispose();
      await db.close();
    });

    Future<void> open(WidgetTester tester, String url, {bool external = false}) async {
      GoRoute page(String path) => GoRoute(
        path: path,
        name: path,
        builder: (context, state) {
          pushed.add((path, state.uri.queryParameters));
          return Scaffold(body: Text('page $path'));
        },
      );
      router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (context, state) => Scaffold(
              body: TextButton(
                onPressed: () async => context.dispatchAsUrl(url, external: external),
                child: const Text('open'),
              ),
            ),
          ),
          page(ScreenPaths.inAppBrowser),
          page(ScreenPaths.openInApp),
          page(ScreenPaths.threadV1),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    const loan = 'https://www.tsdm39.com/plugin.php?id=bank:loan&op=repay';

    /// One page was pushed: [path] with [query].
    void expectPushed(String path, Map<String, String> query) {
      expect(pushed, hasLength(1));
      expect(pushed.single.$1, path);
      expect(pushed.single.$2, query);
    }

    testWidgets('an unsupported forum page opens in the in-app browser', (tester) async {
      await open(tester, loan);
      expectPushed(ScreenPaths.inAppBrowser, {'url': loan});
      expect(launched, isEmpty);
    });

    testWidgets('a relative one on the forum host, query and fragment kept', (tester) async {
      await open(tester, 'forum.php?mod=modcp&action=report&extra=page%3D1#reports');
      expectPushed(ScreenPaths.inAppBrowser, {
        'url': 'https://www.tsdm39.com/forum.php?mod=modcp&action=report&extra=page%3D1#reports',
      });
    });

    testWidgets('"open in browser" of a forum page too', (tester) async {
      const thread = 'https://www.tsdm39.com/forum.php?mod=viewthread&tid=123';
      await open(tester, thread, external: true);
      expectPushed(ScreenPaths.inAppBrowser, {'url': thread});
      expect(launched, isEmpty);
    });

    testWidgets('a page the app has still opens in the app', (tester) async {
      await open(tester, 'https://www.tsdm39.com/forum.php?mod=viewthread&tid=123');
      expect(pushed.single.$1, ScreenPaths.threadV1);
    });

    testWidgets('other sites go to the external browser', (tester) async {
      await open(tester, 'https://example.com/a');
      expect(pushed, isEmpty);
      expect(launched, ['https://example.com/a']);
    });

    testWidgets('all links: other sites in the in-app browser', (tester) async {
      await settings.setValue(SettingsKeys.inAppBrowserForAll, true);
      await open(tester, 'https://example.com/a');
      expectPushed(ScreenPaths.inAppBrowser, {'url': 'https://example.com/a'});
      expect(launched, isEmpty);
    });

    testWidgets('mail links never go to the in-app browser', (tester) async {
      await settings.setValue(SettingsKeys.inAppBrowserForAll, true);
      await open(tester, 'mailto:a@b.c', external: true);
      expect(pushed, isEmpty);
      expect(launched, ['mailto:a@b.c']);
    });

    testWidgets('links of other apps are classed external, but only the allowed schemes are launched', (tester) async {
      // `intent:` and app schemes (`weixin://`) were launched as they came; now only web pages, mail and the schemes
      // the forum takes in `[url]` (downloads, calls) go to another app.
      for (final url in ['intent://x#Intent;end', 'weixin://dl/x', 'tel:123', 'magnet:?xt=urn:btih:0123']) {
        await open(tester, url);
      }
      expect(pushed, isEmpty);
      expect(launched, ['tel:123', 'magnet:?xt=urn:btih:0123']);
    });

    testWidgets('local files, scripts and the handlers of the system are never launched', (tester) async {
      for (final url in [
        'file:///C:/Windows/System32/notepad.exe',
        'FILE:///etc/hosts',
        'File://server/share/a.exe',
        'intent://x#Intent;scheme=weixin;end',
        'javascript:alert(1)',
        'JavaScript:alert(1)',
        'vbscript:msgbox(1)',
        'data:text/html,x',
        'content://x/y',
        'smb://server/share',
        'ms-msdt:/id',
        'ms-settings:privacy',
        'search-ms:query=x',
        'about:blank',
        ' file:///etc/hosts',
        'file:///etc/hosts ',
        '\tfile:///etc/hosts',
        '\u0000file:///etc/hosts',
        'fi\tle:///etc/hosts',
        'java\nscript:alert(1)',
      ]) {
        await open(tester, url);
        await open(tester, url, external: true);
      }
      expect(launched, isEmpty);
    });

    testWidgets('web pages, mail and downloads still launch', (tester) async {
      for (final url in [
        'https://example.com/a',
        'mailto:a@b.c',
        'magnet:?xt=urn:btih:0123',
        'ftp://example.com/a.zip',
      ]) {
        await open(tester, url, external: true);
      }
      expect(launched, [
        'https://example.com/a',
        'mailto:a@b.c',
        'magnet:?xt=urn:btih:0123',
        'ftp://example.com/a.zip',
      ]);
    });

    testWidgets('forum switch off: the "Open in app" page, "open in browser" the external browser', (tester) async {
      await settings.setValue(SettingsKeys.inAppBrowserForForum, false);
      await open(tester, loan);
      expectPushed(ScreenPaths.openInApp, {'url': loan, 'autoOpen': 'false'});
      pushed.clear();
      await open(tester, loan, external: true);
      expect(pushed, isEmpty);
      expect(launched, [loan]);
    });

    testWidgets('Linux: as before', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      await settings.setValue(SettingsKeys.inAppBrowserForAll, true);
      await open(tester, loan);
      expect(pushed.single.$1, ScreenPaths.openInApp);
      debugDefaultTargetPlatformOverride = null;
    });
  });
}
