/// The thread page of the second beautify round (tokens-v2, items 2, 6b, 9, 11 and the floor header):
///
/// * the floors are flat on the page: no card, the whole width on a phone, a hairline of the `line` layer between
///   them (none above the floor a page divider begins);
/// * the body text of a post is 16 (the theme's body text, 14, elsewhere), a quote's text a step smaller (15), and the
///   line width and the long paragraphs follow it (358 of text on a phone 390 wide);
/// * the line height and the paragraph spacing default to 1.8 and 10, for a reader who never set them only;
/// * the header of a floor: the name neutral, the user group a tag beside it, the floor number quiet and without a
///   ground;
/// * the title area: a kicker of the forums (the thread's own forum stressed), the title, a line of the thread's
///   figures with the thread id at its end, which still opens the copy dialog.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/forum/models/models.dart';
import 'package:tsdm_client/features/jump_page/cubit/jump_page_cubit.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/thread/v1/bloc/thread_bloc.dart';
import 'package:tsdm_client/features/thread/v1/models/models.dart';
import 'package:tsdm_client/features/thread/v1/widgets/post_list.dart';
import 'package:tsdm_client/features/thread/v1/widgets/thread_title_header.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/themes/app_surfaces.dart';
import 'package:tsdm_client/utils/html/post_typography.dart';
import 'package:tsdm_client/utils/html/sentence_breaks.dart';
import 'package:tsdm_client/widgets/munched_html.dart';

Post _post(int floor, {int page = 1}) => Post(
  postID: '${100 + floor}',
  postFloor: floor,
  page: page,
  author: User(name: 'author$floor', uid: '$floor', url: 'u'),
  publishTime: DateTime(2026, 11, 24),
  data: 'floor $floor',
  replyAction: null,
  rateAction: null,
  lastEditUsername: null,
  lastEditTime: null,
  shareLink: null,
  isDraft: false,
  packetAllTaken: false,
);

Widget _floors(List<Post> posts, {ThemeData? theme}) => BlocProvider(
  create: (_) => JumpPageCubit(),
  child: MaterialApp(
    theme: theme,
    home: Scaffold(
      body: PostList(
        threadID: '1',
        postList: posts,
        canLoadMore: false,
        scrollController: ScrollController(),
        latestModAct: null,
        title: 'title',
        useDivider: true,
        widgetBuilder: (_, p) => SizedBox(
          key: ValueKey('floor-${p.postID}'),
          width: double.infinity,
          height: 120,
          child: Text('post ${p.postID}'),
        ),
      ),
    ),
  ),
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

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  group('1. flat floors', () {
    testWidgets('no card around a floor, a hairline of the line layer between floors', (tester) async {
      tester.view.physicalSize = const Size(390, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final theme = ThemeData(extensions: [AppSurfaces.forSeed(Colors.teal, Brightness.light)]);
      await tester.pumpWidget(_floors([_post(1), _post(2), _post(3, page: 2)], theme: theme));
      await tester.pump();
      expect(find.byType(Card), findsNothing, reason: 'the floors are flat');
      // The whole width on a phone.
      expect(tester.getSize(find.byKey(const ValueKey('floor-101'))).width, 390);
      expect(tester.getTopLeft(find.byKey(const ValueKey('floor-101'))).dx, 0);

      final line = AppSurfaces.ofTheme(theme).line;
      final lines = tester
          .widgetList<DecoratedBox>(find.byType(DecoratedBox))
          .map((e) => e.decoration)
          .whereType<BoxDecoration>()
          .where((e) => e.border is Border && (e.border! as Border).top.color == line);
      expect(lines.length, 2, reason: 'above the floors 1 and 2; floor 3 begins page 2, its divider parts it');
      expect(find.byKey(const ValueKey('thread-page-divider-2')), findsOneWidget);
    });

    testWidgets('a wide window: the floors 8 in from the sides', (tester) async {
      tester.view.physicalSize = const Size(960, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_floors([_post(1)]));
      await tester.pump();
      expect(find.byType(Card), findsNothing);
      // At most the reading width, centred.
      expect(tester.getSize(find.byKey(const ValueKey('floor-101'))).width, 920);
    });
  });

  group('2. the body text of a post', () {
    testWidgets('16 in a post, 15 in its quote, the theme body text outside a post', (tester) async {
      const html =
          '<div class="quote"><blockquote>quoted words</blockquote></div><br />\r\n'
          'reply words';
      Future<void> pump(Widget child) async {
        await tester.pumpWidget(
          TranslationProvider(
            child: MaterialApp(
              home: Scaffold(body: SingleChildScrollView(child: child)),
            ),
          ),
        );
        await tester.pump();
      }

      await pump(const PostTypographyScope(typography: PostTypography(), child: MunchedHtml(html)));
      expect(_styleOf(tester, 'reply words')?.fontSize, postBodyFontSize);
      expect(_styleOf(tester, 'quoted words')?.fontSize, postBodyFontSize * quoteFontScale);
      expect(postBodyFontSize * quoteFontScale, 15);

      await pump(const MunchedHtml(html));
      final body = Theme.of(tester.element(find.byType(MunchedHtml))).textTheme.bodyMedium!.fontSize;
      expect(body, 14);
      expect(_styleOf(tester, 'reply words')?.fontSize ?? body, body, reason: 'a notice keeps the body text');
    });

    testWidgets('a line of a phone 390 wide holds 358 of text at 16', (tester) async {
      tester.view.physicalSize = const Size(390, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
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
      expect(floorMarginOf(context), 0);
      expect(postContentLineWidthIn(context, 390), closeTo(358 / 16, 1e-9));
      expect(phoneLineWidth, 358 / 16);
      expect(PostTypography.defaultLineWidth, phoneLineWidth);
    });
  });

  group('3. the line height and paragraph spacing defaults', () {
    late AppDatabase db;
    late SettingsRepository settings;
    late StorageProvider storage;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
    });
    tearDown(() async {
      await settings.dispose();
      await db.close();
    });

    test('1.8 and 10 for a reader who never set them', () async {
      expect(PostTypography.defaultLineHeight, 1.8);
      expect(PostTypography.defaultParagraphSpacing, 10);
      await settings.init();
      expect(settings.currentSettings.threadContentLineHeight, 1.8);
      expect(settings.currentSettings.threadContentParagraphSpacing, 10);
    });

    test('what a reader set stays, the old defaults too', () async {
      await storage.saveDouble(SettingsKeys.threadContentLineHeight.name, 1.7);
      await storage.saveDouble(SettingsKeys.threadContentParagraphSpacing.name, 8);
      await settings.init();
      expect(settings.currentSettings.threadContentLineHeight, 1.7);
      expect(settings.currentSettings.threadContentParagraphSpacing, 8);
    });
  });

  group('4. the title area', () {
    final state = ThreadState(
      tid: '9203680',
      title: 'the title',
      fid: 8,
      viewCount: 66,
      replyCount: 58,
      threadType: const FilterType(name: 'type', typeID: '12'),
      breadcrumbs: [
        ThreadBreadcrumb(description: 'group', link: Uri.parse('https://forum.test/forum.php?gid=1')),
        ThreadBreadcrumb(description: 'forum', link: Uri.parse('https://forum.test/forum.php?mod=forumdisplay&fid=8')),
      ],
    );

    testWidgets('kicker, title and a line of figures; the id opens the copy dialog', (tester) async {
      // Wide enough for the figures and the id on one line in the test font.
      tester.view.physicalSize = const Size(800, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var tapped = 0;
      final theme = ThemeData(colorSchemeSeed: Colors.teal);
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            theme: theme,
            home: Scaffold(
              body: ThreadTitleHeader(state: state, title: 'the title', replied: true, onTapId: () => tapped++),
            ),
          ),
        ),
      );
      final tr = t.threadPage;
      expect(find.text('group'), findsOneWidget);
      final forum = tester.widget<Text>(find.text('forum'));
      expect(forum.style?.color, theme.colorScheme.primary, reason: 'the forum the thread is in is stressed');
      expect(forum.style?.fontWeight, FontWeight.bold);
      expect(tester.widget<Text>(find.text('group')).style?.color, isNot(theme.colorScheme.primary));
      expect(find.text('the title'), findsOneWidget);
      expect(tester.widget<Text>(find.text('the title')).style?.fontSize, 28, reason: 'larger on a wide window');
      expect(find.text(tr.statistics(view: 66, reply: 58)), findsOneWidget);
      expect(find.text(tr.repliedMark), findsOneWidget);
      expect(find.byKey(const ValueKey('thread-header-type')), findsOneWidget);
      expect(find.text('${tr.title} 9203680'), findsOneWidget);
      // The figures and the id on one line, the id at its end.
      expect(
        tester.getCenter(find.text('${tr.title} 9203680')).dy,
        closeTo(tester.getCenter(find.text(tr.statistics(view: 66, reply: 58))).dy, 1),
      );
      expect(tester.getTopRight(find.byKey(const ValueKey('thread-header-tid'))).dx, 800);
      expect(tester.getSize(find.byKey(const ValueKey('thread-header-tid'))).height, greaterThanOrEqualTo(48));
      await tester.tap(find.byKey(const ValueKey('thread-header-tid')));
      expect(tapped, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('text 1.3 times larger: nothing overflows', (tester) async {
      tester.view.physicalSize = const Size(390, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: MediaQuery(
              data: const MediaQueryData(size: Size(390, 800), textScaler: TextScaler.linear(1.3)),
              child: Scaffold(
                body: ThreadTitleHeader(state: state, title: 'the title', replied: true, onTapId: () {}),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    });
  });
}
