// The forum link just copied, offered when the app comes to the front (a switch, off by default): the clipboard is
// never read while it is off, read once each time the app is shown again (on desktop also when the window gets the
// focus back), never under the app lock; the same link is offered once, a link copied in the app never. And the
// share text of a thread ("copy share text") is a token the app finds the link in.
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/app_lock/cubit/app_lock_cubit.dart';
import 'package:tsdm_client/features/app_lock/models/app_lock_config.dart';
import 'package:tsdm_client/features/app_lock/repository/app_lock_store.dart';
import 'package:tsdm_client/features/app_lock/repository/biometric_authenticator.dart';
import 'package:tsdm_client/features/app_lock/repository/pin_hasher.dart';
import 'package:tsdm_client/features/diagnostics/diagnostics_bundle.dart';
import 'package:tsdm_client/features/open_in_app/clipboard_link_prompt.dart';
import 'package:tsdm_client/features/open_in_app/utils/forum_link_in_text.dart';
import 'package:tsdm_client/features/open_in_app/utils/share_text.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/sync/models/sync_settings.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/clipboard.dart';

const _token = '【天使动漫】某某标题 https://www.tsdm39.com/forum.php?mod=viewthread&tid=123 点击链接直接打开';
const _url = 'https://www.tsdm39.com/forum.php?mod=viewthread&tid=123';
const _other = 'https://www.tsdm39.com/forum.php?mod=forumdisplay&fid=8';

final class _NoBiometrics implements BiometricAuthenticator {
  @override
  Future<bool> authenticate(String reason) async => false;

  @override
  Future<bool> isAvailable() async => false;
}

/// A prompter on a clipboard holding [clipboard], counting the reads and recording the links offered.
final class _Harness {
  bool enabled = true;
  String? clipboard = _token;
  Exception? readError;
  int reads = 0;
  String? prompted;
  bool shown = true;
  final offered = <ForumLinkInText>[];

  late final prompter = ClipboardLinkPrompter(
    enabled: () => enabled,
    readClipboard: () async {
      reads += 1;
      if (readError != null) {
        throw readError!;
      }
      return clipboard;
    },
    loadPrompted: () async => prompted,
    savePrompted: (url) async => prompted = url,
    prompt: (link) async {
      if (!shown) {
        return false;
      }
      offered.add(link);
      return true;
    },
  );
}

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  group('the prompter', () {
    test('off: the clipboard is never read', () async {
      final h = _Harness()..enabled = false;
      await h.prompter.check();
      expect(h.reads, 0);
      expect(h.offered, isEmpty);
      expect(h.prompted, isNull);
      // A link copied in the app is remembered (nothing is read): switched on later, it is not offered.
      await h.prompter.remember(_token);
      expect(h.reads, 0);
      expect(h.prompted, _url);
      h.enabled = true;
      await h.prompter.check();
      expect(h.offered, isEmpty);
    });

    test('a token copied is offered once; another link is offered again', () async {
      final h = _Harness();
      await h.prompter.check();
      expect(h.offered.map((e) => e.url), [_url]);
      expect(h.offered.single.isThread, isTrue);
      expect(h.prompted, _url, reason: 'remembered when offered, opened or not');

      await h.prompter.check();
      expect(h.reads, 2);
      expect(h.offered, hasLength(1));

      h.clipboard = 'see $_other';
      await h.prompter.check();
      expect(h.offered.map((e) => e.url), [_url, _other]);
      expect(h.offered.last.isThread, isFalse);
    });

    test('nothing to offer: no forum link, a link of another site, nothing, a refused read', () async {
      final h = _Harness();
      for (final text in ['动画 推荐', 'https://example.com/forum.php?mod=viewthread&tid=1', '', null]) {
        h.clipboard = text;
        await h.prompter.check();
      }
      h
        ..clipboard = _token
        ..readError = PlatformException(code: 'denied');
      await h.prompter.check();
      expect(h.offered, isEmpty);
      expect(h.prompted, isNull);
    });

    test('a link that could not be shown is offered the next time', () async {
      final h = _Harness()..shown = false;
      await h.prompter.check();
      expect(h.prompted, isNull);
      h.shown = true;
      await h.prompter.check();
      expect(h.offered.map((e) => e.url), [_url]);
    });

    test('a link copied in the app is not offered', () async {
      final h = _Harness();
      await h.prompter.remember('【天使动漫】某某标题 $_url');
      await h.prompter.check();
      expect(h.offered, isEmpty);
    });
  });

  group('the watcher', () {
    late _Harness h;

    setUp(() => h = _Harness());

    Future<void> pumpWatcher(WidgetTester tester, {AppLockCubit? lock, bool checkOnFocus = false}) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(
        ClipboardLinkWatcher(prompter: h.prompter, lock: lock, checkOnFocus: checkOnFocus),
      );
      await tester.pump();
      await tester.pump();
    }

    Future<void> go(WidgetTester tester, List<AppLifecycleState> states) async {
      states.forEach(tester.binding.handleAppLifecycleStateChanged);
      await tester.pump();
      await tester.pump();
    }

    const away = [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused];
    const back = [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed];
    const blur = [AppLifecycleState.inactive, AppLifecycleState.resumed];

    testWidgets('a cold start reads once; a phone reads again only when the app is shown again', (tester) async {
      await pumpWatcher(tester);
      expect(h.reads, 1);
      expect(h.offered, hasLength(1));

      // The notification shade, a system sheet: inactive and back, not hidden.
      await go(tester, blur);
      await go(tester, blur);
      expect(h.reads, 1);

      await go(tester, away);
      await go(tester, back);
      expect(h.reads, 2);
      expect(h.offered, hasLength(1), reason: 'the same link once');
    });

    testWidgets('desktop: also when the window gets the focus back', (tester) async {
      await pumpWatcher(tester, checkOnFocus: true);
      await go(tester, blur);
      expect(h.reads, 2);
    });

    testWidgets('off: never read, at a start or coming back', (tester) async {
      h.enabled = false;
      await pumpWatcher(tester);
      await go(tester, away);
      await go(tester, back);
      expect(h.reads, 0);
      // Switched on while away: the next return reads.
      h.enabled = true;
      await go(tester, away);
      await go(tester, back);
      expect(h.reads, 1);
    });

    testWidgets('under the app lock nothing is read; once unlocked the link is offered', (tester) async {
      const hasher = PinHasher(iterations: 10);
      final pin = await tester.runAsync(() => hasher.hash('1234'));
      final lock = AppLockCubit(
        config: AppLockConfig(method: AppLockMethod.pin, pin: pin),
        store: AppLockStore.memory(),
        biometrics: _NoBiometrics(),
        hasher: hasher,
      );
      addTearDown(lock.close);
      expect(lock.state.covering, isTrue);
      await pumpWatcher(tester, lock: lock);
      expect(h.reads, 0);

      await tester.runAsync(() => lock.unlockWithPin('1234'));
      await tester.pump();
      await tester.pump();
      expect(lock.state.covering, isFalse);
      expect(h.reads, 1);
      expect(h.offered, hasLength(1));
    });
  });

  group('in the app', () {
    late AppDatabase db;
    late StorageProvider storage;
    late SettingsRepository settings;

    setUp(() async {
      await LocaleSettings.setLocale(AppLocale.zhCn);
      db = AppDatabase(NativeDatabase.memory());
      storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      getIt
        ..allowReassignment = true
        ..registerSingleton<StorageProvider>(storage)
        ..registerSingleton<SettingsRepository>(settings);
      await settings.init();
    });

    tearDown(() async {
      await settings.dispose();
      await db.close();
      await getIt.reset();
      getIt.allowReassignment = false;
    });

    test('the switch is off by default, on this device only, told in a diagnostics bundle', () {
      expect(SettingsKeys.clipboardLinkPrompt.defaultValue, isFalse);
      expect(settings.currentSettings.clipboardLinkPrompt, isFalse);
      expect({for (final s in syncedSettings) s.key.name}, isNot(contains('clipboardLinkPrompt')));
      expect({for (final s in syncedSettings) s.key.name}, isNot(contains(clipboardLinkPromptedKey)));
      expect(diagnosticSettingNames, contains('clipboardLinkPrompt'));
      expect(diagnosticSettingNames, isNot(contains(clipboardLinkPromptedKey)));
    });

    testWidgets('"copy link" and "copy share text" are remembered, the switch on or off', (tester) async {
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      late BuildContext context;
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Builder(
              builder: (c) {
                context = c;
                return const SizedBox();
              },
            ),
          ),
        ),
      );

      final share = threadShareText(context, title: ' 某某标题 ', url: _url);
      expect(share, '【天使动漫】某某标题 $_url');
      expect(findForumLinkInText(share)!.url, _url);

      await tester.runAsync(() => copyToClipboard(context, share, showSnackBar: false));
      expect(copied, [share]);
      expect(await tester.runAsync(() => storage.getString(clipboardLinkPromptedKey)), _url, reason: 'switch off');

      await tester.runAsync(() => settings.setValue(SettingsKeys.clipboardLinkPrompt, true));
      await tester.runAsync(() => copyToClipboard(context, _other, showSnackBar: false));
      expect(await tester.runAsync(() => storage.getString(clipboardLinkPromptedKey)), _other);
    });
  });
}
