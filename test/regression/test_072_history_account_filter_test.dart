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

void main() {
  late AppDatabase db;
  late StorageProvider storage;
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));
  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    storage = StorageProvider(db, {}, {});
  });
  tearDown(() async => db.close());

  Future<void> save(int uid, int tid, String title) async {
    await storage.updateThreadVisitHistory(
      uid: uid,
      tid: tid,
      fid: 1,
      username: 'Same name',
      threadTitle: title,
      forumName: 'Forum',
      visitTime: DateTime(2026, 9, 10),
    );
  }

  Future<void> pump(WidgetTester tester) async {
    await tester.runAsync(() async {
      await save(11, 100, 'Account A thread');
      await save(22, 100, 'Account B thread');
    });
    await tester.pumpWidget(
      RepositoryProvider.value(
        value: ThreadVisitHistoryRepo(storage),
        child: TranslationProvider(child: const MaterialApp(home: ThreadVisitHistoryPage())),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
  }

  List<int> visibleAccounts(WidgetTester tester) =>
      tester.widgetList<ThreadVisitHistoryCard>(find.byType(ThreadVisitHistoryCard)).map((c) => c.model.uid).toList();

  Future<void> select(WidgetTester tester, String label) async {
    await tester.tap(find.byIcon(Icons.filter_list));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  testWidgets('history filter distinguishes accounts with the same name and restores all accounts', (tester) async {
    await pump(tester);
    expect(visibleAccounts(tester), containsAll([11, 22]));
    await select(tester, 'Same name (UID: 11)');
    expect(visibleAccounts(tester), [11]);
    await select(tester, 'Same name (UID: 22)');
    expect(visibleAccounts(tester), [22]);
    await select(tester, 'All accounts');
    expect(visibleAccounts(tester), containsAll([11, 22]));
    expect(tester.takeException(), isNull);
  });

  testWidgets('refresh retains account filter while loading new records', (tester) async {
    await pump(tester);
    await select(tester, 'Same name (UID: 11)');
    await tester.runAsync(() => save(11, 101, 'New A thread'));
    final bloc = tester.element(find.byType(ThreadVisitHistoryCard).first).read<ThreadVisitHistoryBloc>();
    bloc.add(const ThreadVisitHistoryFetchAllRequested());
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    expect(visibleAccounts(tester), [11, 11]);
    expect(find.text('New A thread'), findsOneWidget);
  });
}
