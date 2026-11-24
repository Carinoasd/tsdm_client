/// The homepage, the thread page and the thread lists are back to the cards of 1.61.0 (1.62.0 had them flat), with
/// three things of 1.62.0 kept on the thread page:
///
/// 1. Cards: each floor is a rounded card 6 in from the sides of a phone (16 wider), each row of a thread list is a
///    card, the greeting of the homepage is in a card, and each pinned group of the desktop homepage is a card whose
///    rows have the author above a one line thread title. Ten rows of a group at the text sizes 1.0 and 1.3 neither
///    overflow nor reach the group below.
/// 2. Kept from 1.62.0: the user group is a small tag beside the name, the line under the name holds the time and
///    "from the app" only; a quote is a block of the inset layer, its text a step smaller than the body text (13 for
///    14). The title above the floors and its fade in the app bar are in test_239.
/// 3. The body text of a post is 14 again, the floors' line width follows it.
///
/// Synthetic data: the account is 大和啦, the other names are made up, no picture is loaded.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart' show AuthStatus;
import 'package:tsdm_client/features/checkin/bloc/checkin_bloc.dart';
import 'package:tsdm_client/features/checkin/repository/checkin_repository.dart';
import 'package:tsdm_client/features/homepage/models/models.dart';
import 'package:tsdm_client/features/homepage/widgets/home_dashboard.dart';
import 'package:tsdm_client/features/homepage/widgets/widgets.dart';
import 'package:tsdm_client/features/jump_page/cubit/jump_page_cubit.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/thread/v1/widgets/post_list.dart';
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
import 'package:tsdm_client/themes/app_surfaces.dart';
import 'package:tsdm_client/themes/app_themes.dart';
import 'package:tsdm_client/utils/html/post_typography.dart';
import 'package:tsdm_client/utils/html/sentence_breaks.dart';
import 'package:tsdm_client/widgets/card/post_card/post_card.dart';
import 'package:tsdm_client/widgets/card/thread_card/thread_card.dart';
import 'package:tsdm_client/widgets/munched_html.dart';
import 'package:tsdm_client/widgets/quoted_text.dart';
import 'package:tsdm_client/widgets/single_line_text.dart';

const _me = UserLoginInfo(username: '大和啦', uid: 2042122);

/// No network at all.
final class _Offline implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

final class _Auth extends Fake implements AuthenticationRepository {
  @override
  UserLoginInfo? get currentUser => _me;

  @override
  int? get effectiveCurrentUid => _me.uid;

  @override
  Stream<AuthStatus> get status => const Stream.empty();
}

UserBriefProfile _profile(String name, String group) => UserBriefProfile(
  username: name,
  avatarUrl: null,
  uid: '7',
  nickname: null,
  userGroup: group,
  userGroupColor: null,
  title: null,
  recommended: '0',
  threadCount: '0',
  postCount: '0',
  famous: '0',
  coins: '0',
  publicity: '0',
  natural: '0',
  scheming: '0',
  spirit: '0',
  specialAttr: '0',
  specialAttrName: '',
  specialAttr2: null,
  specialAttrName2: null,
  couple: null,
  privilege: '0',
  registrationDate: '',
  comeFrom: null,
  online: false,
);

Post _post(int floor, {int page = 1, String data = 'floor', UserBriefProfile? profile, bool fromApp = false}) => Post(
  postID: '${100 + floor}',
  postFloor: floor,
  page: page,
  author: User(name: profile?.username ?? '折纸飞机', uid: '$floor', url: 'u'),
  publishTime: DateTime(2026, 11, 24, 10, 15, 28),
  data: data,
  replyAction: null,
  rateAction: null,
  lastEditUsername: null,
  lastEditTime: null,
  shareLink: null,
  isDraft: false,
  packetAllTaken: false,
  userBriefProfile: profile,
  fromApp: fromApp,
);

NormalThread _thread(int tid, String title, {String? type}) => NormalThread(
  title: title,
  url: '$baseUrl/forum.php?mod=viewthread&tid=$tid',
  threadID: '$tid',
  author: User(name: '薄荷汽水', url: '$baseUrl/home.php?mod=space&uid=${100 + tid}', uid: '${100 + tid}'),
  publishDate: DateTime(2026, 11, 23),
  latestReplyAuthor: const User(name: '雪见大福', url: ''),
  latestReplyTime: DateTime.now().subtract(const Duration(minutes: 12)),
  iconUrl: '',
  threadType: type == null ? null : ThreadType(name: type, url: '$baseUrl/forum.php?mod=forumdisplay&typeid=1'),
  replyCount: 126,
  viewCount: 34000,
  price: null,
  css: null,
  stateSet: const {},
  privilege: null,
  isRecentThread: false,
);

/// The style of the run of text [text] in the content under [tester].
TextStyle? _styleOf(WidgetTester tester, String text) {
  TextStyle? found;
  for (final paragraph in tester.renderObjectList<RenderParagraph>(
    find.descendant(of: find.byType(MunchedHtml), matching: find.byType(RichText)),
  )) {
    paragraph.text.visitChildren((span) {
      if (span is TextSpan && (span.text?.contains(text) ?? false)) {
        found = span.style;
        return false;
      }
      return true;
    });
    if (found != null) {
      break;
    }
  }
  return found;
}

Future<void> _settle(WidgetTester tester, {int rounds = 4}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void main() {
  late AppDatabase db;
  late StorageProvider storage;
  late SettingsRepository settings;
  late SettingsBloc settingsBloc;

  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  setUp(() async {
    await LocaleSettings.setLocale(AppLocale.zhTw);
    db = AppDatabase(NativeDatabase.memory());
    storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings)
      ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerSingleton<ImageCacheProvider>(
        ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _Offline())),
      );
    await settings.init();
    settingsBloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository());
  });

  tearDown(() async {
    await settingsBloc.close();
    await getIt.get<ImageCacheProvider>().dispose();
    await getIt.reset();
    await settings.dispose();
    await db.close();
    await LocaleSettings.setLocale(AppLocale.en);
  });

  void window(WidgetTester tester, Size size, {double textScale = 1}) {
    tester.view
      ..physicalSize = size
      ..devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(() {
      tester.view.reset();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });
  }

  Widget app(Widget home, {Brightness brightness = Brightness.dark}) => TranslationProvider(
    child: BlocProvider<SettingsBloc>.value(
      value: settingsBloc,
      child: Builder(
        builder: (context) => MaterialApp(
          theme: brightness == Brightness.light
              ? AppTheme.makeLight(context, seedColor: null, fontFamily: '')
              : AppTheme.makeDark(context, seedColor: null, fontFamily: ''),
          home: home,
        ),
      ),
    ),
  );

  group('1. cards', () {
    Widget floors(List<Post> posts) => BlocProvider(
      create: (_) => JumpPageCubit(),
      child: Scaffold(
        body: PostList(
          threadID: '1',
          postList: posts,
          canLoadMore: false,
          scrollController: ScrollController(),
          latestModAct: null,
          title: '同人展無料小冊的閱讀心得',
          useDivider: true,
          widgetBuilder: (_, p) => SizedBox(
            key: ValueKey('floor-${p.postID}'),
            width: double.infinity,
            height: 120,
            child: Text('post ${p.postID}'),
          ),
        ),
      ),
    );

    testWidgets('each floor is a rounded card, 6 in from the sides of a phone, 8 between floors', (tester) async {
      window(tester, const Size(390, 900));
      await tester.pumpWidget(app(floors([_post(1), _post(2)])));
      await tester.pump();
      final cards = find.byType(Card);
      expect(cards, findsNWidgets(2));
      expect(tester.getTopLeft(cards.first).dx, 6);
      expect(tester.getSize(cards.first).width, 390 - 12);
      expect(tester.getTopLeft(cards.at(1)).dy - tester.getBottomLeft(cards.first).dy, 8);
      final shape = tester.widget<Card>(cards.first).shape;
      expect(shape, isA<RoundedRectangleBorder>());
      expect((shape! as RoundedRectangleBorder).side, BorderSide.none, reason: 'no hairline: the layers tell it');
      // The title above the floors, once.
      expect(find.text('同人展無料小冊的閱讀心得'), findsOneWidget);
      expect(tester.getTopLeft(find.text('同人展無料小冊的閱讀心得')).dy, lessThan(tester.getTopLeft(cards.first).dy));
    });

    testWidgets('a wide window: the floors 16 in from the sides', (tester) async {
      window(tester, const Size(700, 900));
      await tester.pumpWidget(app(floors([_post(1)])));
      await tester.pump();
      expect(tester.getTopLeft(find.byType(Card)).dx, 16);
      expect(floorMarginOf(tester.element(find.byType(Card))), 16);
    });

    testWidgets('each row of a thread list is a card: the author over the date, the type tag at the end', (
      tester,
    ) async {
      window(tester, const Size(390, 900));
      await tester.pumpWidget(
        app(
          Scaffold(
            body: ListView(
              children: [
                NormalThreadCard(_thread(1, '【汉化】春日影 第三卷 完结', type: '汉化')),
                NormalThreadCard(_thread(2, '有没有人跟我一样，买了周边却舍不得拆封？')),
              ],
            ),
          ),
        ),
      );
      await _settle(tester);
      expect(find.descendant(of: find.byType(NormalThreadCard), matching: find.byType(Card)), findsNWidgets(2));
      final name = tester.getRect(find.text('薄荷汽水').first);
      final date = tester.getRect(find.text('2026-11-23').first);
      expect(date.top, greaterThanOrEqualTo(name.bottom - 0.5), reason: 'the date under the name');
      expect((date.left - name.left).abs(), lessThan(0.5));
      expect(tester.getRect(find.text('汉化')).left, greaterThan(name.right), reason: 'the type tag at the end');
      expect(tester.takeException(), isNull);
    });

    testWidgets('the greeting of the homepage is in a card, its four actions two by two', (tester) async {
      window(tester, const Size(390, 900));
      final checkin = CheckinBloc(
        checkinRepository: CheckinRepository(storageProvider: storage),
        authenticationRepository: _Auth(),
        settingsRepository: settings,
      );
      addTearDown(checkin.close);
      await tester.pumpWidget(
        BlocProvider<CheckinBloc>.value(
          value: checkin,
          child: app(
            const Scaffold(
              body: SingleChildScrollView(
                padding: EdgeInsets.all(12),
                child: HomeGreetingCard(
                  username: '大和啦',
                  uid: 2042122,
                  forumStatus: ForumStatus.empty(),
                  dailyRedPacket: null,
                  formHash: 'XXXXXXXX',
                  compact: true,
                ),
              ),
            ),
          ),
        ),
      );
      await _settle(tester);
      final card = find.descendant(of: find.byType(HomeGreetingCard), matching: find.byType(Card));
      expect(card, findsOneWidget);
      final tr = LocaleSettings.instance.currentTranslations;
      final checkinLabel = find.text(tr.homepage.welcome.checkin);
      final packet = find.text(tr.redPacket.daily.unavailable);
      expect(find.descendant(of: card, matching: checkinLabel), findsOneWidget);
      // Two by two: the check-in beside the red packet, the activities under the check-in.
      expect(tester.getCenter(packet).dy, closeTo(tester.getCenter(checkinLabel).dy, 4));
      final activities = find.text(tr.activitiesPage.title);
      expect(tester.getTopLeft(activities).dy, greaterThan(tester.getBottomLeft(checkinLabel).dy));
      // No packet now: an outlined button, the check-in a filled one.
      expect(find.ancestor(of: packet, matching: find.byType(OutlinedButton)), findsOneWidget);
      expect(find.ancestor(of: checkinLabel, matching: find.byType(FilledButton)), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    group('pinned groups of the desktop homepage', () {
      PinnedThread row(int tid, String title) => PinnedThread(
        threadUrl: 'forum.php?mod=viewthread&amp;tid=$tid',
        threadTitle: title,
        authorUrl: 'home.php?mod=space&amp;uid=${3000 + tid}',
        authorName: '晚风信笺',
      );
      const long = '十一月新番中期感想：哪部最让你意外？顺便聊聊下一季的期待与各种各样很长很长很长的标题';
      PinnedThreadGroup tall(String title) =>
          PinnedThreadGroup(title: title, threadList: [for (var i = 0; i < 10; i++) row(100 + i, '$long $i')]);

      for (final scale in [1.0, 1.3]) {
        testWidgets('cards, the author over a one line title; ten rows at ${scale}x stay within their card', (
          tester,
        ) async {
          window(tester, const Size(1040, 4000), textScale: scale);
          await tester.pumpWidget(
            app(
              Scaffold(
                body: Padding(
                  padding: const EdgeInsets.all(24),
                  child: SingleChildScrollView(
                    child: PinSection([tall('第一组'), tall('第二组'), tall('第三组'), tall('第四组')]),
                  ),
                ),
              ),
            ),
          );
          await tester.pump();
          expect(tester.takeException(), isNull, reason: 'nothing overflows');
          final cards = find.descendant(of: find.byType(PinSection), matching: find.byType(Card));
          expect(cards, findsNWidgets(4));
          // The title of a row is one line, under the author.
          final title = find.text('$long 0').first;
          final titleText = tester.widget<Text>(title);
          expect(titleText, isA<SingleLineText>());
          expect(titleText.maxLines, 1);
          final author = find.text('晚风信笺').first;
          expect(tester.getTopLeft(title).dy, greaterThanOrEqualTo(tester.getBottomLeft(author).dy - 0.5));
          expect(tester.getSize(title).height, lessThan(30 * scale), reason: 'one line');
          // Each card holds its ten rows; the cards of a row of groups end above the next row.
          for (var i = 0; i < 4; i++) {
            final list = tester.getRect(find.byType(PinnedThreadList).at(i));
            expect(list.bottom, lessThanOrEqualTo(tester.getRect(cards.at(i)).bottom + 0.5));
          }
          final firstRowBottom = math.max(tester.getRect(cards.at(0)).bottom, tester.getRect(cards.at(1)).bottom);
          expect(tester.getRect(cards.at(2)).top, greaterThan(firstRowBottom));
          expect(tester.getRect(cards.at(3)).top, greaterThan(firstRowBottom));
          // Side by side, the two of a row start at the same height.
          expect(tester.getRect(cards.at(1)).top, tester.getRect(cards.at(0)).top);
        });
      }
    });
  });

  group('2. kept from 1.62.0', () {
    testWidgets('the user group is a tag beside the name; under the name only the time and "from the app"', (
      tester,
    ) async {
      window(tester, const Size(390, 900));
      final post = _post(1, profile: _profile('大和啦', '超級版主'), fromApp: true);
      await tester.pumpWidget(app(Scaffold(body: SingleChildScrollView(child: PostCard(post)))));
      await _settle(tester);
      final tr = LocaleSettings.instance.currentTranslations;
      final name = tester.getRect(find.text('大和啦').first);
      final group = find.text('超級版主');
      expect(group, findsOneWidget);
      expect(tester.getRect(group).left, greaterThan(name.right));
      expect(tester.getCenter(group).dy, closeTo(name.center.dy, 2), reason: 'on the line of the name');
      // A tag: a ground of the control layer, a step above the card.
      final ground = tester
          .widgetList<DecoratedBox>(find.ancestor(of: group, matching: find.byType(DecoratedBox)))
          .map((e) => e.decoration)
          .whereType<BoxDecoration>()
          .first;
      final context = tester.element(group);
      expect(ground.color, AppSurfaces.of(context).control);
      expect(ground.color, isNot(AppSurfaces.of(context).card));
      final meta = tester.widget<Text>(find.textContaining(tr.postCard.fromApp));
      expect(meta.data, '2026-11-24 10:15:28 · ${tr.postCard.fromApp}');
      expect(meta.data, isNot(contains('超級版主')));
      // The name in the accent, as in 1.61.0.
      final nameText = tester.widget<Text>(find.text('大和啦').first);
      expect(nameText.style?.color, Theme.of(context).colorScheme.primary);
      expect(tester.takeException(), isNull);
    });

    for (final brightness in Brightness.values) {
      testWidgets('a quote is a block of the inset layer, its text 13 for the body text of 14 (${brightness.name})', (
        tester,
      ) async {
        window(tester, const Size(390, 900));
        final html = [
          '<div class="quote"><blockquote><font size="2">',
          '<a href="forum.php?mod=redirect&amp;goto=findpost&amp;pid=1&amp;ptid=2" target="_blank">',
          '<font color="#999999">大和啦 發表於 2026-11-24 10:15</font></a></font>',
          '<br />\r\nquoted words</blockquote></div><br />\r\nreply words',
        ].join();
        await tester.pumpWidget(
          app(
            Scaffold(
              body: Card(
                child: PostTypographyScope(typography: const PostTypography(), child: MunchedHtml(html)),
              ),
            ),
            brightness: brightness,
          ),
        );
        await tester.pump();
        expect(_styleOf(tester, 'reply words')?.fontSize, 14);
        expect(_styleOf(tester, 'quoted words')?.fontSize, 13);
        expect(postBodyFontSize * quoteFontScale, 13);
        final quote = find.byType(QuotedText);
        expect(quote, findsOneWidget);
        final context = tester.element(quote);
        final surfaces = AppSurfaces.of(context);
        final block = tester
            .widgetList<DecoratedBox>(find.descendant(of: quote, matching: find.byType(DecoratedBox)))
            .map((e) => e.decoration)
            .whereType<BoxDecoration>()
            .first;
        expect(block.color, surfaces.inset);
        // On the card of a floor now: the block still stands out from it.
        expect(block.color, isNot(surfaces.card));
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('3. the body text of a post', () {
    test('14, 1.7 and 8, the line of a phone 346 of text at 14', () {
      expect(postBodyFontSize, 14);
      expect(PostTypography.defaultLineHeight, 1.7);
      expect(PostTypography.defaultParagraphSpacing, 8);
      expect(phoneLineWidth, 346 / 14);
      expect(PostTypography.defaultLineWidth, phoneLineWidth);
    });

    testWidgets('a phone 390 wide: the floor 6 in, 16 of padding a side', (tester) async {
      window(tester, const Size(390, 800));
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (c) {
              context = c;
              return const SizedBox();
            },
          ),
        ),
      );
      expect(floorMarginOf(context), 6);
      expect(postContentLineWidthIn(context, 390), closeTo(346 / 14, 1e-9));
    });
  });
}
