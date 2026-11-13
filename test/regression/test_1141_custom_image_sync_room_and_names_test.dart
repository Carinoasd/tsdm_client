/// The saved images ("my images") of the cross-device sync, after 1.57.1:
///
/// * the budget: 100 images of usual addresses and short names go with the sync; the latest within the budget of a
///   version before `custom_images_more` stay in `custom_images` (that version finds the section as it would fit it and
///   writes nothing back), the others in `custom_images_more`, read as one; a deletion reaches the other device from
///   either;
/// * the time of a name apart from the time of a save: an image saved again on one device keeps the name given since
///   on the other, a later name wins whichever device saved later, a deletion still wins over an earlier save; an
///   item of a version that writes no `named` reads as named when saved; the app's storage keeps the time of a name
///   through a save again, drops it with a rename or a deletion.
///
/// Synthetic data, no real account or forum.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/editor/utils/custom_image_sync.dart';
import 'package:tsdm_client/features/sync/models/sync_document.dart';
import 'package:tsdm_client/features/sync/models/sync_removals.dart';
import 'package:tsdm_client/features/sync/repository/sync_api.dart';
import 'package:tsdm_client/features/sync/repository/sync_local_store.dart';
import 'package:tsdm_client/features/sync/repository/sync_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

const _uid = 31;

/// The device clock of the tests (milliseconds, whole seconds).
const _t = 1700000000000;

String _url(int n) => 'https://forum.test/data/attachment/forum/202611/13/image_$n.png';

/// An address as long as the usual ones of images uploaded to the forum (85 characters).
String _usualUrl(int n) => 'https://www.forum.test/data/attachment/forum/202611/13/${100000 + n}abcdefghijklmnop.png';

final class _Forum {
  int updated = 0;
  String? data;

  Map<String, dynamic> get doc => data == null ? const {} : jsonDecode(data!) as Map<String, dynamic>;

  Map<String, Map<String, dynamic>> items(String section) => SyncDocument.parse(data).items(section);

  void write(Map<String, dynamic> doc) {
    updated++;
    data = jsonEncode(doc);
  }
}

final class _Api implements SyncApi {
  _Api(this.forum);

  final _Forum forum;
  int pushes = 0;
  int conflicts = 0;
  Future<void> Function()? afterPull;

  @override
  Future<SyncPullAnswer> pull(int uid) async {
    final answer = SyncPulled(updated: forum.updated, data: forum.data, formhash: 'f1f2f3f4', uid: _uid);
    final hook = afterPull;
    afterPull = null;
    await hook?.call();
    return answer;
  }

  @override
  Future<SyncPushAnswer> push(
    int uid, {
    required String data,
    required int baseUpdated,
    required String formhash,
  }) async {
    if (baseUpdated != forum.updated) {
      conflicts++;
      return SyncConflict(updated: forum.updated, data: forum.data);
    }
    pushes++;
    forum
      ..updated += 1
      ..data = data;
    return SyncPushed(forum.updated);
  }
}

final class _Device {
  _Device(_Forum forum, this.now) : api = _Api(forum), store = MemorySyncLocalStore() {
    store.clock = () => now().millisecondsSinceEpoch;
    repo = SyncRepository(
      api: api,
      store: store,
      enabled: () => true,
      categoryEnabled: (c) => !off.contains(c),
      now: now,
    );
  }

  final DateTime Function() now;
  final _Api api;
  final MemorySyncLocalStore store;
  final off = <SyncCategory>{};
  late final SyncRepository repo;

  int get ms => now().millisecondsSinceEpoch;

  Future<SyncOutcome> sync() => repo.pull(_uid);

  void save(int n, {String? name}) => store.saveCustomImage(_url(n), name: name, at: ms);

  void delete(int n) => store.deleteCustomImage(_url(n), ms);

  List<String> get urls => store.customImageList.keys.toList()..sort();

  String? nameOf(int n) => store.customImageList[_url(n)]?.name;
}

int _bytes(Map<String, Map<String, dynamic>> items) => utf8.encode(jsonEncode(items)).length;

/// What a version before `custom_images_more` makes of the section [items] when it fits a document: the latest live
/// and deletion records within its caps, the oldest dropped first until within [syncCustomImagesFirstMaxBytes].
Map<String, Map<String, dynamic>> _fitAsBefore(Map<String, Map<String, dynamic>> items) {
  int byTimeThenKey(MapEntry<String, Map<String, dynamic>> a, MapEntry<String, Map<String, dynamic>> b) {
    final byTime = SyncDocument.updatedOf(b.value).compareTo(SyncDocument.updatedOf(a.value));
    return byTime != 0 ? byTime : a.key.compareTo(b.key);
  }

  final live = (items.entries.where((e) => !SyncDocument.isDeleted(e.value)).toList()..sort(byTimeThenKey))
      .take(syncCustomImagesMax)
      .toList();
  final gone = (items.entries.where((e) => SyncDocument.isDeleted(e.value)).toList()..sort(byTimeThenKey))
      .take(syncRemovalsMax)
      .toList();
  Map<String, Map<String, dynamic>> all() => {
    for (final e in [...live, ...gone]) e.key: e.value,
  };
  while ((live.isNotEmpty || gone.isNotEmpty) && _bytes(all()) > syncCustomImagesFirstMaxBytes) {
    if (gone.isEmpty ||
        (live.isNotEmpty && SyncDocument.updatedOf(live.last.value) <= SyncDocument.updatedOf(gone.last.value))) {
      live.removeLast();
    } else {
      gone.removeLast();
    }
  }
  return all();
}

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
  });

  late DateTime now;
  late _Forum forum;
  late _Device a;
  late _Device b;

  setUp(() {
    now = DateTime.fromMillisecondsSinceEpoch(_t);
    forum = _Forum();
    a = _Device(forum, () => now);
    b = _Device(forum, () => now);
  });

  void tick([int ms = 1000]) => now = now.add(Duration(milliseconds: ms));

  Map<String, Map<String, dynamic>> union() => SyncDocument.parse(forum.data).customImageItems();

  group('the budget', () {
    test('100 images of usual addresses and short names all go, the first part as a version before reads it', () async {
      for (var n = 1; n <= 100; n++) {
        a.store.saveCustomImage(_usualUrl(n), name: '表情$n', at: a.ms);
        tick();
      }
      await a.sync();
      final first = forum.items(customImagesSection);
      final more = forum.items(customImagesMoreSection);
      final all = union();
      // ignore: avoid_print, the size is part of the report of the change.
      print(
        '100 saved images: ${_bytes(all)} bytes in all, ${first.length} (${_bytes(first)} bytes) in the first '
        'section, ${more.length} in the second',
      );
      expect(all, hasLength(100));
      expect(_bytes(all), lessThanOrEqualTo(syncCustomImagesMaxBytes));
      expect(_bytes(first), lessThanOrEqualTo(syncCustomImagesFirstMaxBytes));
      expect(first.keys.toSet().intersection(more.keys.toSet()), isEmpty);
      expect(first, _fitAsBefore(first), reason: 'a version before finds the section as it would fit it');
      expect(first, _fitAsBefore(all), reason: 'the latest are in the first section');

      await b.sync();
      expect(b.store.customImageList, hasLength(100));
      expect(b.store.customImageList[_usualUrl(1)]!.name, '表情1');
      final pushes = a.api.pushes + b.api.pushes;
      expect(await a.sync(), SyncOutcome.upToDate);
      expect(await b.sync(), SyncOutcome.upToDate);
      expect(a.api.pushes + b.api.pushes, pushes);
    });

    test('a full document: the images past the first section give way first, the visits stay', () async {
      for (var tid = 1; tid <= syncVisitsMax; tid++) {
        await a.store.saveVisit(
          _uid,
          SyncVisit(
            tid: tid,
            title: 'a thread title to fill the document $tid',
            fid: 7,
            forumName: '版块',
            updated: _t - tid * 1000,
          ),
        );
      }
      for (var n = 1; n <= 100; n++) {
        a.store.saveCustomImage(_usualUrl(n), name: '表情$n', at: a.ms);
        tick();
      }
      await a.sync();
      final doc = SyncDocument.parse(forum.data);
      // ignore: avoid_print, the size is part of the report of the change.
      print('a full document: ${doc.encodedLength} bytes, ${doc.customImageItems().length} images');
      expect(doc.encodedLength, lessThanOrEqualTo(syncDocumentMaxBytes - syncCustomImagesMoreRoom));
      expect(doc.items('visits'), hasLength(syncVisitsMax), reason: 'no visit dropped for the images');
      final first = doc.items(customImagesSection);
      expect(first, _fitAsBefore({...first, ...doc.items(customImagesMoreSection)}), reason: 'the first section kept');
      expect(doc.customImageItems().length, lessThan(100));
      expect(doc.customImageItems().keys, contains(_usualUrl(100)), reason: 'the latest go');

      await b.sync();
      final pushes = a.api.pushes + b.api.pushes;
      expect(await a.sync(), SyncOutcome.upToDate);
      expect(await b.sync(), SyncOutcome.upToDate);
      expect(a.api.pushes + b.api.pushes, pushes, reason: 'no write back and forth over the room left');
    });

    test('a deletion of an image in the second section reaches the other device', () async {
      for (var n = 1; n <= 100; n++) {
        a.store.saveCustomImage(_usualUrl(n), at: a.ms);
        tick();
      }
      await a.sync();
      await b.sync();
      expect(forum.items(customImagesMoreSection).keys, contains(_usualUrl(1)));
      tick();
      b.store.deleteCustomImage(_usualUrl(1), b.ms);
      await b.sync();
      await a.sync();
      expect(a.store.customImageList.keys, isNot(contains(_usualUrl(1))));
      expect(a.store.customImageList, hasLength(99));
      expect(SyncDocument.isDeleted(union()[_usualUrl(1)]!), isTrue);
    });

    test('a document a version before wrote (the first section only, a later item in it) merges with both', () {
      final local = SyncDocument({
        'schema': 1,
        customImagesSection: {
          _url(1): const {'updated': _t, 'name': 'a'},
        },
        customImagesMoreSection: {
          _url(2): const {'updated': _t, 'name': 'b'},
          _url(3): const {'updated': _t, 'name': 'c'},
        },
      });
      final before = SyncDocument({
        'schema': 1,
        customImagesSection: {
          _url(2): const {'updated': _t + 1000, 'deleted': true},
          _url(4): const {'updated': _t, 'name': 'd'},
        },
        // Carried through as it was: the item of the first section is the later one.
        customImagesMoreSection: {
          _url(2): const {'updated': _t, 'name': 'b'},
        },
      });
      expect(before.customImageItems()[_url(2)], {'updated': _t + 1000, 'deleted': true});
      final merged = SyncDocument.merge(local, before);
      expect(merged.raw.containsKey(customImagesMoreSection), isFalse, reason: 'one section, the caps share them out');
      expect(merged.items(customImagesSection), {
        _url(1): {'updated': _t, 'name': 'a'},
        _url(2): {'updated': _t + 1000, 'deleted': true},
        _url(3): {'updated': _t, 'name': 'c'},
        _url(4): {'updated': _t, 'name': 'd'},
      });
    });
  });

  group('the time of a name', () {
    test('saved again on one device after a rename on the other: the new name stays on both', () async {
      a.save(1, name: '旧');
      await a.sync();
      await b.sync();
      tick();
      a.save(1, name: '新');
      await a.sync();
      tick();
      // Before B took the rename in: saved again from the image action sheet (no name).
      b.save(1);
      expect(b.nameOf(1), '旧');
      await b.sync();
      await a.sync();
      expect(b.nameOf(1), '新');
      expect(a.nameOf(1), '新');
      final item = union()[_url(1)]!;
      expect(item['name'], '新');
      expect(item['updated'], _t + 2000, reason: 'the save again is the later save');
      expect(item['named'], _t + 1000);
      expect(b.store.customImageList[_url(1)]!.updated, _t + 2000);
      expect(b.store.customImageList[_url(1)]!.named, _t + 1000);

      b.store.writes.clear();
      a.store.writes.clear();
      final pushes = a.api.pushes + b.api.pushes;
      expect(await a.sync(), SyncOutcome.upToDate);
      expect(await b.sync(), SyncOutcome.upToDate);
      expect(a.api.pushes + b.api.pushes, pushes);
      expect([...a.store.writes, ...b.store.writes], isEmpty);
    });

    test('the same time of a name on both (kept by a version before): the later save brings its name, '
        'taken in once', () async {
      a.save(1, name: 'X');
      tick();
      a.save(1);
      expect(a.store.customImageList[_url(1)]!.named, _t);
      // Renamed on a version before: the item replaced over the forum's, its `named` kept as it was.
      forum.write({
        'schema': 1,
        customImagesSection: {
          _url(1): {'updated': _t + 5000, 'name': 'Y', 'named': _t},
        },
      });
      tick();
      await a.sync();
      expect(a.nameOf(1), 'Y');
      a.store.writes.clear();
      final pushes = a.api.pushes;
      expect(await a.sync(), SyncOutcome.upToDate);
      expect(a.store.writes, isEmpty);
      expect(a.api.pushes, pushes);
    });

    test('renamed on both: the later name wins, whichever device saved later', () async {
      a.save(1, name: '一');
      await a.sync();
      await b.sync();
      tick();
      b.save(1, name: '二');
      tick();
      a.save(1, name: '三');
      tick();
      b.save(1);
      await b.sync();
      await a.sync();
      await b.sync();
      expect(a.nameOf(1), '三');
      expect(b.nameOf(1), '三');
    });

    test('an item without a time of its name (a version before) is named when saved', () {
      expect(SyncDocument.namedOf(const {'updated': _t, 'name': 'x'}), _t);
      expect(SyncDocument.namedOf(const {'updated': _t, 'named': _t + 5000}), _t, reason: 'never after the save');
      expect(SyncDocument.namedOf(const {'updated': _t, 'named': 'soon'}), _t);
      final merged = SyncDocument.mergeCustomImage(
        const {'updated': _t + 2000, 'name': '旧', 'named': _t},
        const {'updated': _t + 1000, 'name': '新', 'extra': 1},
      );
      expect(merged, {'updated': _t + 2000, 'name': '新', 'named': _t + 1000});
      expect(
        SyncDocument.mergeCustomImage(
          const {'updated': _t + 1000, 'name': '新'},
          const {'updated': _t + 2000, 'name': '旧', 'named': _t},
        ),
        {'updated': _t + 2000, 'name': '新', 'named': _t + 1000},
      );
      expect(
        SyncDocument.mergeCustomImage(
          const {'updated': _t + 1000, 'name': '新'},
          const {'updated': _t + 2000, 'deleted': true},
        ),
        {'updated': _t + 2000, 'deleted': true},
        reason: 'a later deletion wins',
      );
      expect(
        SyncDocument.mergeCustomImage(
          const {'updated': _t + 3000, 'name': '旧', 'named': _t},
          const {'updated': _t + 2000, 'deleted': true},
        ),
        {'updated': _t + 3000, 'name': '旧', 'named': _t},
        reason: 'saved again after the deletion: the image stays',
      );
    });

    group('the app storage', () {
      late AppDatabase db;
      late StorageProvider storage;

      setUp(() {
        db = AppDatabase(NativeDatabase.memory());
        storage = StorageProvider(db, {}, {});
      });

      tearDown(() => db.close());

      Future<int> addedAt(String url) async =>
          (await storage.fetchCustomImages()).firstWhere((e) => e.url == url).addedAt.millisecondsSinceEpoch;

      test('a save again keeps the time of the name, a rename or a deletion drops it', () async {
        final id = await storage.addCustomImage(url: _url(1), name: 'a');
        await db.customStatement('UPDATE custom_image SET added_at = 1000');
        expect(await storage.customImagesNamed(), isEmpty);

        await storage.addCustomImage(url: _url(1));
        expect(await storage.customImagesNamed(), {_url(1): 1000 * 1000});
        expect(await addedAt(_url(1)), greaterThan(1000 * 1000));
        await storage.addCustomImage(url: _url(1), name: 'a');
        expect(await storage.customImagesNamed(), {_url(1): 1000 * 1000}, reason: 'the name it has: a save again');

        await storage.addCustomImage(url: _url(1), name: 'b');
        expect(await storage.customImagesNamed(), isEmpty, reason: 'renamed: named when saved');

        await db.customStatement('UPDATE custom_image SET added_at = 2000');
        await storage.addCustomImage(url: _url(1));
        expect(await storage.customImagesNamed(), {_url(1): 2000 * 1000});
        await storage.deleteCustomImage(id);
        expect(await storage.customImagesNamed(), isEmpty);
      });

      test('the synced time of a name is kept apart, and dropped when it is the time of the save', () async {
        await storage.addCustomImage(url: _url(1), name: 'a');
        final later = DateTime.now().millisecondsSinceEpoch ~/ 1000 * 1000 + 60000;
        await storage.applySyncedCustomImages(
          save: [
            (url: _url(1), name: '新', updated: later, named: later - 30000),
            (url: _url(2), name: 'b', updated: later, named: later),
          ],
          remove: const {},
        );
        expect(await storage.customImagesNamed(), {_url(1): later - 30000});
        expect(await addedAt(_url(1)), later);
        await storage.applySyncedCustomImages(
          save: [(url: _url(1), name: '新', updated: later + 1000, named: later + 1000)],
          remove: {_url(2): later + 1000},
        );
        expect(await storage.customImagesNamed(), isEmpty);
      });
    });
  });
}
