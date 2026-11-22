/// What `status` of plugin 4.1.0 tells of the forum's other plugins (`site_plugins`): the "me" tab hides the entry of
/// one the forum switched off.
///
/// * Only a value of 0 says off; 1, any other value, an id left out, a `site_plugins` that is not an object and a
///   `status` without it (plugin 4.0.x) leave every entry on.
/// * What a `status` told holds through the answers of the same version that leave it out (`notify`) and through
///   [TsdmAppApi.forgetStatus]; a later `status` replaces it, and the change reaches the listeners of
///   [TsdmAppApi.pluginInfo].
///
/// Fixtures: the `status` of the test forum (4.0.0, cleaned) with `site_plugins` added.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';

import 'tsdmapp_v4_fake.dart';

/// The `status` of 4.1.0: the recorded one of 4.0.0 with [sitePlugins].
Map<String, dynamic> _status(Object? sitePlugins, {String version = '4.1.0'}) =>
    v4Status({'version': version, 'site_plugins': sitePlugins});

const _ids = ['gamecenter', 'tsdm_court', 'tsdmcp', 'np_cliworkdz'];

void main() {
  setUpAll(registerV4TestServices);
  tearDownAll(resetV4TestServices);
  setUp(TsdmAppApi.reset);
  tearDown(TsdmAppApi.reset);

  test('only a value of 0 says off', () {
    final info = TsdmAppPluginInfo.fromAnswer(
      _status({'gamecenter': 1, 'tsdm_court': 0, 'tsdmcp': '0', 'np_cliworkdz': 2, 'other': 0}),
    )!;
    expect(info.sitePluginsOff, {'tsdm_court', 'tsdmcp', 'other'});
    TsdmAppApi.pluginInfo.value = info;
    expect([for (final id in _ids) TsdmAppApi.sitePluginOff(id)], [false, true, true, false]);
  });

  test('nothing is off without a site_plugins object', () {
    for (final value in [null, <String, Object>{}, const <Object>[], 'gamecenter', 0]) {
      final info = TsdmAppPluginInfo.fromAnswer(_status(value))!;
      TsdmAppApi.pluginInfo.value = info;
      for (final id in _ids) {
        expect(TsdmAppApi.sitePluginOff(id), isFalse, reason: '$value: $id');
      }
    }
    expect(TsdmAppPluginInfo.fromAnswer(_status(null))!.sitePluginsOff, isNull, reason: 'a status of 4.0.x');
    TsdmAppApi.pluginInfo.value = null;
    expect(TsdmAppApi.sitePluginOff('tsdmcp'), isFalse, reason: 'no status asked yet');
  });

  test('equality: same plugins off equal, whatever the order', () {
    final a = TsdmAppPluginInfo.fromAnswer(_status({'tsdmcp': 0, 'tsdm_court': 0}))!;
    final b = TsdmAppPluginInfo.fromAnswer(_status({'tsdm_court': 0, 'gamecenter': 1, 'tsdmcp': 0}))!;
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect(a, isNot(TsdmAppPluginInfo.fromAnswer(_status({'tsdmcp': 0}))));
    expect(a, isNot(TsdmAppPluginInfo.fromAnswer(_status(null))));
  });

  test('kept through a notify of the same version and forgetStatus, replaced by the next status', () async {
    Object? sitePlugins = {'gamecenter': 1, 'tsdm_court': 1, 'tsdmcp': 0, 'np_cliworkdz': 1};
    final forum = V4Forum(
      (o) => switch (o.uri.queryParameters['action']) {
        'status' => V4Reply(_status(sitePlugins)),
        'notify' => const V4Reply({
          'ok': 1,
          'api': 1,
          'version': '4.1.0',
          'time': 1700000000,
          'uid': 31,
          'notices': <Object>[],
        }),
        _ => null,
      },
    );
    final client = v4Client(forum);
    var changes = 0;
    void count() => changes++;
    TsdmAppApi.pluginInfo.addListener(count);
    addTearDown(() => TsdmAppApi.pluginInfo.removeListener(count));

    await TsdmAppApi.ask(client, 'status');
    expect(TsdmAppApi.sitePluginOff('tsdmcp'), isTrue);
    expect(TsdmAppApi.sitePluginOff('gamecenter'), isFalse);
    expect(changes, 1);

    await TsdmAppApi.ask(client, 'notify', {'since': '0'});
    expect(TsdmAppApi.sitePluginOff('tsdmcp'), isTrue, reason: 'notify names no plugins: what status said holds');

    TsdmAppApi.forgetStatus();
    expect(TsdmAppApi.sitePluginOff('tsdmcp'), isTrue, reason: 'only the v4 flags are forgotten');

    // The forum switched the plugin on again, and another off: the same version, only these changed.
    sitePlugins = {'gamecenter': 0, 'tsdm_court': 1, 'tsdmcp': 1, 'np_cliworkdz': 1};
    changes = 0;
    await TsdmAppApi.ask(client, 'status');
    expect(changes, 1, reason: 'the listeners hear of the change');
    expect([for (final id in _ids) TsdmAppApi.sitePluginOff(id)], [true, false, false, false]);

    // A status of the same version that names no plugins tells nothing new about them.
    sitePlugins = null;
    await TsdmAppApi.ask(client, 'status');
    expect(TsdmAppApi.sitePluginOff('gamecenter'), isTrue);
    expect(forum.unexpected, isEmpty);
  });

  test('an older plugin, without the key: every entry stays', () async {
    final forum = V4Forum(
      (o) => switch (o.uri.queryParameters['action']) {
        'status' => V4Reply(v4Status({'version': '4.0.0'})),
        _ => null,
      },
    );
    await TsdmAppApi.ask(v4Client(forum), 'status');
    expect(TsdmAppApi.pluginInfo.value, isNotNull);
    expect(TsdmAppApi.pluginInfo.value!.sitePluginsOff, isNull);
    for (final id in _ids) {
      expect(TsdmAppApi.sitePluginOff(id), isFalse, reason: id);
    }
  });
}
