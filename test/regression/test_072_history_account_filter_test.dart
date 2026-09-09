import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/thread_visit_history/bloc/thread_visit_history_bloc.dart';
import 'package:tsdm_client/features/thread_visit_history/repository/thread_visit_history_repository.dart';
import 'package:tsdm_client/features/thread_visit_history/view/thread_visit_history_page.dart';
import 'package:tsdm_client/features/thread_visit_history/widgets/thread_visit_history_card.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

/// GitHub #19: the browsing history page filters the records by account, "All accounts" stays available, the choice
/// survives a refresh and accounts with the same name are told apart by uid.
void main() {
  late AppDatabase db;
  late StorageProvider storage;
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));
  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    storage = StorageProvider(db, {}, {});
  });
  tearDown(() async => db.close());

  Future<void> save(int uid, int tid, String title, {String username = 'Same name', DateTime? visitTime}) async {
    await storage.updateThreadVisitHistory(
      uid: uid,
      tid: tid,
      fid: 1,
      username: username,
      threadTitle: title,
      forumName: 'Forum',
      visitTime: visitTime ?? DateTime(2026, 9, 10),
    );
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
  }

  Future<void> pump(WidgetTester tester, {bool seed = true}) async {
    if (seed) {
      await tester.runAsync(() async {
        await save(11, 100, 'Account A thread', visitTime: DateTime(2026, 9, 10, 8));
        await save(22, 100, 'Account B thread', visitTime: DateTime(2026, 9, 10, 9));
        await save(33, 101, 'Account C thread', username: 'Other name', visitTime: DateTime(2026, 9, 10, 7));
      });
    }
    await tester.pumpWidget(
      RepositoryProvider.value(
        value: ThreadVisitHistoryRepo(storage),
        child: TranslationProvider(child: const MaterialApp(home: ThreadVisitHistoryPage())),
      ),
    );
    await settle(tester);
  }

  List<int> visibleAccounts(WidgetTester tester) =>
      tester.widgetList<ThreadVisitHistoryCard>(find.byType(ThreadVisitHistoryCard)).map((c) => c.model.uid).toList();

  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(find.byType(ActionChip));
    await tester.pumpAndSettle();
  }

  Finder inMenu(String text) => find.descendant(of: find.byType(CheckedPopupMenuItem<int>), matching: find.text(text));

  /// The whole menu item holding [text]: the item's list tile ignores pointers, so tapping the text would only warn.
  Finder menuItem(String text) => find.ancestor(of: inMenu(text), matching: find.byType(CheckedPopupMenuItem<int>));

  Future<void> select(WidgetTester tester, String label) async {
    await openMenu(tester);
    await tester.tap(menuItem(label));
    await tester.pumpAndSettle();
  }

  Finder onChip(String text) => find.descendant(of: find.byType(ActionChip), matching: find.text(text));

  List<int> checkedValues(WidgetTester tester) => tester
      .widgetList<CheckedPopupMenuItem<int>>(find.byType(CheckedPopupMenuItem<int>))
      .where((e) => e.checked)
      .map((e) => e.value!)
      .toList();

  testWidgets('the menu lists every account once with its uid, checked item follows the choice', (tester) async {
    await pump(tester);
    expect(visibleAccounts(tester), [22, 11, 33]);
    // The chip shows "all accounts" and no uid until a name collides in the choice.
    expect(onChip('All accounts'), findsOneWidget);
    await openMenu(tester);
    expect(find.byType(CheckedPopupMenuItem<int>), findsNWidgets(4));
    expect(inMenu('UID 11'), findsOneWidget);
    expect(inMenu('UID 22'), findsOneWidget);
    expect(inMenu('UID 33'), findsOneWidget);
    expect(inMenu('Same name'), findsNWidgets(2));
    expect(inMenu('Other name'), findsOneWidget);
    expect(checkedValues(tester), [-1]);
    await tester.tap(menuItem('UID 11'));
    await tester.pumpAndSettle();
    expect(visibleAccounts(tester), [11]);
    // Same name as account 22: the chip carries the uid so the choice is unambiguous.
    expect(onChip('Same name (UID 11)'), findsOneWidget);
    await openMenu(tester);
    expect(checkedValues(tester), [11]);
    await tester.tap(menuItem('Other name'));
    await tester.pumpAndSettle();
    expect(visibleAccounts(tester), [33]);
    // A unique name needs no uid on the chip.
    expect(onChip('Other name'), findsOneWidget);
    await select(tester, 'All accounts');
    expect(visibleAccounts(tester), [22, 11, 33]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('refresh keeps the account filter and shows new records of that account', (tester) async {
    await pump(tester);
    await select(tester, 'UID 11');
    await tester.runAsync(() => save(11, 101, 'New A thread', visitTime: DateTime(2026, 9, 10, 10)));
    tester
        .element(find.byType(ThreadVisitHistoryCard).first)
        .read<ThreadVisitHistoryBloc>()
        .add(const ThreadVisitHistoryFetchAllRequested());
    await tester.pump();
    await settle(tester);
    expect(visibleAccounts(tester), [11, 11]);
    expect(find.text('New A thread'), findsOneWidget);
    expect(onChip('Same name (UID 11)'), findsOneWidget);
  });

  testWidgets('an account whose records are gone stays selected and shows the empty hint', (tester) async {
    await pump(tester);
    await select(tester, 'Other name');
    expect(visibleAccounts(tester), [33]);
    tester
        .element(find.byType(ThreadVisitHistoryCard).first)
        .read<ThreadVisitHistoryBloc>()
        .add(const ThreadVisitHistoryDeleteRecordRequested(uid: 33, tid: 101));
    await tester.pump();
    await settle(tester);
    expect(find.byType(ThreadVisitHistoryCard), findsNothing);
    expect(find.text('No browsing history for this account'), findsOneWidget);
    expect(onChip('Other name'), findsOneWidget);
    // The account is still offered in the menu so the user can see what is filtered.
    await openMenu(tester);
    expect(inMenu('UID 33'), findsOneWidget);
    await tester.tap(menuItem('All accounts'));
    await tester.pumpAndSettle();
    expect(visibleAccounts(tester), [22, 11]);
  });

  testWidgets('no records at all: the empty hint and only the "all accounts" entry', (tester) async {
    await pump(tester, seed: false);
    expect(find.text('No browsing history yet'), findsOneWidget);
    await openMenu(tester);
    expect(find.byType(CheckedPopupMenuItem<int>), findsOneWidget);
  });
}
