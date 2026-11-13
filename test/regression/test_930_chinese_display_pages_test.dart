/// The Chinese display reaches the pages tests 841 and 857 left out: the collections, the blogs, albums and wall of a
/// space (and the answers to its writes: wall, greetings, follows, records), the broadcasts of the members followed,
/// the moderation answers, the friends and the members online, the downloads and the reports.
///
/// Each place converts the forum's text through `BuildContext.displayText` where it builds it. The names of members
/// (here "简单用户", which the dictionary would convert), what can be selected and copied, and the app's own words stay
/// as they are.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/attachment_download/models/attachment_download.dart';
import 'package:tsdm_client/features/attachment_download/widgets/attachment_download_actions.dart';
import 'package:tsdm_client/features/collection/models/collection.dart';
import 'package:tsdm_client/features/collection/widgets/collection_tiles.dart';
import 'package:tsdm_client/features/follow/models/follow_models.dart';
import 'package:tsdm_client/features/follow/widgets/follow_widgets.dart';
import 'package:tsdm_client/features/friend/models/models.dart';
import 'package:tsdm_client/features/friend/widgets/friend_card.dart';
import 'package:tsdm_client/features/homepage/widgets/home_dashboard.dart';
import 'package:tsdm_client/features/jump_page/cubit/jump_page_cubit.dart';
import 'package:tsdm_client/features/moderate/models/modcp_members.dart';
import 'package:tsdm_client/features/moderate/widgets/modcp_widgets.dart';
import 'package:tsdm_client/features/report_handling/models/report_handling.dart';
import 'package:tsdm_client/features/report_handling/repository/report_source.dart';
import 'package:tsdm_client/features/report_handling/view/report_handling_page.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/space/models/space_models.dart';
import 'package:tsdm_client/features/space/repository/space_write_repository.dart';
import 'package:tsdm_client/features/space/widgets/space_social_widgets.dart';
import 'package:tsdm_client/features/space/widgets/space_widgets.dart';
import 'package:tsdm_client/features/task_center/cubit/task_center_cubit.dart';
import 'package:tsdm_client/features/task_center/repository/task_center_repository.dart';
import 'package:tsdm_client/features/task_center/view/task_center_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
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
import 'package:tsdm_client/utils/load_failure.dart';
import 'package:tsdm_client/widgets/failure_view.dart';

ChineseConverter _load(String name) => ChineseConverter.parse(File('assets/text/opencc/$name.txt').readAsStringSync());

final class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

/// A list of reports read once, nothing written.
final class _Reports implements ReportSource {
  _Reports(this.items);

  final List<ReportItem> items;

  @override
  Future<Either<AppException, ReportAnswer>> load({String scope = '', int page = 1}) async => right(
    ReportReady(
      ReportList(
        uid: 32,
        scopes: const [],
        scope: '2',
        scopeLabel: '',
        needScope: false,
        page: 1,
        pages: 1,
        count: items.length,
        items: items,
      ),
    ),
  );

  @override
  Future<Either<AppException, ReportOutcome>> resolve(ReportList list, List<ReportDecision> decisions) async =>
      right(const ReportNotDone(''));

  @override
  Future<Either<AppException, ReportOutcome>> delete(ReportList list, List<ReportItem> items) async =>
      right(const ReportNotDone(''));

  @override
  Widget loginView(ReportNeedsLogin need, Future<void> Function() onLoggedIn) => const SizedBox.shrink();
}

/// The name of a member: the dictionary would convert it, so a conversion would show.
const _member = '简单用户';
const _memberTraditional = '簡單用戶';

/// Whether some text on screen (a [RichText], which every [Text] builds) contains [text].
Finder _shown(String text) => find.byWidgetPredicate(
  (w) => w is RichText && w.text.toPlainText(includeSemanticsLabels: false).contains(text),
  skipOffstage: false,
);

/// Whether some selectable text on screen contains [text].
Finder _selectable(String text) => find.byWidgetPredicate(
  (w) => w is EditableText && w.controller.text.contains(text),
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
              scaffoldMessengerKey: snackbarKey,
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

  group('collections', () {
    const summary = CollectionSummary(
      ctid: 1,
      name: '简体淘帖',
      description: '关于动画的说明',
      keywords: ['动画'],
      threadCount: 3,
      followCount: 2,
      commentCount: 1,
      creatorUid: 7,
      creatorName: _member,
      lastUpdate: '',
      latestThread: null,
      relation: null,
      updated: false,
    );
    const thread = CollectionThread(
      tid: 2,
      subject: '简体标题',
      reason: '值得收藏的内容',
      authorUid: 7,
      authorName: _member,
      date: '',
      replies: 1,
      views: 2,
    );
    const comment = CollectionComment(uid: 7, username: _member, time: '', message: '简体点评', rate: 4);

    testWidgets('the name, description, keywords, subjects and reasons converted; the members and comments not', (
      tester,
    ) async {
      await pump(
        tester,
        ChineseDisplayMode.traditional,
        const Column(
          children: [CollectionSummaryCard(summary), CollectionThreadTile(thread), CollectionCommentTile(comment)],
        ),
      );
      expect(_shown('簡體淘帖'), findsOneWidget);
      expect(_shown('關於動畫的說明'), findsOneWidget);
      expect(_shown('動畫'), findsWidgets);
      expect(_shown('簡體標題'), findsOneWidget);
      expect(_shown('值得收藏的內容'), findsOneWidget);
      expect(_shown(_member), findsNWidgets(3));
      expect(_shown(_memberTraditional), findsNothing);
      expect(_selectable('简体点评'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('as the forum wrote it with the mode off', (tester) async {
      await pump(tester, ChineseDisplayMode.off, const CollectionThreadTile(thread));
      expect(_shown('简体标题'), findsOneWidget);
      expect(_shown('值得收藏的内容'), findsOneWidget);
      await finish(tester);
    });
  });

  group('space', () {
    testWidgets('a blog: its title and category converted', (tester) async {
      await pump(
        tester,
        ChineseDisplayMode.traditional,
        const Column(
          children: [
            SpaceBlogCard(SpaceBlog(blogId: 1, uid: 7, title: '简体日志', category: '动画分类', author: _member)),
            SizedBox(height: 200, child: SpaceAlbumTile(SpaceAlbum(albumId: 1, uid: 7, name: '简体相册'))),
          ],
        ),
      );
      expect(_shown('簡體日誌'), findsOneWidget);
      expect(_shown('動畫分類'), findsOneWidget);
      expect(_shown('簡體相冊'), findsOneWidget);
      await finish(tester);
    });

    testWidgets("the answer to a write (wall, greeting, follow, record): the forum's words converted, the app's not", (
      tester,
    ) async {
      await pump(
        tester,
        ChineseDisplayMode.traditional,
        Builder(
          builder: (context) => Column(
            children: [
              TextButton(
                key: const ValueKey('forum'),
                onPressed: () => showSpaceWriteResult(
                  context,
                  const SpaceWriteResult(SpaceWriteOutcome.rejected, message: '对方设置了隐私'),
                  done: '',
                ),
                child: const Text('forum'),
              ),
              TextButton(
                key: const ValueKey('app'),
                onPressed: () =>
                    showSpaceWriteResult(context, const SpaceWriteResult(SpaceWriteOutcome.done), done: '已发送'),
                child: const Text('app'),
              ),
            ],
          ),
        ),
        scroll: false,
      );
      await tester.tap(find.byKey(const ValueKey('forum')));
      await tester.pump();
      expect(_shown('對方設置了隱私'), findsOneWidget);
      snackbarKey.currentState!.clearSnackBars();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('app')));
      await tester.pump();
      expect(_shown('已发送'), findsOneWidget);
      await finish(tester);
    });
  });

  testWidgets("a broadcast: the thread's title and forum converted; the member and the line naming the author not", (
    tester,
  ) async {
    await pump(
      tester,
      ChineseDisplayMode.traditional,
      const FollowFeedCard(
        FollowFeed(
          feedId: 1,
          uid: 7,
          username: _member,
          threadId: 2,
          threadTitle: '简体标题',
          origin: '$_member 发表于 2026-11-7 22:05',
          forumName: '动画版块',
        ),
      ),
    );
    expect(_shown('簡體標題'), findsOneWidget);
    expect(_shown('#動畫版塊'), findsOneWidget);
    expect(_shown('$_member 发表于'), findsOneWidget);
    expect(_shown(_memberTraditional), findsNothing);
    await finish(tester);
  });

  testWidgets("the moderation panel's answers: the forum's words converted, the app's not", (tester) async {
    await pump(
      tester,
      ChineseDisplayMode.traditional,
      Builder(
        builder: (context) => Column(
          children: [
            Text(modcpOutcomeText(context, right(const ModcpWriteDone(message: '操作成功，已删除')))),
            Text(modcpOutcomeText(context, right(const ModcpWriteRefused('没有权限管理该用户')))),
            Text(modcpOutcomeText(context, right(const ModcpWriteDone()))),
          ],
        ),
      ),
    );
    expect(_shown('操作成功，已刪除'), findsOneWidget);
    expect(_shown('沒有權限管理該用戶'), findsOneWidget);
    expect(_shown(t.moderate.done), findsOneWidget);
    await finish(tester);
  });

  testWidgets('a page the forum refused: its message converted', (tester) async {
    await pump(
      tester,
      ChineseDisplayMode.traditional,
      FailureView(failure: LoadFailure.fromMessage('该版块已关闭')),
      scroll: false,
    );
    expect(_shown('該版塊已關閉'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('a friend and the members online: the user group and the forum line converted, the name not', (
    tester,
  ) async {
    await pump(
      tester,
      ChineseDisplayMode.traditional,
      const Column(
        children: [
          FriendCard(Friend(uid: '7', username: _member, groupName: '动画会员')),
          HomeOnlineCard(summary: ['当前在线 3 人']),
        ],
      ),
    );
    expect(_shown('動畫會員'), findsOneWidget);
    expect(_shown('當前在線 3 人'), findsOneWidget);
    expect(_shown(_member), findsOneWidget);
    expect(_shown(_memberTraditional), findsNothing);
    await finish(tester);
  });

  testWidgets("a download: the forum's words converted, the file name not", (tester) async {
    await pump(
      tester,
      ChineseDisplayMode.traditional,
      AttachmentDownloadView(
        AttachmentDownload(
          id: 'd1',
          uid: 7,
          url: 'https://forum.test/forum.php?mod=attachment&aid=1',
          filename: '简体资料.zip',
          createdAt: DateTime(2026, 11, 13),
          status: AttachmentDownloadStatus.failed,
          message: '抱歉，您的积分不足',
          notice: '您的 天使币 -1 ，现在将开始下载',
        ),
      ),
    );
    expect(_shown('简体资料.zip'), findsOneWidget);
    expect(_shown('抱歉，您的積分不足'), findsOneWidget);
    expect(_shown('現在將開始下載'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('a report: the reason and the excerpt converted, the name of the reporter not', (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pump(
      tester,
      ChineseDisplayMode.traditional,
      ReportHandlingPage(
        source: _Reports([
          const ReportItem(
            id: 1,
            url: 'forum.php?mod=redirect&goto=findpost&ptid=2&pid=3',
            tid: 2,
            pid: 3,
            fid: 2,
            forum: '动画版块',
            lines: ['$_member : 广告内容'],
            uid: 7,
            username: _member,
            dateline: 1700000000,
            count: 1,
            excerpt: '简体摘要',
          ),
        ]),
      ),
      scroll: false,
    );
    await tester.pumpAndSettle();
    expect(_shown('$_member : 廣告內容'), findsOneWidget);
    expect(_shown('簡體摘要'), findsOneWidget);
    expect(_shown(_memberTraditional), findsNothing);
    await finish(tester);
  });

  testWidgets("a task claimed: the task's name converted in the app's sentence", (tester) async {
    String file(String name) => File('test/data/task/$name').readAsStringSync();
    var doing = 'list_doing_complete_x5.html';
    final cubit = TaskCenterCubit(
      currentUid: () => 31,
      repository: () => TaskCenterRepository(
        getPage: (url) async => file(switch (Uri.parse(url).queryParameters['item']) {
          'new' => 'list_new_x5.html',
          'doing' => doing,
          _ => 'list_done_x5.html',
        }),
        getWrite: (_) async {
          doing = 'list_doing_empty_x5.html';
          return (data: file('draw_reward.json'), location: null);
        },
      ),
    );
    addTearDown(cubit.close);
    await pump(tester, ChineseDisplayMode.traditional, TaskCenterPage(controller: cubit), scroll: false);
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.taskCenter.tabDoing));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('task-claim-2')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.general.ok));
    await tester.pumpAndSettle();
    // "回复三次" in the dictionary's words; the sentence around it stays as the app wrote it.
    expect(_shown(t.taskCenter.rewarded(name: '回覆三次')), findsOneWidget);
    await finish(tester);
  });
}
