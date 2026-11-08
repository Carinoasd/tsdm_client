/// Links in a post's content to a thread are drawn as cards of the thread (the link card, part 3: the floor).
///
/// In a floor of the test forum the links showing a url of a thread get a card below them (title, author, forum,
/// replies, views), each thread asked once; the link with text of its own and the link to a forum get none. The links
/// themselves stay as they were. A card is asked once it is in view, opens its link when tapped, and is nothing when
/// the thread can not be loaded. At most 10 cards
/// in a floor; the setting turns them off. The html of anything but a post's content (a notice) keeps its links.
library;

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/thread/v1/utils/parse_thread_document.dart';
import 'package:tsdm_client/features/thread_link_card/repository/thread_link_card_repository.dart';
import 'package:tsdm_client/features/thread_link_card/widgets/thread_link_card.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/shared/repositories/fragments_repository/fragments_repository.dart';
import 'package:tsdm_client/utils/html/post_typography.dart';
import 'package:tsdm_client/widgets/munched_html.dart';

/// The first page of thread [tid] as the forum answers it.
ThreadPageInfo _page(int tid) => ThreadPageInfo(
  tid: '$tid',
  title: '帖子$tid',
  fid: 10,
  forumName: '版块$tid',
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

String _floor(String content) =>
    '<div class="t_fsz"><table cellspacing="0" cellpadding="0"><tr><td class="t_f" id="postmessage_1">'
    '$content</td></tr></table></div>';

String _link(int tid) {
  final url = '$baseUrl/forum.php?mod=viewthread&amp;tid=$tid';
  return '<a href="$url" target="_blank">$url</a>';
}

Finder _card(int tid) => find.byKey(ValueKey('thread-link-card-$tid'), skipOffstage: false);

/// The rich texts showing [text].
/// The rich texts showing [text] (the trigger before a link not loaded yet is no text).
Finder _text(String text) => find.byWidgetPredicate(
  (w) => w is RichText && w.text.toPlainText().replaceAll('\uFFFC', '').contains(text),
  skipOffstage: false,
);

void main() {
  late List<int> asked;
  late Map<int, Either<AppException, ThreadPageInfo>> answers;
  late Map<String, String>? opened;

  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
  });

  setUp(() {
    asked = [];
    answers = {};
    opened = null;
    ThreadLinkCardRepository.instance = ThreadLinkCardRepository(
      fetchPage: (tid) async {
        asked.add(tid);
        return answers[tid] ?? Right(_page(tid));
      },
      currentUid: () => 35,
    );
  });

  tearDown(() => ThreadLinkCardRepository.instance = ThreadLinkCardRepository());

  Widget app(Widget home, {SettingsBloc? settings}) {
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => Scaffold(body: home),
        ),
        GoRoute(
          path: ScreenPaths.threadV1,
          name: ScreenPaths.threadV1,
          builder: (_, state) {
            opened = state.uri.queryParameters;
            return const Text('thread page');
          },
        ),
      ],
    );
    final child = TranslationProvider(child: MaterialApp.router(routerConfig: router));
    return settings == null ? child : BlocProvider.value(value: settings, child: child);
  }

  Widget post(String html) => PostTypographyScope(typography: const PostTypography(), child: MunchedHtml(html));

  testWidgets('the links of a floor of the test forum', (tester) async {
    final html = File('test/data/thread_link_card/post_links_x5.html').readAsStringSync();
    await tester.pumpWidget(app(SingleChildScrollView(child: post(html))));
    await tester.pumpAndSettle();

    // The url links of three threads, each asked once.
    expect(asked..sort(), [9202763, 9202765, 9202766]);
    expect(_card(9202763), findsNWidgets(2));
    expect(_card(9202765), findsNWidgets(2));
    expect(_card(9202766), findsOneWidget);
    expect(find.text('帖子9202763'), findsNWidgets(2));
    expect(_text('版块9202766'), findsOneWidget);
    // The link with text of its own and the link to the forum stay as they were.
    expect(_text('自定义文字'), findsOneWidget);
    expect(_text('mod=forumdisplay&fid=10'), findsOneWidget);
    // The links stay as they were, in the line of the text around them; the card goes below.
    expect(_text('句中 $baseUrl/forum.php?mod=viewthread&tid=9202766 结尾'), findsOneWidget);
    final link = tester.getRect(_text('句中').first);
    expect(tester.getRect(_card(9202766)).top, greaterThan(link.top));

    await tester.ensureVisible(_card(9202766));
    await tester.pumpAndSettle();
    await tester.tap(_card(9202766));
    await tester.pumpAndSettle();
    expect(opened?['tid'], '9202766');
  });

  testWidgets('the floor redirect opens the thread at the floor', (tester) async {
    const url = '$baseUrl/forum.php?mod=redirect&amp;goto=findpost&amp;pid=11176&amp;ptid=9202763';
    await tester.pumpWidget(app(post(_floor('<a href="$url">$url</a>'))));
    await tester.pumpAndSettle();
    await tester.tap(_card(9202763));
    await tester.pumpAndSettle();
    expect(opened?['pid'], '11176');
  });

  testWidgets('a card is asked once it comes into view', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      app(
        SingleChildScrollView(
          controller: controller,
          child: Column(children: [const SizedBox(height: 3000), post(_floor(_link(7)))]),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(asked, isEmpty);
    expect(find.byType(ThreadLinkCard, skipOffstage: false), findsOneWidget);
    expect(_text('tid=7'), findsOneWidget);

    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(asked, [7]);
    expect(_card(7), findsOneWidget);
  });

  testWidgets('a thread that can not be loaded is the link again', (tester) async {
    answers[8] = Left(HttpRequestFailedException(500));
    await tester.pumpWidget(app(post(_floor('句中 ${_link(8)} 结尾'))));
    await tester.pumpAndSettle();
    expect(asked, [8]);
    expect(_card(8), findsNothing);
    // The link as it was, in the line of the text around it.
    expect(_text('句中 $baseUrl/forum.php?mod=viewthread&tid=8 结尾'), findsOneWidget);
  });

  testWidgets('at most 10 cards in a floor, the others stay links', (tester) async {
    final links = [for (var tid = 101; tid <= 112; tid++) '${_link(tid)}<br />'].join();
    await tester.pumpWidget(app(SingleChildScrollView(child: post(_floor(links)))));
    await tester.pumpAndSettle();
    expect(asked..sort(), [for (var tid = 101; tid <= 110; tid++) tid]);
    expect(find.byType(ThreadLinkCard), findsNWidgets(10));
    expect(_text('tid=111'), findsOneWidget);
    expect(_text('tid=112'), findsOneWidget);
  });

  testWidgets('not in the html of anything but a post', (tester) async {
    await tester.pumpWidget(
      app(PostTypographyScope(typography: const PostTypography(), postContent: false, child: MunchedHtml(_link(9)))),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ThreadLinkCard), findsNothing);
    expect(asked, isEmpty);
  });

  group('the setting', () {
    late AppDatabase db;
    late SettingsRepository settings;
    late SettingsBloc bloc;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      final storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      getIt.registerSingleton<StorageProvider>(storage);
      await settings.init();
      bloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository());
    });

    tearDown(() async {
      await bloc.close();
      await getIt.reset();
      await settings.dispose();
      await db.close();
    });

    testWidgets('on by default; off, the links stay links', (tester) async {
      expect(SettingsKeys.threadLinkCard.defaultValue, isTrue);
      expect(bloc.state.settingsMap.threadLinkCard, isTrue);
      await tester.pumpWidget(app(post(_floor(_link(10))), settings: bloc));
      await tester.pumpAndSettle();
      expect(_card(10), findsOneWidget);

      bloc.add(const SettingsValueChanged(SettingsKeys.threadLinkCard, false));
      await tester.runAsync(() => bloc.stream.firstWhere((s) => !s.settingsMap.threadLinkCard));
      expect(settings.currentSettings.threadLinkCard, isFalse);
      // A floor built again.
      await tester.pumpWidget(app(post(_floor('${_link(10)} ')), settings: bloc));
      await tester.pumpAndSettle();
      expect(find.byType(ThreadLinkCard), findsNothing);
      expect(_text('tid=10'), findsOneWidget);
    });
  });
}
