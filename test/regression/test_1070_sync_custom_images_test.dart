/// The cross-device sync of the saved images of the emoji pickers ("my images", the `custom_images` section):
///
/// * item by item the later wins, by the address; a deleted image leaves a record of when, noted where it is deleted,
///   so the deletion reaches the other devices unless one saved the image again later; a new name is a change;
/// * only addresses the editor saves go (no image itself); a section switched off is neither read nor written, and
///   switched on again deletes nothing; within its budget the oldest stay on their device, no deletion for the others;
/// * the time is stored in whole seconds: a second run writes nothing;
/// * documents without the section, items and fields this version does not know, a newer schema left alone; `schema`
///   stays 1;
/// * the app's storage: a deletion is noted, saving again drops the note, a rename is timed, the sync's apply keeps
///   the order of the images already there;
/// * the coordinator: the switch is on by default, a change of the images schedules a write.
///
/// Synthetic data, no real account or forum.
library;

import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rxdart/rxdart.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/features/editor/utils/custom_image_sync.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/sync/models/sync_document.dart';
import 'package:tsdm_client/features/sync/repository/sync_api.dart';
import 'package:tsdm_client/features/sync/repository/sync_local_store.dart';
import 'package:tsdm_client/features/sync/repository/sync_repository.dart';
import 'package:tsdm_client/features/sync/sync_coordinator.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

const _uid = 31;

/// The device clock of the tests (milliseconds, whole seconds).
const _t = 1700000000000;

String _url(int n) => 'https://forum.test/data/attachment/forum/202611/13/image_$n.png';

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

  void save(int n, {String name = ''}) => store.saveCustomImage(_url(n), name: name, at: ms);

  void delete(int n) => store.deleteCustomImage(_url(n), ms);

  List<String> get urls => store.customImageList.keys.toList()..sort();

  String? nameOf(int n) => store.customImageList[_url(n)]?.name;
}

final class _Auth extends Fake implements AuthenticationRepository {
  final _status = BehaviorSubject<AuthStatus>.seeded(const AuthStatusAuthed(UserLoginInfo(username: 'u', uid: _uid)));

  @override
  int? get effectiveCurrentUid => _uid;

  @override
  Stream<AuthStatus> get status => _status.stream;

  @override
  Future<void> dispose() => _status.close();
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

  group('the section', () {
    test('each device saves an image: both have both, with their names; the address and the name only', () async {
      a.save(1, name: '猫猫');
      tick();
      b.save(2);
      await a.sync();
      await b.sync();
      await a.sync();
      expect(a.urls, [_url(1), _url(2)]);
      expect(b.urls, [_url(1), _url(2)]);
      expect(b.nameOf(1), '猫猫');
      expect(forum.items(customImagesSection)[_url(1)], {'updated': _t, 'name': '猫猫'});
      expect(forum.items(customImagesSection)[_url(2)], {'updated': _t + 1000, 'name': ''});
      expect(forum.doc['schema'], 1, reason: 'a new section, the same schema');
    });

    test('deleted on one device it is deleted on the other; saved again later on the other, it comes back', () async {
      a
        ..save(1)
        ..save(2);
      await a.sync();
      await b.sync();
      expect(b.urls, [_url(1), _url(2)]);

      tick();
      a.delete(1);
      await a.sync();
      expect(forum.items(customImagesSection)[_url(1)], {'updated': _t + 1000, 'deleted': true});
      await b.sync();
      expect(b.urls, [_url(2)]);
      expect(b.store.customImagesRemovedAt, {_url(1): _t + 1000});

      tick();
      b.save(1, name: '回来了');
      await b.sync();
      await a.sync();
      expect(a.urls, [_url(1), _url(2)]);
      expect(a.nameOf(1), '回来了');
      expect(a.store.customImagesRemovedAt, isEmpty);
    });

    test('saved again on one device before it was deleted on the other: the deletion wins', () async {
      a.save(1);
      await a.sync();
      await b.sync();
      tick();
      b.save(1, name: '改名');
      tick();
      a.delete(1);
      await a.sync();
      await b.sync();
      await a.sync();
      expect(a.urls, isEmpty);
      expect(b.urls, isEmpty);
      expect(forum.items(customImagesSection)[_url(1)], {'updated': _t + 2000, 'deleted': true});
    });

    test('a new name is a change: the later name wins on both', () async {
      a.save(1, name: '旧');
      await a.sync();
      await b.sync();
      tick();
      b.save(1, name: '新');
      await b.sync();
      await a.sync();
      expect(a.nameOf(1), '新');
      expect(a.store.customImageList[_url(1)]!.updated, _t + 1000);
    });

    test('both change at once: the refused write merges and both end with the same', () async {
      await a.sync();
      await b.sync();
      a.save(1);
      tick();
      b.save(2);
      a.api.afterPull = () async => b.sync();
      await a.sync();
      expect(a.api.conflicts, 1);
      await b.sync();
      expect(a.urls, [_url(1), _url(2)]);
      expect(b.urls, [_url(1), _url(2)]);
    });

    test('a time within the second it is stored in: taken once, no write back and forth', () async {
      forum.write({
        'schema': 1,
        customImagesSection: {
          _url(5): {'updated': _t + 1234, 'name': '毫秒', 'extra': 1},
        },
      });
      tick(5000);
      await b.sync();
      expect(b.store.customImageList[_url(5)]!.updated, _t + 1000);
      b.store.writes.clear();
      final pushes = b.api.pushes;
      expect(await b.sync(), SyncOutcome.upToDate);
      expect(await b.sync(), SyncOutcome.upToDate);
      expect(b.store.writes, isEmpty);
      expect(b.api.pushes, pushes);
      expect(forum.items(customImagesSection)[_url(5)]!['extra'], 1, reason: 'a field this version does not know');
    });

    test('over the budget the oldest stay on their device and are no deletion on the others', () async {
      for (var n = 1; n <= 120; n++) {
        a.save(n, name: '一个相当长的中文图片名称，用来占满预算 $n');
        tick();
      }
      await a.sync();
      final sent = forum.items(customImagesSection);
      expect(utf8.encode(jsonEncode(sent)).length, lessThanOrEqualTo(syncCustomImagesMaxBytes));
      expect(sent.length, lessThan(120));
      expect(sent.keys, contains(_url(120)), reason: 'the latest go');
      expect(sent.keys, isNot(contains(_url(1))));
      expect(a.urls, hasLength(120), reason: 'nothing deleted here');
      await b.sync();
      expect(b.urls, hasLength(sent.length));
      await a.sync();
      expect(a.urls, hasLength(120));
      expect(forum.items(customImagesSection).values.where(SyncDocument.isDeleted), isEmpty);
    });

    test('switched off it is neither read nor written; switched on again nothing is deleted', () async {
      a.save(1);
      await a.sync();
      b.off.add(SyncCategory.customImages);
      b.save(9);
      await b.sync();
      expect(b.urls, [_url(9)]);
      expect(forum.items(customImagesSection).keys, [_url(1)]);
      tick();
      a.save(2);
      await a.sync();
      await b.sync();
      expect(b.urls, [_url(9)]);
      b.off.clear();
      tick();
      await b.sync();
      expect(b.urls, [_url(1), _url(2), _url(9)]);
      await a.sync();
      expect(a.urls, [_url(1), _url(2), _url(9)], reason: 'the images B never held are no deletion');
      expect(forum.items(customImagesSection).values.where(SyncDocument.isDeleted), isEmpty);
    });

    test('addresses the editor does not save are neither written nor taken, and carried as they are', () async {
      final long = 'https://forum.test/${'a' * syncCustomImageUrlMaxLength}.png';
      a.store.customImageList[long] = CustomImageSyncEntry(url: long, name: '', updated: _t);
      a.save(1);
      await a.sync();
      expect(forum.items(customImagesSection).keys, [_url(1)], reason: 'a too long address stays on its device');

      forum.write({
        ...forum.doc,
        customImagesSection: {
          ...forum.doc[customImagesSection] as Map<String, dynamic>,
          'javascript:alert(1)': {'updated': _t + 500, 'name': 'x'},
          'file:///etc/passwd': {'updated': _t + 500},
          _url(3): {'updated': 'soon', 'name': 'x'},
          _url(4): {'updated': _t + 500, 'name': 7},
        },
      });
      tick();
      await b.sync();
      expect(b.urls, [_url(1), _url(4)], reason: 'a name that is not text reads as none');
      expect(b.nameOf(4), '');
      await a.sync();
      expect(
        forum.items(customImagesSection).keys,
        containsAll(['javascript:alert(1)', 'file:///etc/passwd', _url(3)]),
        reason: 'items this version can not read are carried, never deleted',
      );
    });

    test('an older document without the section, a section of an unknown shape, a newer schema left alone', () async {
      forum.write({
        'schema': 1,
        'phrases': {
          'updated': _t,
          'items': ['x'],
        },
        'later_things': {'k': 1},
      });
      a.save(1);
      await a.sync();
      expect(forum.items(customImagesSection).keys, [_url(1)]);
      expect(forum.doc['later_things'], {'k': 1});

      forum.write({...forum.doc, customImagesSection: 'not an object'});
      tick();
      await b.sync();
      expect(b.urls, isEmpty);

      final newer = {
        'schema': 2,
        customImagesSection: {
          _url(7): {'updated': _t + 9000, 'name': 'v2'},
        },
      };
      forum.write(newer);
      expect(await b.sync(), SyncOutcome.newerSchema);
      expect(b.urls, isEmpty, reason: 'nothing applied');
      expect(forum.doc, newer, reason: 'nothing written');
    });

    test('a document as an older version writes it (the section carried as unknown) reads the same', () {
      final local = SyncDocument({
        'schema': 1,
        customImagesSection: {
          _url(1): const {'updated': _t, 'name': 'a'},
        },
      });
      final older = SyncDocument({
        'schema': 1,
        customImagesSection: {
          _url(1): const {'updated': _t + 1000, 'deleted': true},
          _url(2): const {'updated': _t, 'name': 'b', 'from_v2': true},
        },
      });
      final merged = SyncDocument.merge(local, older);
      expect(merged.items(customImagesSection), {
        _url(1): {'updated': _t + 1000, 'deleted': true},
        _url(2): {'updated': _t, 'name': 'b', 'from_v2': true},
      });
      expect(SyncDocument.itemSections, contains(customImagesSection));
    });
  });

  group('the app storage', () {
    late AppDatabase db;
    late StorageProvider storage;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      storage = StorageProvider(db, {}, {});
    });

    tearDown(() => db.close());

    test('a deletion is noted, saving again drops the note, a rename is timed, the same name is no change', () async {
      final id = await storage.addCustomImage(url: _url(1), name: 'a');
      await storage.addCustomImage(url: _url(2));
      final before = (await storage.fetchCustomImages()).first.addedAt;
      await storage.addCustomImage(url: _url(1), name: 'a');
      expect((await storage.fetchCustomImages()).first.addedAt, before, reason: 'the same name');

      await storage.deleteCustomImage(id);
      expect((await storage.customImagesRemoved()).keys, [_url(1)]);
      await storage.deleteCustomImage(9999);
      expect((await storage.customImagesRemoved()).keys, [_url(1)], reason: 'nothing deleted, nothing noted');
      await storage.addCustomImage(url: _url(1));
      expect(await storage.customImagesRemoved(), isEmpty);

      await db.customStatement('UPDATE custom_image SET added_at = 1000');
      await storage.addCustomImage(url: _url(2), name: '新名字');
      final renamed = (await storage.fetchCustomImages()).firstWhere((e) => e.url == _url(2));
      expect(renamed.name, '新名字');
      expect(renamed.addedAt.millisecondsSinceEpoch, greaterThan(1000 * 1000), reason: 'the rename is timed');
    });

    test('the store reads the images and takes the forum items in, keeping the order of the ones there', () async {
      final settings = SettingsRepository(storage);
      await settings.init();
      final blocks = UserBlockRepository(storage);
      final auth = _Auth();
      addTearDown(() async {
        await auth.dispose();
        await blocks.dispose();
        await settings.dispose();
      });
      final store = StorageSyncLocalStore(storage: storage, settings: settings, blocks: blocks, authentication: auth);
      await storage.addCustomImage(url: _url(1), name: 'a');
      await storage.addCustomImage(url: _url(2), name: 'b');
      await storage.addCustomImage(url: _url(3));
      final (:entries, removed: _) = await store.customImages();
      expect([for (final e in entries) e.url], [_url(1), _url(2), _url(3)]);
      expect(entries.first.updated % 1000, 0, reason: 'the stored time is in whole seconds');

      final later = DateTime.now().millisecondsSinceEpoch + 60000;
      await store.applyCustomImages({
        _url(1): {'updated': later, 'name': '改名'},
        _url(2): {'updated': later, 'deleted': true},
        _url(5): {'updated': later + 2000, 'name': 'e'},
        _url(4): {'updated': later + 1000, 'name': 'd'},
        _url(6): {'updated': later, 'deleted': true},
      });
      final images = await storage.fetchCustomImages();
      expect(
        [for (final e in images) e.url],
        [_url(1), _url(3), _url(4), _url(5)],
        reason: 'new ones after, earliest first',
      );
      expect(images.first.name, '改名');
      expect(await storage.customImagesRemoved(), {_url(2): later}, reason: 'only what was deleted here');

      // Taken in once: the second time changes nothing.
      final again = await store.customImages();
      await store.applyCustomImages({
        _url(1): {'updated': later, 'name': '改名'},
        _url(5): {'updated': later + 2000, 'name': 'e'},
      });
      final after = await store.customImages();
      expect(after.entries, again.entries);
      expect(after.removed, again.removed);

      // Deleted here, then saved later on another device: back, the note dropped.
      await store.applyCustomImages({
        _url(2): {'updated': later + 5000, 'name': 'b2'},
      });
      expect((await storage.fetchCustomImages()).map((e) => e.url), contains(_url(2)));
      expect(await storage.customImagesRemoved(), isEmpty);
    });

    test('the coordinator: the switch is on by default, a change of the images schedules a write', () async {
      final settings = SettingsRepository(storage);
      await settings.init();
      final blocks = UserBlockRepository(storage);
      final auth = _Auth();
      final repository = SyncRepository(
        api: _Api(_Forum()),
        store: MemorySyncLocalStore(),
        enabled: () => settings.currentSettings.crossDeviceSync,
        currentUid: () => auth.effectiveCurrentUid,
        categoryEnabled: (c) => SyncCoordinator.categoryEnabledIn(settings.currentSettings, c),
        debounce: const Duration(minutes: 5),
      );
      final coordinator = SyncCoordinator(
        repository: repository,
        authentication: auth,
        settings: settings,
        blocks: blocks,
        storage: storage,
      )..start();
      addTearDown(() async {
        await coordinator.dispose();
        await auth.dispose();
        await blocks.dispose();
        await settings.dispose();
      });
      Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 50));
      await settle();
      expect(settings.currentSettings.crossDeviceSyncCustomImages, isTrue);
      expect(SyncCoordinator.categoryEnabledIn(settings.currentSettings, SyncCategory.customImages), isTrue);
      repository.cancelScheduled();

      await storage.addCustomImage(url: _url(1));
      await settle();
      expect(repository.pushScheduled, isTrue, reason: 'an image saved');
      repository.cancelScheduled();

      final id = (await storage.fetchCustomImages()).single.id;
      await storage.deleteCustomImage(id);
      await settle();
      expect(repository.pushScheduled, isTrue, reason: 'an image deleted');
      repository.cancelScheduled();

      await settings.setValue(SettingsKeys.crossDeviceSyncCustomImages, false);
      expect(SyncCoordinator.categoryEnabledIn(settings.currentSettings, SyncCategory.customImages), isFalse);
    });
  });

  test('the size of a typical document with 30 saved images', () async {
    final device = _Device(forum, () => now);
    device.store.phraseList = ['谢谢楼主', '收藏了'];
    device.off.add(SyncCategory.customImages);
    for (var n = 1; n <= 30; n++) {
      device.save(n, name: n.isEven ? '表情$n' : '');
    }
    await device.sync();
    final before = utf8.encode(forum.data!).length;
    device.off.clear();
    tick();
    await device.sync();
    final after = utf8.encode(forum.data!).length;
    // ignore: avoid_print, the size is part of the report of the change.
    print('typical document: $before bytes before, $after bytes after (+${after - before})');
    expect(after - before, lessThan(syncCustomImagesMaxBytes));
    expect(forum.items(customImagesSection), hasLength(30));
  });
}
