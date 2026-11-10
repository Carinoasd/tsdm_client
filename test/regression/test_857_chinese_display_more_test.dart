/// The Chinese display reaches the places test 841 left out: the medals, the credit names, the titles, the user
/// groups, the rate scores and reasons, the moderation log of a thread, the floor comments, the private messages, the
/// reviews and the site statistics.
///
/// Each place converts the forum's text through `BuildContext.displayText` where it builds it: shown converted in a
/// mode, as it is with the mode off. Names of members and the app's own words stay as they are.
library;

import 'dart:io';

import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/jump_page/cubit/jump_page_cubit.dart';
import 'package:tsdm_client/features/points/models/models.dart';
import 'package:tsdm_client/features/points/widgets/points_card.dart';
import 'package:tsdm_client/features/post_comment/models/post_comment.dart';
import 'package:tsdm_client/features/post_comment/widgets/post_comment_widgets.dart';
import 'package:tsdm_client/features/profile/models/user_group_progress.dart';
import 'package:tsdm_client/features/profile/widgets/user_group_progress_bar.dart';
import 'package:tsdm_client/features/rate/widgets/fast_rate_template_card.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/site_stats/models/site_stats.dart';
import 'package:tsdm_client/features/site_stats/widgets/site_stats_chart_view.dart';
import 'package:tsdm_client/features/task_center/cubit/task_center_cubit.dart';
import 'package:tsdm_client/features/task_center/repository/task_center_repository.dart';
import 'package:tsdm_client/features/task_center/view/task_center_page.dart';
import 'package:tsdm_client/features/thread/v1/widgets/operation_log_card.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/medal.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/shared/repositories/fragments_repository/fragments_repository.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_converter.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_display.dart';
import 'package:tsdm_client/widgets/card/review_card.dart';
import 'package:tsdm_client/widgets/medal_group_view.dart';

ChineseConverter _load(String name) => ChineseConverter.parse(File('assets/text/opencc/$name.txt').readAsStringSync());

final class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

/// Whether some text on screen (a [RichText], which every [Text] builds) contains [text].
Finder _shown(String text) => find.byWidgetPredicate(
  (w) => w is RichText && w.text.toPlainText(includeSemanticsLabels: false).contains(text),
  skipOffstage: false,
);

void main() {
  late ChineseConverter s2t;
  late ChineseConverter t2s;
  late AppDatabase db;
  late SettingsRepository settings;
  late SettingsBloc bloc;

  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    s2t = _load('s2t');
    t2s = _load('t2s');
  });

  setUp(() async {
    // The app in Simplified Chinese: its own words must stay Simplified in the Traditional mode.
    await LocaleSettings.setLocale(AppLocale.zhCn);
    ChineseDisplay.instance.useConverters(s2t: s2t, t2s: t2s);
    db = AppDatabase(NativeDatabase.memory());
    final storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings)
      ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerFactory<NetClientProvider>(
        () => NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _OfflineAdapter()),
      )
      ..registerSingleton<ImageCacheProvider>(
        ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _OfflineAdapter())),
      );
    await settings.init();
    bloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository());
  });

  tearDown(() async {
    await bloc.close();
    await getIt.reset();
    await settings.dispose();
    await db.close();
    await LocaleSettings.setLocale(AppLocale.en);
  });

  /// [child] in a page of the app showing forum text in [mode]; the host sits where the app puts it, above the
  /// navigator, so dialogs and sheets are under it too.
  Future<void> pump(WidgetTester tester, ChineseDisplayMode mode, Widget child, {bool scroll = true}) async {
    await tester.pumpWidget(
      BlocProvider<SettingsBloc>.value(
        value: bloc,
        child: BlocProvider<JumpPageCubit>(
          create: (_) => JumpPageCubit(),
          child: TranslationProvider(
            child: MaterialApp(
              builder: (context, child) => ChineseDisplayHost(mode: mode, child: child!),
              home: Scaffold(
                body: scroll ? SingleChildScrollView(child: SizedBox(width: 400, child: child)) : child,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  // The avatars and pictures are asked of an offline client: let their failure land before the test ends.
  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// [child] in the Traditional mode shows [converted], with the mode off [original].
  Future<void> check(WidgetTester tester, Widget child, {required String original, required String converted}) async {
    await pump(tester, ChineseDisplayMode.traditional, child);
    expect(_shown(converted), findsWidgets);
    await pump(tester, ChineseDisplayMode.off, child);
    expect(_shown(original), findsWidgets);
    expect(_shown(converted), findsNothing);
    await finish(tester);
  }

  testWidgets('the medals of an author: name and description', (tester) async {
    const medals = [Medal(name: '软件开发达人', image: '', alter: '', description: '发布过软件开发帖')];
    await check(tester, const MedalGroupView(medals, expand: true), original: '软件开发达人', converted: '軟件開發達人');
    await check(tester, const MedalGroupView(medals, expand: true), original: '发布过软件开发帖', converted: '發佈過軟件開發帖');
    // The tooltip of the medals in a row.
    await pump(tester, ChineseDisplayMode.traditional, const MedalGroupView(medals));
    await tester.longPress(find.byType(Tooltip));
    await tester.pump(const Duration(milliseconds: 100));
    expect(_shown('軟件開發達人'), findsWidgets);
    await finish(tester);
  });

  testWidgets('the credit names of a points change, and its operation', (tester) async {
    final change = PointsChange(
      operation: '软件开发奖励',
      operationFilterUrl: '',
      pointsChangeType: PointsChangeType.more,
      changeMap: const {'天使币': '+2'},
      detail: '<td>x</td>',
      time: DateTime(2026, 9),
    );
    await check(tester, PointsChangeCard(change), original: '软件开发奖励', converted: '軟件開發獎勵');
    await check(tester, PointsChangeCard(change), original: '天使币', converted: '天使幣');
  });

  testWidgets('the rate scores: the credit name', (tester) async {
    await check(
      tester,
      const RateScoreChip(name: '天使币', value: 2),
      original: '天使币',
      converted: '天使幣',
    );
  });

  testWidgets('the user group of the progress bar', (tester) async {
    const progress = UserGroupProgress(
      mainGroupName: '软件开发组',
      credits: 10,
      currentFrom: 0,
      nextName: '高级组',
      nextFrom: 100,
    );
    await check(tester, const UserGroupProgressBar(progress), original: '软件开发组', converted: '軟件開發組');
  });

  testWidgets('the latest moderation of a thread', (tester) async {
    await check(
      tester,
      const OperationLogCard(latestAction: '软件开发 置顶', tid: '1'),
      original: '软件开发 置顶',
      converted: '軟件開發 置頂',
    );
  });

  testWidgets('the comment of a floor: the content converted, the author as it is', (tester) async {
    const comment = PostComment(authorName: '软件开发者', content: '软件开发讨论');
    await pump(tester, ChineseDisplayMode.traditional, const PostCommentTile(comment));
    expect(find.text('軟件開發討論'), findsOneWidget);
    expect(_shown('软件开发者'), findsWidgets);
    await pump(tester, ChineseDisplayMode.off, const PostCommentTile(comment));
    expect(find.text('软件开发讨论'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('the review: the content converted, the name as it is', (tester) async {
    const card = ReviewCard(name: '软件开发者', content: '软件开发讨论');
    await pump(tester, ChineseDisplayMode.traditional, card);
    expect(find.text('軟件開發討論'), findsOneWidget);
    expect(find.text('软件开发者'), findsOneWidget);
    await pump(tester, ChineseDisplayMode.off, card);
    expect(find.text('软件开发讨论'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('the legend of the site statistics', (tester) async {
    const chart = SiteStatsChart(
      labels: ['1', '2'],
      series: [
        (title: '软件开发帖', values: [1, 2]),
        (title: '回复', values: [2, 3]),
      ],
    );
    await check(
      tester,
      const SiteStatsChartView(chart),
      original: '软件开发帖',
      converted: '軟件開發帖',
    );
  });

  testWidgets('the task center: the name, the description and the reward of a task', (tester) async {
    final page = File('test/data/task/list_new_x5.html').readAsStringSync();
    final cubit = TaskCenterCubit(
      currentUid: () => 31,
      repository: () =>
          TaskCenterRepository(getPage: (_) async => page, getWrite: (_) async => (data: '', location: null)),
    );
    addTearDown(cubit.close);
    for (final mode in [ChineseDisplayMode.traditional, ChineseDisplayMode.off]) {
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            builder: (context, child) => ChineseDisplayHost(mode: mode, child: child!),
            home: TaskCenterPage(controller: cubit),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(ChineseDisplay.instance.convert(mode, '管理员专属')), findsOneWidget);
      expect(find.text(ChineseDisplay.instance.convert(mode, '仅限管理人员申请。')), findsOneWidget);
    }
    expect(find.text('管理员专属'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
