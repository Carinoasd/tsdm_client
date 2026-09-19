import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:slang_flutter/slang_flutter.dart';
import 'package:tsdm_client/features/open_in_app/view/open_in_app_page.dart';
import 'package:tsdm_client/features/root/view/root_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';

void main() {
  setUpAll(() async {
    await LocaleSettings.setLocale(AppLocale.zhCN);
  });

  group('OpenInAppPage 深度链接回归测试', () {
    testWidgets('autoOpen=false 时，仅填入链接，不自动跳转', (tester) async {
      final router = GoRouter(
        initialLocation: ScreenPaths.openInApp,
        routes: [
          GoRoute(
            path: ScreenPaths.openInApp,
            builder: (context, state) => RootPage(
              ScreenPaths.openInApp,
              OpenInAppPage(
                initialUrl: 'https://www.tsdm39.com/forum.php?mod=viewthread&tid=1266556',
                autoOpen: false,
              ),
            ),
          ),
        ],
      );

      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(OpenInAppPage), findsOneWidget);
      expect(find.text('https://www.tsdm39.com/forum.php?mod=viewthread&tid=1266556'), findsOneWidget);
    });

    testWidgets('autoOpen=true 但链接不支持时，不自动跳转', (tester) async {
      final router = GoRouter(
        initialLocation: ScreenPaths.openInApp,
        routes: [
          GoRoute(
            path: ScreenPaths.openInApp,
            builder: (context, state) => RootPage(
              ScreenPaths.openInApp,
              OpenInAppPage(
                initialUrl: 'https://www.tsdm39.net/forum.php?mod=viewthread&tid=1266556',
                autoOpen: true,
              ),
            ),
          ),
        ],
      );

      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(OpenInAppPage), findsOneWidget);
    });

    testWidgets('autoOpen=true 且链接合法时，自动跳转到目标页面', (tester) async {
      final router = GoRouter(
        initialLocation: ScreenPaths.openInApp,
        routes: [
          GoRoute(
            path: ScreenPaths.openInApp,
            builder: (context, state) => RootPage(
              ScreenPaths.openInApp,
              OpenInAppPage(
                initialUrl: 'https://www.tsdm39.com/forum.php?mod=viewthread&tid=1266556',
                autoOpen: true,
              ),
            ),
          ),
          GoRoute(
            path: ScreenPaths.threadV1,
            builder: (context, state) => const Scaffold(body: Text('Thread Page')),
          ),
        ],
      );

      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Thread Page'), findsOneWidget);
    });
  });
}
