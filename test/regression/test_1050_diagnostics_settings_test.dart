// The settings section of the diagnostics bundle (PR #410) came out empty on a device: the whole settings map was
// encoded at once, and a value without a mapper (the window's `Size`) failed it all
// ("MapperException: Failed to encode (SettingsMap).windowSize[Instance of 'Size']: Unknown type Size").
//
// The section reads the names of the allow list one by one from the settings as they are, each turned into a short
// text of its own: a name that fails is left out alone.
import 'dart:ui';

import 'package:drift/native.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/diagnostics/diagnostics_bundle.dart';
import 'package:tsdm_client/features/diagnostics/diagnostics_export.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

void main() {
  late AppDatabase db;
  late SettingsMap settings;

  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(useConsoleLogs: false)));

  setUp(() async {
    talker.cleanHistory();
    db = AppDatabase(NativeDatabase.memory());
    final repository = SettingsRepository(StorageProvider(db, {}, {}));
    await repository.init();
    settings = repository.currentSettings.copyWith(
      // The values of a desktop that remembers its window: what made the whole map fail.
      windowSize: const Size(1280, 720),
      windowPosition: const Offset(12, 34),
    );
  });
  tearDown(() => db.close());

  String info(Map<String, Object?> values) => composeDiagnosticsInfo(
    appVersion: '1',
    buildMode: 'release',
    platform: 'android',
    osVersion: 'x',
    deviceModel: '',
    locale: 'zh_CN, app zh-CN',
    display: '-',
    plugin: null,
    settings: values,
    now: DateTime(2026, 11, 13),
  );

  test('every name of the allow list is told for the settings of the app', () {
    final told = diagnosticSettingsSummary(diagnosticSettingsOf(settings));
    expect(told.map((e) => e.$1), diagnosticSettingNames);
    final text = info(diagnosticSettingsOf(settings));
    expect(text, contains('  locale: '));
    expect(text, contains('  themeMode: '));
    expect(text, contains('  enableDebugOperations: '));
  });

  test('every value of the allow list is a plain one, whatever its type', () {
    for (final (name, value) in diagnosticSettingsSummary(diagnosticSettingsOf(settings))) {
      // `<Type>` is what an unknown kind of value is told as: every setting of the list must be one it knows.
      expect(value, isNot(matches(RegExp('^<[A-Za-z_]'))), reason: name);
    }
  });

  test('a value of each kind is turned into a short text', () {
    final told = Map.fromEntries(
      diagnosticSettingsSummary({
        'locale': null,
        'themeMode': ThemeMode.dark,
        'homeLayout': const Size(1.5, 2),
        'twoPaneLayout': const Offset(3, 4.25),
        'textScaleFactor': 1.15,
        'threadReverseOrder': true,
        'fontFamily': 'Noto Sans',
        'appIcon': 'x' * 40,
        'netClientUseProxy': const [1, 2],
      }).map((e) => MapEntry(e.$1, e.$2)),
    );
    expect(told, {
      'locale': '-',
      'themeMode': 'dark',
      'textScaleFactor': '1.15',
      'fontFamily': 'Noto Sans',
      'homeLayout': '1.5x2.0',
      'twoPaneLayout': '3.0,4.25',
      'threadReverseOrder': 'true',
      'netClientUseProxy': '<List<int>>',
      'appIcon': '<40 chars>',
    });
  });

  test('a setting that can not be read is left out alone', () {
    final values = diagnosticSettingsOf(
      settings,
      read: (s, name) => name == 'themeMode' ? throw StateError('x') : null,
    );
    expect(values.keys, isNot(contains('themeMode')));
    expect(values.keys, contains('locale'));
    expect(values.length, diagnosticSettingNames.length - 1);
    // One line names the setting left out, never its value.
    final lines = talker.history.map((e) => e.generateTextMessage()).where((e) => e.contains('diagnostics'));
    expect(lines, hasLength(1));
    expect(lines.single, contains('themeMode'));
  });

  test('a value whose text fails is left out alone', () {
    final skipped = <String>[];
    final told = diagnosticSettingsSummary(
      {'locale': 'zh-CN', 'themeMode': _BrokenSize(), 'fontFamily': 'a'},
      onSkip: (name, _) => skipped.add(name),
    );
    expect(told, [('locale', 'zh-CN'), ('fontFamily', 'a')]);
    expect(skipped, ['themeMode']);
  });
}

final class _BrokenSize extends Size {
  _BrokenSize() : super(1, 2);

  @override
  double get width => throw StateError('broken');
}
