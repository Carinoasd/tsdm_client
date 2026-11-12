/// A visit record the storage did not save is not shown as saved.
///
/// The bloc of the thread visit history ignored how the save went: an error of the storage (a full disk, a locked
/// database) was thrown out of the handler, the bloc stayed "saving" and the next update put the record in its list
/// all the same, while the storage still held the old one. The record is now changed in the list only once saved; a
/// failed save is logged and the state says it failed, with the list as stored. The list of the state before is no
/// more changed in place.
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/thread_visit_history/bloc/thread_visit_history_bloc.dart';
import 'package:tsdm_client/features/thread_visit_history/repository/thread_visit_history_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

ThreadVisitHistoryModel _visit(String title, DateTime time) => ThreadVisitHistoryModel(
  uid: 31,
  username: 'tester',
  threadId: 1140,
  threadTitle: title,
  forumId: 2,
  forumName: 'forum',
  visitTime: time,
);

void main() {
  late AppDatabase db;
  late ThreadVisitHistoryBloc bloc;

  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    final storage = StorageProvider(db, {}, {});
    final first = _visit('first title', DateTime(2026, 11, 13, 10));
    await storage.updateThreadVisitHistory(
      uid: first.uid,
      tid: first.threadId,
      fid: first.forumId,
      username: first.username,
      threadTitle: first.threadTitle,
      forumName: first.forumName,
      visitTime: first.visitTime,
    );
    bloc = ThreadVisitHistoryBloc(ThreadVisitHistoryRepo(storage))..add(const ThreadVisitHistoryFetchAllRequested());
    await bloc.stream.firstWhere((s) => s.status == ThreadVisitHistoryStatus.success);
  });

  tearDown(() async {
    await bloc.close();
    await db.close();
  });

  Future<ThreadVisitHistoryState> update(ThreadVisitHistoryModel model) async {
    final done = bloc.stream.firstWhere(
      (s) => s.status == ThreadVisitHistoryStatus.success || s.status == ThreadVisitHistoryStatus.failure,
    );
    bloc.add(ThreadVisitHistoryUpdateRequested(model));
    return done.timeout(const Duration(seconds: 5));
  }

  test('saved: the record in the list is the new one, the list before is not changed', () async {
    final before = bloc.state.history;
    final state = await update(_visit('second title', DateTime(2026, 11, 13, 11)));
    expect(state.status, ThreadVisitHistoryStatus.success);
    expect(state.history.single.threadTitle, 'second title');
    expect(before.single.threadTitle, 'first title', reason: 'the list of the state before was changed in place');
  });

  test('not saved: the state says so, the list stays as stored', () async {
    // Every write of a visit fails from here on, as on a full disk.
    await db.customStatement(
      'CREATE TRIGGER fail_insert BEFORE INSERT ON thread_visit_history BEGIN SELECT RAISE(ABORT, "disk full"); END',
    );
    await db.customStatement(
      'CREATE TRIGGER fail_update BEFORE UPDATE ON thread_visit_history BEGIN SELECT RAISE(ABORT, "disk full"); END',
    );
    final state = await update(_visit('second title', DateTime(2026, 11, 13, 11)));
    expect(state.status, ThreadVisitHistoryStatus.failure, reason: 'it stayed "saving", the error thrown away');
    expect(state.history.single.threadTitle, 'first title');

    // The next save that works is shown again.
    await db.customStatement('DROP TRIGGER fail_insert');
    await db.customStatement('DROP TRIGGER fail_update');
    final saved = await update(_visit('third title', DateTime(2026, 11, 13, 12)));
    expect(saved.status, ThreadVisitHistoryStatus.success);
    expect(saved.history.single.threadTitle, 'third title');
  });
}
