/// Filtering the lists kept on the device, and what the quick open box matches with the same folding.
///
/// * Words are compared in any case and in simplified characters ([foldForSearch]): typed either way, a text written
///   either way is found. Every word must be there, each may be in another field; nothing typed filters nothing.
/// * [ListFilterAppBar]: the title and a search button; the field instead once tapped; back (the bar's, the system's)
///   closes the field and lists everything again. [ListFilterNoMatch] is not the empty list's message.
/// * The quick open box lists the threads put aside and the floors bookmarked too; a thread put aside is not listed
///   again as one visited; its words are folded the same way.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/floor_bookmark/models/floor_bookmark.dart';
import 'package:tsdm_client/features/quick_open/models/quick_open_candidate.dart';
import 'package:tsdm_client/features/quick_open/repository/quick_open_sources_loader.dart';
import 'package:tsdm_client/features/quick_open/utils/quick_open_search.dart';
import 'package:tsdm_client/features/read_later/cubit/read_later_cubit.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_converter.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_display.dart';
import 'package:tsdm_client/utils/local_filter.dart';
import 'package:tsdm_client/widgets/list_filter.dart';

Translations get tr => LocaleSettings.instance.currentTranslations;

/// The dictionary the app ships.
ChineseConverter _t2s() => ChineseConverter.parse(File(chineseDisplayT2sAsset).readAsStringSync());

const _threads = ['收藏的帖子', '樓層書籤 Notes', 'Read LATER list', '簡體與繁體'];

/// A page listing [_threads] through a filter, as the pages of the app do.
class _Page extends StatelessWidget {
  const _Page();

  @override
  Widget build(BuildContext context) => ListFilterHost(
    builder: (context, filter) {
      final items = _threads.where((e) => filter.matches([e])).toList();
      return Scaffold(
        appBar: ListFilterAppBar(
          controller: filter,
          title: 'the list',
          actions: [IconButton(key: const ValueKey('own-action'), icon: const Icon(Icons.sync), onPressed: () {})],
        ),
        body: items.isEmpty
            ? ListFilterNoMatch(filter.query)
            : ListView(children: [for (final item in items) ListTile(title: Text(item))]),
      );
    },
  );
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.zhTw);
  });

  tearDown(ChineseDisplay.instance.useConverters);

  group('the words', () {
    test('without the dictionary: any case, every word, each in any field', () {
      ChineseDisplay.instance.useConverters();
      expect(searchTokens('  Read   LATER '), ['read', 'later']);
      expect(searchTokens('   '), isEmpty);
      expect(matchesSearch(searchTokens('later READ'), ['Read LATER list']), isTrue);
      expect(matchesSearch(searchTokens('read bob'), ['Read later', 'Bob']), isTrue, reason: 'a word per field');
      expect(matchesSearch(searchTokens('read carol'), ['Read later', 'Bob']), isFalse, reason: 'every word');
      expect(matchesSearch(searchTokens('read'), [null, '']), isFalse);
      expect(matchesSearch(const [], ['anything']), isTrue, reason: 'nothing typed filters nothing');
      // Written as it is typed still fits; the other writing does not, yet.
      expect(matchesSearch(searchTokens('書籤'), ['樓層書籤']), isTrue);
      expect(matchesSearch(searchTokens('书签'), ['樓層書籤']), isFalse);
    });

    test('with the dictionary: simplified and traditional find each other', () {
      ChineseDisplay.instance.useConverters(t2s: _t2s());
      expect(foldForSearch('樓層書籤 Notes'), '楼层书签 notes');
      expect(matchesSearch(searchTokens('书签'), ['樓層書籤']), isTrue, reason: 'typed simplified, written traditional');
      expect(matchesSearch(searchTokens('書籤'), ['楼层书签']), isTrue, reason: 'typed traditional, written simplified');
      expect(matchesSearch(searchTokens('書籤 notes'), ['楼层书签', 'My NOTES']), isTrue);
      expect(matchesSearch(searchTokens('收藏'), ['樓層書籤']), isFalse);
    });

    testWidgets('the dictionary of the app is loaded on demand, and never fails the search', (tester) async {
      ChineseDisplay.instance.useConverters();
      expect(ChineseDisplay.instance.isReady(ChineseDisplayMode.simplified), isFalse);
      await tester.runAsync(ensureSearchFolding);
      expect(ChineseDisplay.instance.isReady(ChineseDisplayMode.simplified), isTrue);
      expect(matchesSearch(searchTokens('书签'), ['樓層書籤']), isTrue);
    });
  });

  test('the dictionary arriving after the page was left changes nothing and does not throw', () async {
    ChineseDisplay.instance.useConverters();
    final filter = ListFilterController();
    var told = 0;
    filter
      ..addListener(() => told++)
      ..show()
      ..edited('书签');
    expect(told, 2);
    // Left while the dictionary is still loading.
    filter.dispose();
    await ensureSearchFolding();
    await Future<void>.delayed(Duration.zero);
    expect(told, 2, reason: 'no listener told after the controller is gone');
  });

  group('the app bar', () {
    Future<void> pump(WidgetTester tester) async {
      ChineseDisplay.instance.useConverters(t2s: _t2s());
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const _Page())),
                    child: const Text('open the page'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open the page'));
      await tester.pumpAndSettle();
    }

    final open = find.byKey(const ValueKey('list-filter-open'));
    final field = find.byKey(const ValueKey('list-filter-field'));
    final noMatch = find.byKey(const ValueKey('list-filter-no-match'));

    testWidgets('the title and the button; the field once tapped; typing filters as it is typed', (tester) async {
      await pump(tester);
      expect(find.text('the list'), findsOneWidget);
      expect(field, findsNothing);
      expect(find.byKey(const ValueKey('own-action')), findsOneWidget);
      expect(find.byType(ListTile), findsNWidgets(4));
      expect(tester.widget<IconButton>(open).tooltip, tr.listFilter.open);

      await tester.tap(open);
      await tester.pumpAndSettle();
      expect(field, findsOneWidget);
      expect(find.text('the list'), findsNothing);
      expect(find.byKey(const ValueKey('own-action')), findsNothing, reason: 'the field has the bar');
      expect(find.byType(ListTile), findsNWidgets(4), reason: 'nothing typed yet');

      await tester.enterText(field, 'later');
      await tester.pump();
      expect(find.byType(ListTile), findsOneWidget);
      expect(find.text('Read LATER list'), findsOneWidget);

      // Simplified typed, traditional listed.
      await tester.enterText(field, '书签 notes');
      await tester.pump();
      expect(find.text('樓層書籤 Notes'), findsOneWidget);
      expect(find.byType(ListTile), findsOneWidget);
    });

    testWidgets('nothing fits: said with the words typed; clearing lists everything again', (tester) async {
      await pump(tester);
      await tester.tap(open);
      await tester.pumpAndSettle();
      await tester.enterText(field, 'zzzz');
      await tester.pump();
      expect(noMatch, findsOneWidget);
      expect(find.text(tr.listFilter.noMatch(query: 'zzzz')), findsOneWidget);
      expect(find.byType(ListTile), findsNothing);

      await tester.tap(find.byKey(const ValueKey('list-filter-clear')));
      await tester.pump();
      expect(noMatch, findsNothing);
      expect(find.byType(ListTile), findsNWidgets(4));
      expect(field, findsOneWidget, reason: 'the field stays for other words');
    });

    testWidgets("back closes the field first (the bar's and the system's), then the page", (tester) async {
      await pump(tester);
      await tester.tap(open);
      await tester.pumpAndSettle();
      await tester.enterText(field, 'later');
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('list-filter-close')));
      await tester.pumpAndSettle();
      expect(field, findsNothing);
      expect(find.text('the list'), findsOneWidget);
      expect(find.byType(ListTile), findsNWidgets(4), reason: 'everything listed again');

      await tester.tap(open);
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(field, findsNothing, reason: 'the system back closed the field');
      expect(find.text('the list'), findsOneWidget, reason: 'the page is still there');

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('the list'), findsNothing, reason: 'now the page is left');
      expect(find.text('open the page'), findsOneWidget);
    });
  });

  group('the quick open box', () {
    const sources = QuickOpenSources(
      threads: [(tid: 1, title: '樓層書籤的用法'), (tid: 2, title: 'visited only')],
      readLater: [(tid: 1, title: '樓層書籤的用法'), (tid: 3, title: 'put aside')],
      bookmarks: [
        (pid: 501, title: '樓層書籤的用法', note: '重點在這', floor: 12),
        (pid: 502, title: 'other thread', note: '', floor: null),
      ],
    );

    List<QuickOpenCandidate> of(String text, QuickOpenKind kind) =>
        buildQuickOpenCandidates(text, sources).where((e) => e.kind == kind).toList();

    test('threads put aside and floors bookmarked are listed; a thread put aside not again as visited', () {
      ChineseDisplay.instance.useConverters();
      final aside = of('書籤', QuickOpenKind.readLater);
      expect(aside.map((e) => e.title), ['樓層書籤的用法']);
      expect(aside.single.route.screenPath, ScreenPaths.threadV1);
      expect(aside.single.route.queryParameters, {'tid': '1'});
      expect(of('書籤', QuickOpenKind.thread), isEmpty, reason: 'the same thread, listed once');
      expect(of('visited', QuickOpenKind.thread).map((e) => e.title), ['visited only']);
      expect(of('aside', QuickOpenKind.readLater).single.route.queryParameters, {'tid': '3'});

      final marks = of('書籤', QuickOpenKind.bookmark);
      expect(marks.single.title, '樓層書籤的用法 #12 重點在這');
      expect(marks.single.route.queryParameters, {'pid': '501', 'appBarTitle': '樓層書籤的用法'});
      expect(of('重點', QuickOpenKind.bookmark), hasLength(1), reason: 'by the note');
      expect(of('other', QuickOpenKind.bookmark).single.title, 'other thread');
    });

    test('folded as the lists are: simplified typed finds traditional titles', () {
      ChineseDisplay.instance.useConverters();
      expect(of('书签', QuickOpenKind.readLater), isEmpty);
      ChineseDisplay.instance.useConverters(t2s: _t2s());
      expect(of('书签', QuickOpenKind.readLater), hasLength(1));
      expect(of('重点', QuickOpenKind.bookmark), hasLength(1));
      expect(matchScore('樓層書籤', searchTokens('楼层书签')), 0, reason: 'the whole text, written the other way');
    });

    test('what the lists hold is handed over as the box needs it', () {
      final later = quickOpenReadLaterOf([
        ReadLaterItem(tid: 9, title: 'nine', addedAt: DateTime(2026)),
        ReadLaterItem(tid: 8, title: '', addedAt: DateTime(2026)),
      ]);
      expect(later, [(tid: 9, title: 'nine')]);
      final marks = quickOpenBookmarksOf([
        FloorBookmark(tid: 9, pid: 105, updated: 1, floor: 5, threadTitle: 'a thread', note: 'a note'),
        FloorBookmark(tid: 9, pid: 107, updated: 1),
      ]);
      expect(marks, [(pid: 105, title: 'a thread', note: 'a note', floor: 5)]);
    });
  });
}
