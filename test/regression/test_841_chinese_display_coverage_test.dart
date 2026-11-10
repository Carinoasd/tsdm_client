/// The Chinese display (settings, appearance) reaches every place that shows forum text, not only the app bar and the
/// html the muncher lays out: the title above the first floor, the online storage chips, the poll, the thread cards
/// of the lists and the search results (title, thread type, forum, excerpt), the notifications, the thread link
/// cards, the special thread cards, the user group of a floor's author and the forum cards.
///
/// Each place converts the forum's text through `BuildContext.displayText` where it builds it: shown converted in a
/// mode, as it is with the mode off, and built again when the mode changes. The app's own words (translations), the
/// text fields and what is copied stay as they are.
library;

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart' hide State;
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/jump_page/cubit/jump_page_cubit.dart';
import 'package:tsdm_client/features/netdisk/models/netdisk_link.dart';
import 'package:tsdm_client/features/netdisk/widgets/netdisk_row.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/features/poll/cubit/poll_cubit.dart';
import 'package:tsdm_client/features/poll/repository/poll_repository.dart';
import 'package:tsdm_client/features/search/models/models.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/special_thread/widgets/special_thread_card.dart';
import 'package:tsdm_client/features/thread/v1/utils/parse_thread_document.dart';
import 'package:tsdm_client/features/thread/v1/utils/thread_page_api.dart';
import 'package:tsdm_client/features/thread/v1/widgets/post_list.dart';
import 'package:tsdm_client/features/thread_link_card/repository/thread_link_card_repository.dart';
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
import 'package:tsdm_client/utils/chinese_display/chinese_converter.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_display.dart';
import 'package:tsdm_client/utils/html/post_typography.dart';
import 'package:tsdm_client/widgets/card/forum_card.dart';
import 'package:tsdm_client/widgets/card/notice_card_v2.dart';
import 'package:tsdm_client/widgets/card/poll_card.dart';
import 'package:tsdm_client/widgets/card/post_card/post_card.dart';
import 'package:tsdm_client/widgets/card/thread_card/thread_card.dart';
import 'package:tsdm_client/widgets/munched_html.dart';
import 'package:universal_html/parsing.dart';

ChineseConverter _load(String name) => ChineseConverter.parse(File('assets/text/opencc/$name.txt').readAsStringSync());

Map<String, dynamic> _json(String name) =>
    jsonDecode(File('test/data/tsdmapp/$name.json').readAsStringSync()) as Map<String, dynamic>;

/// The special part of the thread page fixture `special_v15_[name].json`, its strings changed by [edit].
T _special<T extends ThreadSpecial>(String name, void Function(Map<String, dynamic> special) edit) {
  final json = _json('special_v15_$name');
  edit(json['special'] as Map<String, dynamic>);
  return threadPageFromApi(json, 1).special! as T;
}

final class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

const _author = User(name: '作者甲', url: '$baseUrl/home.php?mod=space&uid=2000', uid: '2000');

NormalThread _thread({String title = '软件开发讨论', ThreadType? type, ThreadPreview? preview}) => NormalThread(
  title: title,
  url: '$baseUrl/forum.php?mod=viewthread&tid=10',
  threadID: '10',
  author: _author,
  publishDate: DateTime(2026, 9),
  latestReplyAuthor: _author,
  latestReplyTime: DateTime(2026, 9, 2, 8),
  iconUrl: '',
  threadType: type,
  replyCount: 3,
  viewCount: 30,
  price: null,
  privilege: null,
  css: null,
  stateSet: const {},
  isRecentThread: false,
  preview: preview,
);

ThreadPageInfo _linkedPage(int tid) => ThreadPageInfo(
  tid: '$tid',
  title: '软件开发$tid',
  fid: 10,
  forumName: '动漫论坛',
  currentPage: 1,
  totalPages: 1,
  havePermission: true,
  permissionDeniedMessage: null,
  needLogin: false,
  threadSoftClosed: false,
  threadClosed: false,
  postList: const [],
  replyParameters: null,
  threadType: null,
  isDraft: false,
  latestModAct: null,
  breadcrumbs: const [],
  postMedals: const [],
  viewCount: 40,
  replyCount: 5,
);

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
    ThreadLinkCardRepository.instance = ThreadLinkCardRepository();
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

  /// [child] shown in each mode, in turn on the same tree: [check] gets what the forum's text should look like.
  Future<void> eachMode(
    WidgetTester tester,
    Widget child,
    void Function(String Function(String forumText) shown) check, {
    bool scroll = true,
  }) async {
    for (final mode in [ChineseDisplayMode.traditional, ChineseDisplayMode.off, ChineseDisplayMode.simplified]) {
      await pump(tester, mode, child, scroll: scroll);
      check((text) => ChineseDisplay.instance.convert(mode, text));
    }
  }

  // The avatars and pictures are asked of an offline client: let their failure land before the test ends.
  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('the title above the first floor', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final list = PostList(
      threadID: '1',
      postList: const [],
      canLoadMore: false,
      scrollController: controller,
      latestModAct: null,
      title: '软件开发讨论',
      widgetBuilder: (_, p) => Text('post ${p.postID}'),
    );
    await pump(tester, ChineseDisplayMode.traditional, list, scroll: false);
    expect(find.text('軟件開發討論'), findsOneWidget);
    await pump(tester, ChineseDisplayMode.off, list, scroll: false);
    expect(find.text('软件开发讨论'), findsOneWidget);
  });

  testWidgets('the online storage chips: the service converted, the codes and the copied code as they are', (
    tester,
  ) async {
    const link = NetdiskLink(
      url: 'https://pan.baidu.com/s/1abc',
      provider: NetdiskProvider(name: '百度网盘', hosts: ['pan.baidu.com']),
      extractCode: '后来',
      unzipPassword: 'x发y',
    );
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map<Object?, Object?>)['text'] as String?;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));

    await pump(tester, ChineseDisplayMode.traditional, const NetdiskRow(link: link));
    expect(find.text('百度網盤'), findsOneWidget);
    // The codes are typed by hand on the service's page: shown as written, the app's words as they are.
    expect(find.text('${t.netdisk.extractCode} 后来'), findsOneWidget);
    expect(t.netdisk.extractCode, '提取码');
    expect(find.text('${t.netdisk.unzipPassword} x发y'), findsOneWidget);
    await tester.tap(find.text('${t.netdisk.extractCode} 后来'));
    await tester.pump();
    expect(copied, '后来');

    await pump(tester, ChineseDisplayMode.off, const NetdiskRow(link: link));
    expect(find.text('百度网盘'), findsOneWidget);
  });

  testWidgets('the poll: its summary, deadline and options', (tester) async {
    final html = File('test/data/poll_multiple_x5.html')
        .readAsStringSync()
        .replaceFirst('&nbsp;A</label>', '&nbsp;软件开发</label>')
        .replaceFirst('&nbsp;B</label>', '&nbsp;头发</label>');
    final repo = PollRepository(getPage: (_) async => html, postForm: (_, _) async => '');
    final cubit = PollCubit(url: 'poll', currentUid: () => 1000, repository: () => repo);
    addTearDown(cubit.close);
    final card = PollCard('1', controller: cubit);

    await pump(tester, ChineseDisplayMode.traditional, card);
    await tester.pumpAndSettle();
    expect(find.text('1. 軟件開發'), findsOneWidget);
    expect(find.text('2. 頭髮'), findsOneWidget);
    expect(_shown('多選投票'), findsOneWidget);
    expect(_shown('距結束還有'), findsOneWidget);
    // The card's own title is the app's word.
    expect(find.text(t.pollCard.title), findsOneWidget);

    await pump(tester, ChineseDisplayMode.off, card);
    expect(find.text('1. 软件开发'), findsOneWidget);
    expect(_shown('多选投票'), findsOneWidget);
    expect(_shown('距结束还有'), findsOneWidget);
  });

  testWidgets("the poll of the app's API: the options converted, its summary and deadline in the app's words", (
    tester,
  ) async {
    final poll = _special<PollSpecial>('poll_single_before', (s) {
      s['expiration'] = 1792716600;
      ((s['choices'] as List).first as Map<String, dynamic>)
        ..['text'] = '软件开发'
        ..['html'] = '软件开发';
    });
    // The card the thread page builds for it, for the account the page was served to.
    final auth = AuthenticationRepository(
      user: UserLoginInfo(username: 'viewer', uid: poll.viewerUid),
    );
    addTearDown(auth.dispose);
    final card = RepositoryProvider<AuthenticationRepository>.value(
      value: auth,
      child: SpecialThreadCard(poll, pid: '1'),
    );
    await pump(tester, ChineseDisplayMode.traditional, card);
    expect(find.text('1. 軟件開發'), findsOneWidget);
    // Built by the app from its translations (Simplified here): not rewritten.
    expect(_shown(t.specialThread.poll.single), findsOneWidget);
    expect(t.specialThread.poll.single, '单选投票');
    expect(_shown('投票截止：'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('the thread card of a list: title, thread type and excerpt; rebuilt when the mode changes', (
    tester,
  ) async {
    final card = NormalThreadCard(
      _thread(
        type: const ThreadType(name: '资源发布', url: '$baseUrl/forum.php?mod=forumdisplay&fid=2&typeid=1'),
        preview: const ThreadPreview(excerpt: '这是头发和发展的摘要', images: []),
      ),
      disableTap: true,
    );
    await eachMode(tester, card, (shown) {
      expect(find.text(shown('软件开发讨论')), findsOneWidget);
      expect(find.text(shown('资源发布')), findsOneWidget);
      expect(find.text(shown('这是头发和发展的摘要')), findsOneWidget);
    });
    expect(find.text('軟件開發討論'), findsNothing);
  });

  testWidgets('the search results: title and forum', (tester) async {
    final card = SearchedThreadCard(
      SearchedThread(
        tid: 10,
        title: '软件开发讨论',
        url: '$baseUrl/forum.php?mod=viewthread&tid=10',
        author: _author,
        publishTime: DateTime(2026, 9),
        forumName: '动漫论坛',
        forumUrl: '$baseUrl/forum.php?mod=forumdisplay&fid=2',
      ),
    );
    await pump(tester, ChineseDisplayMode.traditional, card);
    expect(find.text('軟件開發討論'), findsOneWidget);
    expect(find.text('動漫論壇'), findsOneWidget);
    // A user's name is who they are: never rewritten.
    expect(find.text('作者甲'), findsOneWidget);
    await pump(tester, ChineseDisplayMode.off, card);
    expect(find.text('动漫论坛'), findsOneWidget);
  });

  testWidgets('a notification', (tester) async {
    const notice = NoticeV2(
      id: 1,
      timestamp: 1788000001,
      data:
          '<a href="home.php?mod=space&uid=2000">作者甲</a> 回复了您的帖子 '
          '<a href="forum.php?mod=redirect&goto=findpost&ptid=10&pid=20">软件开发讨论</a>',
      authorId: 2000,
      author: '作者甲',
    );
    await pump(tester, ChineseDisplayMode.traditional, const NoticeCardV2(notice));
    expect(_shown('軟件開發討論'), findsOneWidget);
    expect(find.text('作者甲'), findsWidgets);
    await pump(tester, ChineseDisplayMode.off, const NoticeCardV2(notice));
    expect(_shown('软件开发讨论'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('the card of a thread linked in a floor: title and forum', (tester) async {
    ThreadLinkCardRepository.instance = ThreadLinkCardRepository(
      fetchPage: (tid) async => Right(_linkedPage(tid)),
      currentUid: () => 35,
    );
    const url = '$baseUrl/forum.php?mod=viewthread&amp;tid=7';
    const floor = PostTypographyScope(
      typography: PostTypography(),
      child: MunchedHtml(
        '<div class="t_fsz"><table cellspacing="0" cellpadding="0"><tr><td class="t_f" id="postmessage_1"><a href="$url" target="_blank">$url</a></td></tr></table></div>',
      ),
    );
    await pump(tester, ChineseDisplayMode.traditional, floor);
    await tester.pumpAndSettle();
    expect(_shown('軟件開發7'), findsOneWidget);
    expect(_shown('動漫論壇'), findsOneWidget);
    await pump(tester, ChineseDisplayMode.off, floor);
    await tester.pumpAndSettle();
    expect(_shown('软件开发7'), findsOneWidget);
    expect(_shown('动漫论坛'), findsOneWidget);
  });

  group('the special thread cards', () {
    testWidgets('the activity: its class, place and the message of an applicant', (tester) async {
      final activity = _special<ActivitySpecial>('activity_applied', (s) {
        s['class'] = '线下聚会';
        s['place'] = '广场东门';
        ((s['applylist'] as List).first as Map<String, dynamic>)['message'] = '我会准时到';
      });
      final card = SpecialThreadCard(activity, pid: '5824');
      await pump(tester, ChineseDisplayMode.traditional, card);
      expect(find.text('線下聚會'), findsWidgets);
      expect(find.text('廣場東門'), findsOneWidget);
      expect(_shown('我會準時到'), findsOneWidget);
      // The app's words beside them (Simplified, as the app is) are left alone.
      expect(find.text(t.specialThread.activity.place), findsOneWidget);
      await pump(tester, ChineseDisplayMode.off, card);
      expect(find.text('广场东门'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('the trade: the subject of the goods', (tester) async {
      final trade = _special<TradeSpecial>('trade_guest', (s) {
        ((s['goods'] as List).first as Map<String, dynamic>)['subject'] = '限量发售软件';
      });
      final card = SpecialThreadCard(trade, pid: '5796');
      await pump(tester, ChineseDisplayMode.traditional, card);
      expect(find.text('限量發售軟件'), findsOneWidget);
      await pump(tester, ChineseDisplayMode.off, card);
      expect(find.text('限量发售软件'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('the bounty: the excerpt of the accepted answer', (tester) async {
      final reward = _special<RewardSpecial>('reward_resolved', (s) {
        (s['bestpost'] as Map<String, dynamic>)['excerpt'] = '最佳答案：后来发现了';
      });
      final card = SpecialThreadCard(reward, pid: '5806');
      await pump(tester, ChineseDisplayMode.traditional, card);
      expect(find.text('最佳答案：後來發現了'), findsOneWidget);
      await pump(tester, ChineseDisplayMode.off, card);
      expect(find.text('最佳答案：后来发现了'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('the debate: a point without html', (tester) async {
      final debate = _special<DebateSpecial>('debate_open_member', (s) {
        for (final key in s.keys.toList()) {
          if (key.endsWith('point_html')) {
            s[key] = '';
          }
        }
        s['affirmpoint'] = '正方认为后来者居上';
      });
      final card = SpecialThreadCard(debate, pid: '6297');
      await pump(tester, ChineseDisplayMode.traditional, card);
      expect(find.text('正方認爲後來者居上'), findsOneWidget);
      await pump(tester, ChineseDisplayMode.off, card);
      expect(find.text('正方认为后来者居上'), findsOneWidget);
      await finish(tester);
    });
  });

  testWidgets("the user group of a floor's author", (tester) async {
    final html = File('test/data/locked_purchase_x5.html').readAsStringSync();
    final post = Post.fromPostNode(parseHtmlDocument(html).querySelector('div#post_77983102')!, 1)!;
    final profile = post.userBriefProfile!;
    final card = PostCard(
      post.copyWith(
        author: User(name: post.author.name, uid: post.author.uid, url: post.author.url),
        userBriefProfile: profile.copyWith(userGroup: '论坛元老'),
        postMedals: null,
        badge: null,
        secondBadge: null,
        signature: null,
        pokemon: null,
        checkin: null,
      ),
    );
    await pump(tester, ChineseDisplayMode.traditional, card);
    expect(find.textContaining('論壇元老'), findsOneWidget);
    expect(find.text(post.author.name), findsWidgets);
    await pump(tester, ChineseDisplayMode.off, card);
    expect(find.textContaining('论坛元老'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('the forum card: the latest thread and the threads its description links', (tester) async {
    const forum = Forum(
      forumID: 2,
      url: '$baseUrl/forum.php?mod=forumdisplay&fid=2',
      name: '动漫论坛',
      iconUrl: '',
      threadCount: 10,
      replyCount: 20,
      latestThreadUrl: '$baseUrl/forum.php?mod=redirect&tid=10&goto=lastpost#lastpost',
      latestThreadTime: null,
      latestThreadTimeText: null,
      threadTodayCount: 1,
      latestThreadTitle: '软件开发讨论',
      latestThreadUserName: '作者甲',
      subThreadList: [('版规与发帖须知', '$baseUrl/forum.php?mod=viewthread&tid=11')],
    );
    // The latest thread and the links show with the shortcuts of a forum card on.
    await pump(tester, ChineseDisplayMode.off, const ForumCard(forum));
    await tester.runAsync(() async {
      await settings.setValue(SettingsKeys.showShortcutInForumCard, true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pump();
    await tester.tap(find.textContaining('(1)'));
    await tester.pump();
    await eachMode(tester, const ForumCard(forum), (shown) {
      expect(find.text(shown('动漫论坛')), findsOneWidget);
      expect(find.text(shown('软件开发讨论')), findsOneWidget);
      expect(find.text(shown('版规与发帖须知')), findsOneWidget);
      expect(find.text('作者甲'), findsOneWidget);
    });
  });

  testWidgets('a text field keeps what is typed in it', (tester) async {
    final controller = TextEditingController(text: '软件开发');
    addTearDown(controller.dispose);
    await pump(
      tester,
      ChineseDisplayMode.traditional,
      Column(
        children: [
          Builder(builder: (context) => Text(context.displayText('软件开发'), key: const ValueKey('shown'))),
          TextField(controller: controller),
        ],
      ),
    );
    expect(tester.widget<Text>(find.byKey(const ValueKey('shown'))).data, '軟件開發');
    expect(tester.widget<EditableText>(find.byType(EditableText)).controller.text, '软件开发');
    await tester.enterText(find.byType(TextField), '头发');
    expect(controller.text, '头发');
  });
}
