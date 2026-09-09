import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/local_notice/callback.dart';
import 'package:tsdm_client/features/local_notice/keys.dart';
import 'package:tsdm_client/features/local_notice/stream.dart';
import 'package:tsdm_client/features/local_notice/tap.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';

/// GitHub #14: a tap on the auto sync notification decides by the page the router really shows on top, not by the
/// location stack that drifted after the notice page was left once (the log showed "do not push to notice page
/// already in it" while the homepage was in front).
void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  test('login first, then whether the notice page is on top', () {
    expect(decideLocalNoticeTap(loggedIn: false, topLocation: ScreenPaths.homepage), LocalNoticeTapAction.needLogin);
    expect(decideLocalNoticeTap(loggedIn: false, topLocation: ScreenPaths.notice), LocalNoticeTapAction.needLogin);
    expect(
      decideLocalNoticeTap(loggedIn: true, topLocation: ScreenPaths.notice),
      LocalNoticeTapAction.alreadyOnNoticePage,
    );
    expect(
      decideLocalNoticeTap(loggedIn: true, topLocation: ScreenPaths.homepage),
      LocalNoticeTapAction.openNoticePage,
    );
    expect(
      decideLocalNoticeTap(loggedIn: true, topLocation: ScreenPaths.threadV1),
      LocalNoticeTapAction.openNoticePage,
    );
    expect(decideLocalNoticeTap(loggedIn: true, topLocation: null), LocalNoticeTapAction.openNoticePage);
  });

  test('a tap reaches the stream with its payload', () async {
    final got = <String?>[];
    final sub = localNoticeStream.stream.listen(got.add);
    addTearDown(sub.cancel);
    onLocalNotificationOpened(
      const NotificationResponse(
        notificationResponseType: NotificationResponseType.selectedNotification,
        id: 0,
        payload: LocalNoticeKeys.openNotification,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(got, [LocalNoticeKeys.openNotification]);
  });

  testWidgets('the router reports the page on top: shell branch, pushed page, page under a dialog', (tester) async {
    final router = GoRouter(
      initialLocation: ScreenPaths.homepage,
      routes: [
        StatefulShellRoute.indexedStack(
          builder: (_, _, navigator) => navigator,
          branches: [
            StatefulShellBranch(
              routes: [
                GoRoute(path: ScreenPaths.homepage, name: ScreenPaths.homepage, builder: (_, _) => const Text('home')),
              ],
            ),
          ],
        ),
        GoRoute(path: ScreenPaths.notice, name: ScreenPaths.notice, builder: (_, _) => const Text('notice')),
        GoRoute(path: ScreenPaths.threadV1, name: ScreenPaths.threadV1, builder: (_, _) => const Text('thread')),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    expect(routerTopLocation(router), ScreenPaths.homepage);

    unawaited(router.pushNamed(ScreenPaths.notice));
    await tester.pumpAndSettle();
    expect(find.text('notice'), findsOneWidget);
    expect(routerTopLocation(router), ScreenPaths.notice);
    expect(
      decideLocalNoticeTap(loggedIn: true, topLocation: routerTopLocation(router)),
      LocalNoticeTapAction.alreadyOnNoticePage,
    );

    unawaited(router.pushNamed(ScreenPaths.threadV1));
    await tester.pumpAndSettle();
    expect(routerTopLocation(router), ScreenPaths.threadV1);

    router.pop();
    await tester.pumpAndSettle();
    expect(routerTopLocation(router), ScreenPaths.notice);

    // Back on the homepage after leaving the notice page: this is the tap the location stack refused.
    router.pop();
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);
    expect(routerTopLocation(router), ScreenPaths.homepage);
    expect(
      decideLocalNoticeTap(loggedIn: true, topLocation: routerTopLocation(router)),
      LocalNoticeTapAction.openNoticePage,
    );

    // A dialog is not a page of the router: the page under it is still the one on top.
    final ctx = router.routerDelegate.navigatorKey.currentContext!;
    unawaited(
      showDialog<void>(
        context: ctx,
        builder: (_) => const AlertDialog(title: Text('dialog')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('dialog'), findsOneWidget);
    expect(routerTopLocation(router), ScreenPaths.homepage);
  });
}
