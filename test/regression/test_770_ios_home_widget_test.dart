/// The iOS home screen widget (a WidgetKit extension, `ios/TsdmWidget`) shows what the Android one does: the app
/// tells the state over the same `HomeWidgetChannel`, the native `HomeWidgetBridge` stores it in the App Group the
/// extension reads, and the widget's taps open `tsdm://shortcut/<id>` links the app hands to Dart over the shortcuts
/// channel.
///
/// 1. the widget is on Android and iOS: the channel and the sync are on there, nowhere else;
/// 2. the shortcut links parse to their shortcut (the id alone still does, for Android), anything else to nothing;
/// 3. the shortcuts channel takes a link both at a cold start and while the app runs;
/// 4. the state the app writes for the widget: the whole state in one call, a logout as "no account";
/// 5. the native sides agree with Dart: channel and method names, argument keys, links, the App Group of both
///    targets, and the extension's bundle id under the app's.
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/home_widget/repository/home_widget_channel.dart';
import 'package:tsdm_client/features/shortcuts/models/app_shortcut.dart';
import 'package:tsdm_client/features/shortcuts/repository/app_shortcuts_channel.dart';
import 'package:tsdm_client/instance.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  group('platforms', () {
    test('Android and iOS have the widget, the others not', () {
      expect(HomeWidgetChannel.hasWidget(android: true, ios: false), isTrue);
      expect(HomeWidgetChannel.hasWidget(android: false, ios: true), isTrue);
      expect(HomeWidgetChannel.hasWidget(android: false, ios: false), isFalse);
      // The tests run on neither.
      expect(HomeWidgetChannel.platformHasWidget, isFalse);
      expect(const HomeWidgetChannel().enabled, isFalse);
    });
  });

  group('links', () {
    test('every shortcut has a link that parses back to it', () {
      for (final shortcut in AppShortcut.values) {
        expect(shortcut.link, 'tsdm://shortcut/${shortcut.id}');
        expect(AppShortcut.fromLink(shortcut.link), shortcut);
        expect(AppShortcut.fromIdOrLink(shortcut.link), shortcut);
        expect(AppShortcut.fromIdOrLink(shortcut.id), shortcut);
      }
    });

    test('a link written otherwise still counts', () {
      expect(AppShortcut.fromLink('TSDM://Shortcut/checkin'), AppShortcut.checkin);
      expect(AppShortcut.fromLink('tsdm://shortcut/notice/'), AppShortcut.notice);
      expect(AppShortcut.fromLink('tsdm://shortcut/notice?from=widget'), AppShortcut.notice);
    });

    test('anything else is no shortcut', () {
      for (final link in [
        null,
        '',
        'checkin',
        'https://shortcut/checkin',
        'tsdm://forum/checkin',
        'tsdm://shortcut',
        'tsdm://shortcut/',
        'tsdm://shortcut/unknown',
        'tsdm://shortcut/checkin/again',
        'tsdm://shortcut/CHECKIN',
        '::not a link::',
      ]) {
        expect(AppShortcut.fromLink(link), isNull, reason: '$link');
      }
      expect(AppShortcut.fromIdOrLink('tsdm://shortcut/unknown'), isNull);
      expect(AppShortcut.fromIdOrLink('unknown'), isNull);
    });
  });

  group('shortcuts channel', () {
    const channel = MethodChannel(AppShortcutsChannel.name);
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('the link of a cold start', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, AppShortcutsChannel.getInitialShortcut);
        return AppShortcut.checkin.link;
      });
      expect(await const AppShortcutsChannel().initial(), AppShortcut.checkin);
    });

    test('a link opened while the app runs, an unknown one dropped', () async {
      const shortcuts = AppShortcutsChannel();
      final tapped = <AppShortcut>[];
      shortcuts.listen(tapped.add);
      addTearDown(shortcuts.dispose);
      const codec = StandardMethodCodec();
      for (final link in [AppShortcut.notice.link, 'tsdm://shortcut/unknown', AppShortcut.checkin.link]) {
        await messenger.handlePlatformMessage(
          AppShortcutsChannel.name,
          codec.encodeMethodCall(MethodCall(AppShortcutsChannel.onShortcut, link)),
          (_) {},
        );
      }
      expect(tapped, [AppShortcut.notice, AppShortcut.checkin]);
    });
  });

  group('state written for the widget', () {
    const channel = MethodChannel(HomeWidgetChannel.name);
    late List<MethodCall> calls;
    setUp(() {
      calls = [];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return true;
      });
    });
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('the whole state in one call, a logout as no account', () async {
      const widget = HomeWidgetChannel(enabled: true);
      await widget.update(uid: 31, notice: 120, personalMessage: 0, checkedInDay: '2026-11-09');
      await widget.update(uid: 31, notice: null, personalMessage: null, checkedInDay: null);
      await widget.clear();
      expect(calls.map((e) => e.method), everyElement(HomeWidgetChannel.updateMethod));
      expect(calls.map((e) => e.arguments), [
        {'uid': 31, 'notice': 120, 'personalMessage': 0, 'checkedInDay': '2026-11-09'},
        {'uid': 31, 'notice': null, 'personalMessage': null, 'checkedInDay': null},
        {'uid': null, 'notice': 0, 'personalMessage': 0, 'checkedInDay': null},
      ]);
    });
  });

  group('native sides', () {
    String read(String path) => File(path).readAsStringSync();

    test('the bridge speaks the channels of Dart', () {
      final bridge = read('ios/Runner/HomeWidgetBridge.swift');
      for (final value in [
        HomeWidgetChannel.name,
        HomeWidgetChannel.updateMethod,
        AppShortcutsChannel.name,
        AppShortcutsChannel.getInitialShortcut,
        AppShortcutsChannel.onShortcut,
        AppShortcut.linkScheme,
      ]) {
        expect(bridge, contains('"$value"'));
      }
      for (final key in ['uid', 'notice', 'personalMessage', 'checkedInDay']) {
        expect(bridge, contains('args["$key"]'));
      }
      expect(read('ios/Runner/AppDelegate.swift'), contains('HomeWidgetBridge.register(with:'));
    });

    test('the widget opens the links of Dart', () {
      final widget = read('ios/TsdmWidget/TsdmWidget.swift');
      expect(widget, contains('"${AppShortcut.checkin.link}"'));
      expect(widget, contains('"${AppShortcut.notice.link}"'));
      final info = read('ios/Runner/Info.plist');
      expect(info, contains('<string>${AppShortcut.linkScheme}</string>'));
    });

    test('both targets share one App Group, the extension sits under the app', () {
      final group = RegExp('appGroup = "([^"]+)"').firstMatch(read('ios/TsdmWidget/HomeWidgetState.swift'))!.group(1)!;
      for (final path in ['ios/Runner/Runner.entitlements', 'ios/TsdmWidget/TsdmWidget.entitlements']) {
        expect(read(path), contains('<string>$group</string>'), reason: path);
      }
      final project = read('ios/Runner.xcodeproj/project.pbxproj');
      final ids = RegExp('PRODUCT_BUNDLE_IDENTIFIER = ([^;]+);').allMatches(project).map((e) => e.group(1)!).toSet();
      const app = 'com.tsdm.tsdmClient';
      expect(ids, containsAll([app, '$app.widget']));
      expect(group, 'group.$app');
      expect(RegExp(r'CODE_SIGN_ENTITLEMENTS = Runner/Runner\.entitlements;').allMatches(project), hasLength(3));
      expect(
        RegExp(r'CODE_SIGN_ENTITLEMENTS = TsdmWidget/TsdmWidget\.entitlements;').allMatches(project),
        hasLength(3),
      );
    });
  });
}
