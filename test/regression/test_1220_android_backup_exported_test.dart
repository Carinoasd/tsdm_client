// Android: nothing of the app goes into the system backup (cloud backup, device-to-device transfer), and the
// components other apps can reach are exactly the ones that must be reachable. The cookie database, the accounts and
// the settings stay on the device; the app has its own export, import and sync.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

const _android = 'http://schemas.android.com/apk/res/android';
const _tools = 'http://schemas.android.com/tools';
const _res = 'android/app/src/main/res/xml';

/// Every domain of the backup rules: the app's storage, its external files, and the device protected storage.
const _domains = {'root', 'file', 'database', 'sharedpref', 'external'};
const _deviceDomains = {'device_root', 'device_file', 'device_database', 'device_sharedpref'};

/// The exported components of the app manifest, each with why another app or the system has to reach it.
const _exported = {
  // The launcher entries and the forum links opened from a browser.
  'kzs.th000.tsdm_client.MainActivityImpl': 'activity',
  'kzs.th000.tsdm_client.MainActivity': 'activity-alias',
  'kzs.th000.tsdm_client.IconDark': 'activity-alias',
  'kzs.th000.tsdm_client.IconMono': 'activity-alias',
  'kzs.th000.tsdm_client.IconPink': 'activity-alias',
  // The home screen widget: the launcher's widget host.
  'kzs.th000.tsdm_client.HomeWidgetProvider': 'receiver',
  // The target of the system share sheet.
  'kzs.th000.tsdm_client.ShareActivity': 'activity',
  // The media buttons (headset, Bluetooth) the system delivers.
  'com.ryanheise.audioservice.MediaButtonReceiver': 'receiver',
};

const _components = {'activity', 'activity-alias', 'receiver', 'service', 'provider'};

String _full(String name) => name.startsWith('.') ? 'kzs.th000.tsdm_client$name' : name;

Iterable<XmlElement> _componentsOf(XmlDocument manifest) =>
    manifest.findAllElements('application').single.childElements.where((e) => _components.contains(e.name.local));

/// Exported as the system reads it: the attribute, or an intent filter without one (the old default).
bool _isExported(XmlElement component) {
  final value = component.getAttribute('exported', namespace: _android);
  return value == 'true' || (value == null && component.findElements('intent-filter').isNotEmpty);
}

Set<String> _excluded(XmlElement section) => section
    .findElements('exclude')
    .where((e) => e.getAttribute('path') == '.')
    .map((e) => e.getAttribute('domain')!)
    .toSet();

void main() {
  final manifest = XmlDocument.parse(File('android/app/src/main/AndroidManifest.xml').readAsStringSync());
  final application = manifest.findAllElements('application').single;

  test('system backup is off and both rule files are wired', () {
    expect(application.getAttribute('allowBackup', namespace: _android), 'false');
    expect(application.getAttribute('fullBackupContent', namespace: _android), '@xml/backup_rules');
    expect(application.getAttribute('dataExtractionRules', namespace: _android), '@xml/data_extraction_rules');
  });

  test('Android 12+: cloud backup and device transfer both exclude every domain', () {
    // allowBackup="false" does not stop the device-to-device transfer from Android 12 on: these rules do.
    final rules = XmlDocument.parse(File('$_res/data_extraction_rules.xml').readAsStringSync()).rootElement;
    expect(rules.name.local, 'data-extraction-rules');
    for (final name in ['cloud-backup', 'device-transfer']) {
      final section = rules.findElements(name).single;
      expect(section.findElements('include'), isEmpty, reason: name);
      expect(_excluded(section), {..._domains, ..._deviceDomains}, reason: name);
    }
  });

  test('Android 11 and older: the full backup excludes every domain', () {
    final rules = XmlDocument.parse(File('$_res/backup_rules.xml').readAsStringSync()).rootElement;
    expect(rules.name.local, 'full-backup-content');
    expect(rules.findElements('include'), isEmpty);
    expect(_excluded(rules), _domains);
  });

  test('the exported components of the app manifest are exactly the known ones', () {
    final exported = {
      for (final c in _componentsOf(manifest).where(_isExported))
        _full(c.getAttribute('name', namespace: _android)!): c.name.local,
    };
    expect(exported, _exported);
  });

  test('the background service plugin: watchdog, boot receiver and service are made unexported', () {
    for (final name in const [
      'id.flutter.flutter_background_service.WatchdogReceiver',
      'id.flutter.flutter_background_service.BootReceiver',
      'id.flutter.flutter_background_service.BackgroundService',
    ]) {
      final component = _componentsOf(manifest).singleWhere(
        (e) => e.getAttribute('name', namespace: _android) == name,
        orElse: () => throw StateError(name),
      );
      expect(component.getAttribute('exported', namespace: _android), 'false', reason: name);
      expect(component.getAttribute('replace', namespace: _tools), contains('android:exported'), reason: name);
    }
  });

  test('every component a Flutter plugin exports is made unexported here or is one of the known ones', () {
    // A plugin update that adds an exported component fails here. Components of plain Android libraries (androidx)
    // are not seen by this test: the merged manifest of a build shows them.
    final dependencies = jsonDecode(File('.flutter-plugins-dependencies').readAsStringSync()) as Map<String, dynamic>;
    final plugins = ((dependencies['plugins'] as Map<String, dynamic>)['android'] as List<dynamic>)
        .cast<Map<String, dynamic>>();
    expect(plugins, isNotEmpty);
    final overridden = {
      for (final c in _componentsOf(manifest))
        if (!_isExported(c)) _full(c.getAttribute('name', namespace: _android)!),
    };
    final reachable = <String>[];
    var seen = 0;
    for (final plugin in plugins) {
      final root = (plugin['path'] as String).replaceAll(RegExp(r'/+$'), '');
      final file = File('$root/android/src/main/AndroidManifest.xml');
      if (!file.existsSync()) continue;
      final pluginManifest = XmlDocument.parse(file.readAsStringSync());
      final package = pluginManifest.rootElement.getAttribute('package');
      final application = pluginManifest.findAllElements('application');
      if (application.isEmpty) continue;
      for (final c in application.single.childElements.where((e) => _components.contains(e.name.local))) {
        seen += 1;
        if (!_isExported(c)) continue;
        final raw = c.getAttribute('name', namespace: _android)!;
        final name = raw.startsWith('.') && package != null ? '$package$raw' : raw;
        if (!overridden.contains(name) && !_exported.containsKey(name)) {
          reachable.add('${plugin['name']}: $name');
        }
      }
    }
    expect(seen, greaterThan(0));
    expect(reachable, isEmpty);
  });

  test('a shared stream is checked before it is read, for both share entries', () {
    // MainActivityImpl is exported too: a share sent straight to it does not pass ShareActivity, so the check is
    // where both end, in ShareIntents.read (the Kotlin tests cover the rule itself).
    final share = File('android/app/src/main/kotlin/kzs/th000/tsdm_client/ShareIntents.kt').readAsStringSync();
    expect(share, contains('.filter { uri -> acceptsStream(uri) {'));
    expect(share, contains('val images = copyImages(context, accepted)'));
    expect(RegExp(r'copyImages\(').allMatches(share), hasLength(2), reason: 'one definition, one call');
  });

  test('the interactive viewer handles in place the configuration changes a user can make while away', () {
    // With the app lock on, a recreated viewer closes (it cannot tell a dead process from a configuration change):
    // the changes a user makes in the system settings while away must not recreate it.
    final viewer = _componentsOf(manifest).singleWhere(
      (e) => e.getAttribute('name', namespace: _android) == 'kzs.th000.tsdm_client.InteractiveHtmlActivity',
    );
    final changes = viewer.getAttribute('configChanges', namespace: _android)!.split('|').toSet();
    expect(
      changes,
      containsAll(const [
        'orientation', 'screenSize', 'screenLayout', 'smallestScreenSize', 'keyboardHidden', 'keyboard', //
        'navigation', 'density', 'uiMode', 'fontScale', 'fontWeightAdjustment', 'locale', 'layoutDirection', //
        'grammaticalGender', 'colorMode', 'touchscreen', 'mcc', 'mnc',
      ]),
    );
  });
}
