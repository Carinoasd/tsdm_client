import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

class _Storage extends Fake implements StorageProvider {
  final rows = <String, List<String>>{};
  bool failReads = false;
  int writes = 0;
  Completer<List<String>?>? firstRead;
  int reads = 0;

  @override
  Future<List<String>?> getStringList(String key) async {
    if (++reads == 1 && firstRead != null) return firstRead!.future;
    if (failReads) throw StateError('disk unavailable');
    return rows[key] == null ? null : List.of(rows[key]!);
  }

  @override
  Future<void> saveStringList(String key, List<String> value) async {
    writes++;
    rows[key] = List.of(value);
  }

  @override
  Future<void> deleteKey(String key) async {
    writes++;
    rows.remove(key);
  }
}

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init();
  });

  test('failed storage read cannot overwrite existing silent block list', () async {
    final storage = _Storage();
    final repo = UserBlockRepository(storage);
    await repo.block(ownerUid: 10, uid: 20, username: 'First');
    final before = List<String>.of(storage.rows[UserBlockRepository.keyOf(10)]!);
    storage.failReads = true;
    final writesBefore = storage.writes;
    try {
      await repo.block(ownerUid: 10, uid: 30, username: 'Second');
    } on Object {
      // An error is acceptable; overwriting a list that could not be read is not.
    }
    expect(storage.writes, writesBefore);
    expect(storage.rows[UserBlockRepository.keyOf(10)], before);
    await repo.dispose();
  });

  test('watch does not miss a block saved while its initial read is pending', () async {
    final storage = _Storage()..firstRead = Completer<List<String>?>();
    final repo = UserBlockRepository(storage);
    final seen = <UserBlockList>[];
    final sub = repo.watch(10).listen(seen.add);
    await Future<void>.delayed(Duration.zero);
    await repo.block(ownerUid: 10, uid: 20, username: 'First');
    storage.firstRead!.complete(const []);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(seen.last.uids, {20});
    await sub.cancel();
    await repo.dispose();
  });
  test('same-name users and separate accounts remain independent across reload', () async {
    final storage = _Storage();
    final repo = UserBlockRepository(storage);
    await repo.block(ownerUid: 10, uid: 20, username: 'Same');
    await repo.block(ownerUid: 11, uid: 30, username: 'Same');
    final reopened = UserBlockRepository(storage);
    expect((await reopened.load(10)).uids, {20});
    expect((await reopened.load(11)).uids, {30});
    await repo.unblock(ownerUid: 10, uid: 20);
    expect((await reopened.load(11)).uids, {30});
    await repo.dispose();
    await reopened.dispose();
  });
}
