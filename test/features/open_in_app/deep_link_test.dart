import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:slang_flutter/slang_flutter.dart';
import 'package:tsdm_client/features/open_in_app/view/open_in_app_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';

void main() {
  setUpAll(() async {
    await LocaleSettings.setLocale(AppLocale.zhCn);
  });

  /// 构造与 app_routes.dart 一致的 openInApp 路由（带 autoOpen 参数），
  /// 用于验证"外部链接进入 -> 自动解析 -> 跳到帖子页"的完整链路。
  List<RouteBase> buildRoutes() {
    return [
      GoRoute(
        name: ScreenPaths.openInApp,
        path: ScreenPaths.openInApp,
        builder: (context, state) {
          final url = state.uri.queryParameters['url'];
          final autoOpen = state.uri.queryParameters['autoOpen'] == 'true';
          return OpenInAppPage(initialUrl: url, autoOpen: autoOpen);
        },
      ),
      GoRoute(
        name: ScreenPaths.threadV1,
        path: ScreenPaths.threadV1,
        builder: (context, state) => const Scaffold(body: Text('Thread Page')),
      ),
    ];
  }

  group('OpenInAppPage 深度链接回归测试', () {
    testWidgets('autoOpen=false 时，仅填入链接，不自动跳转', (tester) async {
      final router = GoRouter(
        initialLocation: ScreenPaths.openInApp,
        routes: [
          GoRoute(
            name: ScreenPaths.openInApp,
            path: ScreenPaths.openInApp,
            builder: (context, state) => OpenInAppPage(
              initialUrl: 'https://www.tsdm39.com/forum.php?mod=viewthread&tid=1266556',
              autoOpen: false,
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
      expect(
        find.text('https://www.tsdm39.com/forum.php?mod=viewthread&tid=1266556'),
        findsOneWidget,
      );
    });

    testWidgets('autoOpen=true 但链接域名不受支持时，不自动跳转', (tester) async {
      final router = GoRouter(
        initialLocation: ScreenPaths.openInApp,
        routes: [
          GoRoute(
            name: ScreenPaths.openInApp,
            path: ScreenPaths.openInApp,
            builder: (context, state) => OpenInAppPage(
              initialUrl: 'https://www.tsdm39.net/forum.php?mod=viewthread&tid=1266556',
              autoOpen: true,
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

      // 依旧停留在 OpenInAppPage，说明没有自动跳转
      expect(find.byType(OpenInAppPage), findsOneWidget);
    });

    testWidgets('autoOpen=true 且链接合法时，自动跳转到目标页面', (tester) async {
      final router = GoRouter(
        initialLocation: ScreenPaths.openInApp,
        routes: [
          GoRoute(
            name: ScreenPaths.openInApp,
            path: ScreenPaths.openInApp,
            builder: (context, state) => OpenInAppPage(
              initialUrl: 'https://www.tsdm39.com/forum.php?mod=viewthread&tid=1266556',
              autoOpen: true,
            ),
          ),
          GoRoute(
            name: ScreenPaths.threadV1,
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

      // 已经跳到 threadV1 的占位页面
      expect(find.text('Thread Page'), findsOneWidget);
    });

    testWidgets('模拟外部链接接收流程：pushNamed(openInApp, url, autoOpen=true) 应自动跳到帖子页', (tester) async {
      // 构造与 app_routes.dart 相同的路由表
      final router = GoRouter(
        initialLocation: ScreenPaths.homepage,
        routes: [
          GoRoute(
            name: ScreenPaths.homepage,
            path: ScreenPaths.homepage,
            builder: (context, state) => const Scaffold(body: Text('Home')),
          ),
          ...buildRoutes(),
        ],
      );

      // 挂载 App
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      // 模拟 app.dart 的 getInitialLink / onDeepLink 路径：
      // pushNamed(openInApp) 带上 url 和 autoOpen=true
      unawaited(router.pushNamed(
        ScreenPaths.openInApp,
        queryParameters: {
          'url': 'https://www.tsdm39.com/forum.php?mod=viewthread&tid=1266556',
          'autoOpen': 'true',
        },
      ));

      await tester.pumpAndSettle();

      // 断言：最终应跳到 Thread Page，而不是停留在 OpenInAppPage
      expect(find.text('Thread Page'), findsOneWidget);
      expect(find.byType(OpenInAppPage), findsNothing);
    });
  });
}
