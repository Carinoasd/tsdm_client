// What's new (P8): when the homepage offers the changelog of the installed version, and what is recorded.
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/update/repository/whats_new_controller.dart';
import 'package:tsdm_client/instance.dart';

const _released = ['1.55.0', '1.54.1', '1.54.0', '1.53.2', '1.10.0', '1.9.0'];

/// The storage of the settings in memory, counting the writes.
final class _Store {
  final Map<String, String> values = {};
  int writes = 0;

  Future<String?> read(String key) async => values[key];

  Future<void> write(String key, String value) async {
    writes++;
    values[key] = value;
  }
}

void main() {
  late _Store store;

  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  setUp(() => store = _Store());

  WhatsNewController controller(String appVersion) => WhatsNewController(
    read: store.read,
    write: store.write,
    appVersion: appVersion,
    releasedVersions: () => _released,
  );

  String? seen() => store.values[WhatsNewController.storageKey];

  test('a new install records the version and offers nothing', () async {
    final c = controller('1.55.0+170');
    await c.resolve(hadPriorData: false);
    expect(c.prompt.value, isNull);
    expect(seen(), '1.55.0');
  });

  test('an update offers the news since the version seen, recorded only once dismissed', () async {
    store.values[WhatsNewController.storageKey] = '1.54.1';
    final c = controller('1.55.0+170');
    await c.resolve(hadPriorData: true);
    expect(c.prompt.value, const WhatsNewPrompt(version: '1.55.0', since: '1.54.1'));
    expect(store.writes, 0);

    await c.markSeen();
    expect(c.prompt.value, isNull);
    expect(seen(), '1.55.0');

    // The next start of the same version.
    final again = controller('1.55.0+170');
    await again.resolve(hadPriorData: true);
    expect(again.prompt.value, isNull);
  });

  test('skipping versions offers every one in between', () async {
    store.values[WhatsNewController.storageKey] = '1.9.0';
    final c = controller('1.55.0+170');
    await c.resolve(hadPriorData: true);
    final p = c.prompt.value!;
    expect(p.since, '1.9.0');
    expect(_released.where((v) => isNewRelease(v, since: p.since, until: p.version)), [
      '1.55.0',
      '1.54.1',
      '1.54.0',
      '1.53.2',
      '1.10.0',
    ]);
  });

  test('an update from an app that kept no record offers the installed version only', () async {
    final c = controller('1.55.0+170');
    await c.resolve(hadPriorData: true);
    final p = c.prompt.value!;
    expect(p, const WhatsNewPrompt(version: '1.55.0', since: null));
    expect(_released.where((v) => isNewRelease(v, since: p.since, until: p.version)), ['1.55.0']);
    expect(store.writes, 0);
  });

  test('the same version again offers nothing', () async {
    store.values[WhatsNewController.storageKey] = '1.55.0';
    final c = controller('1.55.0+170');
    await c.resolve(hadPriorData: true);
    expect(c.prompt.value, isNull);
    expect(store.writes, 0);
  });

  test('versions compare by numbers, not as text', () async {
    store.values[WhatsNewController.storageKey] = '1.10.0';
    final older = controller('1.9.0+1');
    await older.resolve(hadPriorData: true);
    expect(older.prompt.value, isNull, reason: 'a downgrade');
    expect(seen(), '1.10.0');

    store.values[WhatsNewController.storageKey] = '1.9.0';
    final newer = controller('1.10.0+2');
    await newer.resolve(hadPriorData: true);
    expect(newer.prompt.value?.since, '1.9.0');
  });

  test('a version without an entry yet (being developed) offers and records nothing', () async {
    store.values[WhatsNewController.storageKey] = '1.54.1';
    final c = controller('1.56.0+171');
    await c.resolve(hadPriorData: true);
    expect(c.prompt.value, isNull);
    expect(seen(), '1.54.1');

    // Once released with an entry, the news since 1.54.1 are offered.
    final released = WhatsNewController(
      read: store.read,
      write: store.write,
      appVersion: '1.56.0+171',
      releasedVersions: () => ['1.56.0', ..._released],
    );
    await released.resolve(hadPriorData: true);
    expect(released.prompt.value, const WhatsNewPrompt(version: '1.56.0', since: '1.54.1'));
  });

  test('a new install of a pre-release build records nothing: the release after it is offered', () async {
    final c = controller('1.55.0-blocking.3+82');
    await c.resolve(hadPriorData: false);
    expect(store.writes, 0);

    final released = controller('1.55.0+170');
    await released.resolve(hadPriorData: true);
    expect(released.prompt.value, const WhatsNewPrompt(version: '1.55.0', since: null));
  });

  test('the changelog is read only when there may be an offer', () async {
    var reads = 0;
    store.values[WhatsNewController.storageKey] = '1.55.0';
    final c = WhatsNewController(
      read: store.read,
      write: store.write,
      appVersion: '1.55.0+170',
      releasedVersions: () {
        reads++;
        return _released;
      },
    );
    await c.resolve(hadPriorData: true);
    expect(reads, 0);
  });

  test('a failed write is not thrown at the caller', () async {
    store.values[WhatsNewController.storageKey] = '1.54.1';
    final c = WhatsNewController(
      read: store.read,
      write: (_, _) async => throw StateError('disk full'),
      appVersion: '1.55.0+170',
      releasedVersions: () => _released,
    );
    await c.resolve(hadPriorData: true);
    await c.markSeen();
    expect(c.prompt.value, isNull);
  });

  test('a pre-release build offers nothing', () async {
    store.values[WhatsNewController.storageKey] = '1.54.1';
    final c = controller('1.55.0-blocking.3+82');
    await c.resolve(hadPriorData: true);
    expect(c.prompt.value, isNull);
    expect(store.writes, 0);
  });

  test('marking seen without an offer writes nothing', () async {
    final c = controller('1.55.0+170');
    await c.markSeen();
    expect(store.writes, 0);
  });
}
