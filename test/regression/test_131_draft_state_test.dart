import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/draft_box/cubit/draft_cubit.dart';
import 'package:tsdm_client/features/draft_box/repository/draft_repository.dart';
import 'package:tsdm_client/instance.dart';

import 'draft_fixtures.dart';

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));
  test('account switch discards a late list and erases private rows', () async {
    var uid = 1000;
    final pending = Completer<String>();
    final cubit = DraftCubit(currentUid: () => uid, repository: () => DraftRepository((_) => pending.future));
    addTearDown(cubit.close);
    final loading = cubit.load();
    uid = 1001;
    cubit.invalidate();
    pending.complete(draftList());
    await loading;
    expect(cubit.state.entries, isEmpty);
    expect(cubit.state.uid, isNull);
  });
  test('newer refresh wins even when older request finishes last', () async {
    final first = Completer<String>();
    var count = 0;
    final cubit = DraftCubit(
      currentUid: () => 1000,
      repository: () => DraftRepository((_) => ++count == 1 ? first.future : Future.value(draftList(tid: '124'))),
    );
    addTearDown(cubit.close);
    final older = cubit.load();
    await cubit.load();
    first.complete(draftList());
    await older;
    expect(cubit.state.entries.single.tid, '124');
  });
  test('page failure preserves rows and retry deduplicates overlapping pages', () async {
    var fail = true;
    final cubit = DraftCubit(
      currentUid: () => 1000,
      repository: () => DraftRepository((url) async {
        if (Uri.parse(url).queryParameters['page'] == '1') return draftList(next: 2);
        if (fail) throw StateError('synthetic network failure');
        return draftList();
      }),
    );
    addTearDown(cubit.close);
    await cubit.load();
    await cubit.load(more: true);
    expect(cubit.state.entries.length, 1);
    expect(cubit.state.nextPage, 2);
    expect(cubit.state.failed, isTrue);
    fail = false;
    await cubit.load(more: true);
    expect(cubit.state.entries.length, 1);
    expect(cubit.state.nextPage, isNull);
    expect(cubit.state.failed, isFalse);
  });
  test('late open cannot return another account private edit target', () async {
    var uid = 1000;
    final pending = Completer<String>();
    final urls = <String>[];
    final cubit = DraftCubit(
      currentUid: () => uid,
      repository: () => DraftRepository((url) async {
        urls.add(url);
        return url.contains('home.php') ? draftList() : pending.future;
      }),
    );
    addTearDown(cubit.close);
    await cubit.load();
    final opening = cubit.open(cubit.state.entries.single);
    uid = 1001;
    cubit.invalidate();
    pending.complete(draftThread());
    expect(await opening, isNull);
    expect(urls.any((url) => url.contains('pubsave')), isFalse);
  });
  test('logged-out and mismatched server pages never expose drafts', () async {
    for (final uid in [0, 1001]) {
      final cubit = DraftCubit(
        currentUid: () => 1000,
        repository: () => DraftRepository((_) async => draftList(uid: uid)),
      );
      addTearDown(cubit.close);
      await cubit.load();
      expect(cubit.state.entries, isEmpty);
      expect(cubit.state.failed, isTrue);
    }
    final guest = DraftCubit(currentUid: () => null, repository: () => throw StateError('must not fetch'));
    addTearDown(guest.close);
    await guest.load();
    expect(guest.state.loginRequired, isTrue);
  });
}
