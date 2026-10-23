/// What runs before the first frame (cold start, UX audit item 5).
///
/// 1. the background message service is brought in line with the settings after `runApp`: starting it polled the
///    plugin every 200 ms until it ran, before the first frame; the request is still queued at once, so a change on
///    the settings page queues behind it;
/// 2. the legacy notification channel goes in the background; the notification that launched the app is still read
///    before the home page asks for it;
/// 3. no image cache row is read, and the clean up of the cache waits long after the first frame (test_241, test_242).
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/background_sync/background_sync_controller.dart';
import 'package:tsdm_client/instance.dart';

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  final main = File('lib/main.dart').readAsStringSync();
  final boot = main.substring(main.indexOf('Future<void> _boot'), main.indexOf('runApp('));

  test('1. the background message service does not hold the first frame', () {
    expect(boot, isNot(contains('await getIt.get<BackgroundSyncController>()')));
    expect(boot, matches(RegExp(r'unawaited\(\s*getIt\s*\.get<BackgroundSyncController>\(\)\s*\.applySettings\(')));
  });

  test('1. the boot request is queued at once: a later one from the settings page goes after it', () async {
    final calls = <String>[];
    final started = Completer<void>();
    var running = false;
    final controller = BackgroundSyncController(
      configure: ({required autoStartOnBoot}) async => calls.add('configure $autoStartOnBoot'),
      start: () async {
        calls.add('start');
        await started.future;
        running = true;
        return true;
      },
      stop: () async {
        calls.add('stop');
        running = false;
        return true;
      },
      isRunning: () async => running,
      notifySettingsChanged: () => calls.add('notify'),
    );
    // The boot, not waited for, then the settings page switching the service off right away.
    final boot = controller.apply(enabled: true, intervalSeconds: 600);
    final page = controller.apply(enabled: false, intervalSeconds: 600);
    started.complete();
    expect(await boot, anyOf(BackgroundSyncApplyResult.superseded, BackgroundSyncApplyResult.running));
    expect(await page, BackgroundSyncApplyResult.stopped);
    expect(running, isFalse, reason: 'the latest request wins');
  });

  test('2. the legacy channel goes in the background, the launch notification is still read first', () {
    expect(boot, contains('unawaited(deleteLegacyLocalNoticeChannel())'));
    expect(boot, contains('await rememberNotificationLaunch()'));
  });

  test('3. no image row before the first frame, no clean up holding the homepage', () {
    final providers = File('lib/shared/providers/providers.dart').readAsStringSync();
    expect(providers, isNot(contains('preloadImageCache')));
    final home = File('lib/features/home/view/home_page.dart').readAsStringSync();
    expect(home, isNot(contains('BlocBuilder<InitCubit')));
  });
}
