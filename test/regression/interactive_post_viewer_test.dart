import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/thread/v1/utils/interactive_post_viewer.dart';
import 'package:tsdm_client/features/thread/v1/widgets/interactive_post_entry.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/shared/models/models.dart';

const _viewer = MethodChannel('kzs.th000.tsdm_client/interactiveHtmlChannel');
const _browser = MethodChannel('kzs.th000.tsdm_client/mainChannel');
const _launcher = MethodChannel('plugins.flutter.io/url_launcher');
const _html =
    '<style>.tool{display:grid}</style><svg viewBox="0 0 20 20"></svg>\n'
    '<button onclick="this.textContent=\'done\'">Start</button>';

class _Authentication extends AuthenticationRepository {
  UserLoginInfo? reader;

  @override
  UserLoginInfo? get currentUser => reader;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final viewerCalls = <MethodCall>[];
  final browserCalls = <MethodCall>[];
  final launcherCalls = <MethodCall>[];
  late Future<Object?> Function() nativeReply;
  late Future<Object?> Function() browserReply;

  setUpAll(() async => LocaleSettings.setLocale(AppLocale.en));
  setUp(() {
    viewerCalls.clear();
    browserCalls.clear();
    launcherCalls.clear();
    nativeReply = () async => true;
    browserReply = () async => true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      ..setMockMethodCallHandler(_viewer, (call) async {
        viewerCalls.add(call);
        return nativeReply();
      })
      ..setMockMethodCallHandler(_browser, (call) async {
        browserCalls.add(call);
        return browserReply();
      })
      ..setMockMethodCallHandler(_launcher, (call) async {
        launcherCalls.add(call);
        return browserReply();
      });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      ..setMockMethodCallHandler(_viewer, null)
      ..setMockMethodCallHandler(_browser, null)
      ..setMockMethodCallHandler(_launcher, null);
  });

  test('native payload contains authored HTML, canonical post source and reader scope only', () async {
    final result = await openInteractivePost(html: _html, postId: '998877', currentUid: 1234);
    expect(result, InteractivePostOpenResult.viewer);
    expect(viewerCalls, hasLength(1));
    expect(viewerCalls.single.method, 'openHtml');
    expect(viewerCalls.single.arguments, {
      'html': _html,
      'sourceUrl': '$baseUrl/forum.php?mod=redirect&goto=findpost&pid=998877',
      'accountScope': '1234',
      'postId': '998877',
    });
    expect(browserCalls, isEmpty);
    expect(launcherCalls, isEmpty);
  });

  test('each active reader and guest uses a separate account scope', () async {
    for (final uid in <int?>[111, 222, null, 0, -1]) {
      await openInteractivePost(html: _html, postId: '998877', currentUid: uid);
    }
    expect(
      viewerCalls.map((call) => (call.arguments as Map<Object?, Object?>)['accountScope']),
      ['111', '222', 'guest', 'guest', 'guest'],
    );
  });

  for (final failure in ['false', 'platform', 'missing']) {
    test('native $failure falls back to Android browser-only original-post link', () async {
      nativeReply = () async => switch (failure) {
        'platform' => throw PlatformException(code: 'unavailable'),
        'missing' => throw MissingPluginException(),
        _ => false,
      };
      final result = await openInteractivePost(html: _html, postId: '998877', currentUid: 1234);
      expect(result, InteractivePostOpenResult.browser);
      expect(browserCalls.single.method, 'openInBrowser');
      expect(browserCalls.single.arguments, {
        'url': '$baseUrl/forum.php?mod=redirect&goto=findpost&pid=998877',
      });
      expect(launcherCalls, isEmpty, reason: 'A generic Android launch could loop back into the app.');
    });
  }

  test('non-Android uses the external browser without passing HTML or account data', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final result = await openInteractivePost(html: _html, postId: '998877', currentUid: 1234);
    expect(result, InteractivePostOpenResult.browser);
    expect(viewerCalls, isEmpty);
    expect(browserCalls, isEmpty);
    expect(launcherCalls, hasLength(1));
    final arguments = launcherCalls.single.arguments as Map<Object?, Object?>;
    expect(arguments['url'], '$baseUrl/forum.php?mod=redirect&goto=findpost&pid=998877');
    expect(arguments['useWebView'], isFalse);
    expect(arguments.containsKey('html'), isFalse);
    expect(arguments.containsKey('accountScope'), isFalse);
  });

  test('256 KiB limit measures UTF-8 bytes and never sends oversized HTML to native', () async {
    final exact = 'a' * interactivePostMaxBytes;
    await openInteractivePost(html: exact, postId: '998877', currentUid: null);
    expect(viewerCalls, hasLength(1));
    expect(browserCalls, isEmpty);
    viewerCalls.clear();
    final wide = '界' * (interactivePostMaxBytes ~/ 3 + 1);
    expect(wide.length, lessThan(interactivePostMaxBytes));
    expect(utf8.encode(wide).length, greaterThan(interactivePostMaxBytes));
    expect(
      await openInteractivePost(html: wide, postId: '998877', currentUid: null),
      InteractivePostOpenResult.browser,
    );
    expect(viewerCalls, isEmpty);
    expect(browserCalls, hasLength(1));
  });

  test('invalid post identity never reaches a platform or arbitrary URL', () async {
    for (final postId in ['', '0', '../secret', '1&formhash=secret', 'https://example.com']) {
      expect(
        await openInteractivePost(html: _html, postId: postId, currentUid: null),
        InteractivePostOpenResult.failed,
      );
    }
    expect(viewerCalls, isEmpty);
    expect(browserCalls, isEmpty);
    expect(launcherCalls, isEmpty);
  });

  test('browser failure is reported without throwing or attempting other launches', () async {
    nativeReply = () async => false;
    browserReply = () async => throw PlatformException(code: 'no_browser');
    expect(
      await openInteractivePost(html: _html, postId: '998877', currentUid: null),
      InteractivePostOpenResult.failed,
    );
    expect(browserCalls, hasLength(1));
    expect(launcherCalls, isEmpty);
  });

  Future<void> pumpEntry(WidgetTester tester, {required String html, _Authentication? auth}) async {
    final entry = TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: InteractivePostEntry(data: html, postId: '998877'),
          ),
        ),
      ),
    );
    await tester.pumpWidget(
      auth == null ? entry : RepositoryProvider<AuthenticationRepository>.value(value: auth, child: entry),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('ordinary post shows no action and interactive post does nothing until tapped', (tester) async {
    final tr = LocaleSettings.instance.currentTranslations.postCard.interactiveHtml;
    await pumpEntry(tester, html: '<p>A normal post with <strong>formatted text</strong>.</p>');
    expect(find.text(tr.open), findsNothing);
    expect(viewerCalls, isEmpty);
    await pumpEntry(tester, html: _html);
    expect(find.text(tr.open), findsOneWidget);
    expect(find.text(tr.description), findsOneWidget);
    expect(viewerCalls, isEmpty);
    await tester.tap(find.text(tr.open));
    await tester.pumpAndSettle();
    expect(viewerCalls, hasLength(1));
    expect((viewerCalls.single.arguments as Map<Object?, Object?>)['accountScope'], 'guest');
  });

  testWidgets('entry reads current login at tap time and never captures a former account', (tester) async {
    final auth = _Authentication()..reader = const UserLoginInfo(username: 'Alice', uid: 111);
    addTearDown(auth.dispose);
    final action = find.text(LocaleSettings.instance.currentTranslations.postCard.interactiveHtml.open);
    await pumpEntry(tester, html: _html, auth: auth);
    auth.reader = const UserLoginInfo(username: 'Bob', uid: 222);
    await tester.tap(action);
    await tester.pumpAndSettle();
    auth.reader = null;
    await tester.tap(action);
    await tester.pumpAndSettle();
    expect(
      viewerCalls.map((call) => (call.arguments as Map<Object?, Object?>)['accountScope']),
      ['222', 'guest'],
    );
  });

  testWidgets('entry disables duplicate taps while native open is pending', (tester) async {
    final pending = Completer<Object?>();
    nativeReply = () => pending.future;
    final action = find.text(LocaleSettings.instance.currentTranslations.postCard.interactiveHtml.open);
    await pumpEntry(tester, html: _html);
    await tester.tap(action);
    await tester.pump();
    await tester.tap(action);
    await tester.pump();
    expect(viewerCalls, hasLength(1));
    pending.complete(true);
    await tester.pumpAndSettle();
  });

  testWidgets('failed viewer uses browser fallback and explains its destination', (tester) async {
    final tr = LocaleSettings.instance.currentTranslations.postCard.interactiveHtml;
    nativeReply = () async => false;
    await pumpEntry(tester, html: _html);
    await tester.tap(find.text(tr.open));
    await tester.pumpAndSettle();
    expect(find.text(tr.browserFallback), findsOneWidget);
    expect(browserCalls, hasLength(1));
  });

  testWidgets('interactive entry fits a narrow page at large text scale', (tester) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(320, 700);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: const Scaffold(
            body: SingleChildScrollView(
              child: InteractivePostEntry(data: _html, postId: '998877'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(viewerCalls, isEmpty);
  });
}
