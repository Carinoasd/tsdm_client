import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:go_router/go_router.dart';
import 'package:smooth_sheets/smooth_sheets.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/forum/models/models.dart';
import 'package:tsdm_client/features/forum/repository/forum_repository.dart';
import 'package:tsdm_client/features/forum/utils/forum_page_parser.dart';
import 'package:tsdm_client/features/forum/view/forum_page.dart';
import 'package:tsdm_client/features/notification/bloc/notification_bloc.dart';
import 'package:tsdm_client/features/notification/bloc/notification_state_cubit.dart';
import 'package:tsdm_client/features/notification/repository/notification_info_repository.dart';
import 'package:tsdm_client/features/notification/repository/notification_repository.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/shared/repositories/fragments_repository/fragments_repository.dart';
import 'package:tsdm_client/themes/app_themes.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

String _data(String name) => File('test/data/$name').readAsStringSync();

/// No network in tests: thread card avatars must not be fetched.
class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

/// Answers the same forum page every time; the second and later answers arrive late, the way the network does, so
/// the page stays in its loading state while the sheet closes.
class _SlowForumRepository implements ForumRepository {
  _SlowForumRepository(this.html);

  final String html;
  int calls = 0;

  @override
  AsyncEither<uh.Document> fetchForum({required String fid, required FilterState filterState, int pageNumber = 1}) =>
      AsyncEither(() async {
        calls += 1;
        if (calls > 1) {
          await Future<void>.delayed(const Duration(seconds: 2));
        }
        return right(parseHtmlDocument(html));
      });

  @override
  AsyncEither<ForumGroup?> fetchForumGroup(String gid) => AsyncEither(() async => right(null));
}

/// GitHub #55 (first reported as #45): picking a filter in the forum page flashed a full screen grey block.
///
/// The chips live in the page body and the page rebuilds that body the moment the filter changes, so the chip
/// element is gone while the sheet is still closing. The sheet's content was built on that chip's context: its
/// `MediaQuery` lookup then threw, the framework replaced the sheet body with the error widget, and the sheet
/// stretches to the viewport, so a release build painted the error widget's grey (0xF0C0C0C0) over the whole
/// screen for the length of the close animation - blinding in dark mode.
void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  test('the filter menus of a forum page parse into one entry each', () {
    final page = parseForumPage(parseHtmlDocument(_data('forum_thread_filters_x5.html')), '4');
    expect(page.normalThreadList.length, 2);
    // Every thread type appears once: the sheet used to build the list twice.
    expect(page.filterTypeList.map((e) => e.name).toList(), [
      '全部',
      '其他',
      '自曝',
      '心情',
      '领糖',
      '醒目',
      '官方水楼',
      '水区公告',
      '活动',
      '生日',
      '告白',
      '宣传',
      '周年',
    ]);
    expect(page.filterSpecialTypeList.map((e) => e.name).toList(), ['全部主题', '投票', '商品', '悬赏', '活动', '辩论']);
    expect(page.filterOrderList.map((e) => e.name).toList(), ['默认排序', '发帖时间', '回复/查看', '查看', '最后发表', '热门']);
    expect(page.filterDatelineList.map((e) => e.name).toList(), ['全部时间', '一天', '两天', '一周', '一个月', '三个月']);
  });

  testWidgets('picking an order keeps the sheet its own size and paints no error widget', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    final storage = StorageProvider(db, {}, {});
    final settings = SettingsRepository(storage);
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings)
      ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
      ..registerSingleton<ImageCacheProvider>(
        ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _OfflineAdapter())),
      );
    await settings.init();
    addTearDown(() async {
      await getIt.get<ImageCacheProvider>().dispose();
      await getIt.reset();
      await settings.dispose();
      await db.close();
    });
    tester.view.physicalSize = const Size(1600, 2560);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final html = _data('forum_thread_filters_x5.html');
    final dark = AppTheme.makeDark(tester.binding.rootElement!, seedColor: const Color(0xFF6750A4), fontFamily: '');
    final authRepo = AuthenticationRepository();
    addTearDown(authRepo.dispose);

    await tester.pumpWidget(
      TranslationProvider(
        child: MultiRepositoryProvider(
          providers: [
            RepositoryProvider<ForumRepository>(create: (_) => _SlowForumRepository(html)),
            RepositoryProvider<AuthenticationRepository>.value(value: authRepo),
            RepositoryProvider<FragmentsRepository>(create: (_) => FragmentsRepository()),
            RepositoryProvider<NotificationRepository>(create: (_) => NotificationRepository()),
            RepositoryProvider<NotificationInfoRepository>(create: (_) => NotificationInfoRepository()),
          ],
          child: MultiBlocProvider(
            providers: [
              BlocProvider<SettingsBloc>(
                create: (ctx) => SettingsBloc(
                  settingsRepository: settings,
                  fragmentsRepository: RepositoryProvider.of<FragmentsRepository>(ctx),
                ),
              ),
              BlocProvider<NotificationStateCubit>(
                create: (ctx) => NotificationStateCubit(RepositoryProvider.of<NotificationInfoRepository>(ctx)),
              ),
              BlocProvider<NotificationBloc>(
                create: (ctx) => NotificationBloc(
                  notificationRepository: RepositoryProvider.of<NotificationRepository>(ctx),
                  infoRepository: RepositoryProvider.of<NotificationInfoRepository>(ctx),
                  authRepo: authRepo,
                  storageProvider: storage,
                ),
              ),
            ],
            child: MaterialApp.router(
              theme: dark,
              darkTheme: dark,
              themeMode: ThemeMode.dark,
              routerConfig: GoRouter(
                routes: [
                  GoRoute(
                    path: '/',
                    builder: (_, _) => const ForumPage(fid: '4'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    double sheetHeight() =>
        (find.byType(SheetContentScaffold).evaluate().single.renderObject! as RenderBox).size.height;

    // The type sheet listed every type twice.
    await tester.tap(find.widgetWithText(FilterChip, '全部'));
    await tester.pumpAndSettle();
    expect(find.text('其他'), findsOneWidget);
    expect(find.text('自曝'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close_outlined));
    await tester.pumpAndSettle();
    expect(find.byType(SheetContentScaffold), findsNothing);

    await tester.tap(find.widgetWithText(FilterChip, '默认排序'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('最后发表'), findsOneWidget);

    final viewportHeight = tester.view.physicalSize.height / tester.view.devicePixelRatio;
    final openHeight = sheetHeight();
    expect(openHeight, lessThan(viewportHeight));

    await tester.tap(find.text('最后发表'));
    // The whole close animation, frame by frame: the sheet must never grow to the viewport and no frame may throw.
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.takeException(), isNull, reason: 'frame $i threw');
      expect(find.byType(ErrorWidget), findsNothing, reason: 'frame $i painted the error widget');
      if (find.byType(SheetContentScaffold).evaluate().isNotEmpty) {
        expect(sheetHeight(), openHeight, reason: 'frame $i resized the sheet');
      }
    }
    await tester.pumpAndSettle(const Duration(milliseconds: 16));
    expect(tester.takeException(), isNull);
    expect(find.byType(SheetContentScaffold), findsNothing);
  });
}
