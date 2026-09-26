import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/draft_box/cubit/draft_cubit.dart';
import 'package:tsdm_client/features/draft_box/repository/draft_repository.dart';
import 'package:tsdm_client/features/draft_box/view/draft_box_panel.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';

import 'draft_fixtures.dart';

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));
  testWidgets('empty state, failed refresh and retry are distinct at large text', (tester) async {
    await LocaleSettings.setLocale(AppLocale.en);
    var fail = false;
    final cubit = DraftCubit(
      currentUid: () => 1000,
      repository: () => DraftRepository((_) async {
        if (fail) throw StateError('synthetic failure');
        return draftList(empty: true);
      }),
    );
    addTearDown(cubit.close);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(2)),
              child: DraftBoxPanel(controller: cubit),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('No forum drafts'), findsOneWidget);
    fail = true;
    await tester.tap(find.text('Refresh'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not load drafts'), findsOneWidget);
    expect(find.textContaining('No forum drafts'), findsNothing);
    fail = false;
    await tester.tap(find.text('Refresh'));
    await tester.pumpAndSettle();
    expect(find.textContaining('No forum drafts'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('open draft uses existing editor and reloads after returning', (tester) async {
    await LocaleSettings.setLocale(AppLocale.en);
    var lists = 0;
    final cubit = DraftCubit(
      currentUid: () => 1000,
      repository: () => DraftRepository((url) async {
        if (url.contains('home.php')) {
          lists++;
          return draftList(empty: lists > 1);
        }
        return draftThread();
      }),
    );
    addTearDown(cubit.close);
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => Scaffold(body: DraftBoxPanel(controller: cubit)),
        ),
        GoRoute(
          path: '/edit/:editType/:fid',
          name: ScreenPaths.editPost,
          builder: (context, state) => Scaffold(
            body: TextButton(
              onPressed: () => context.pop(true),
              child: Text(
                'Editor ${state.pathParameters['fid']} ${state.uri.queryParameters['tid']} ${state.uri.queryParameters['pid']}',
              ),
            ),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(TranslationProvider(child: MaterialApp.router(routerConfig: router)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Synthetic draft 123'));
    await tester.pumpAndSettle();
    expect(find.text('Editor 4 123 456'), findsOneWidget);
    await tester.tap(find.text('Editor 4 123 456'));
    await tester.pumpAndSettle();
    expect(lists, 2);
    expect(find.textContaining('No forum drafts'), findsOneWidget);
  });
}
