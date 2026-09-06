// Copyright (C) 2026 Carinoasd. MIT License.
//
// The in-app update check downloads `version.json` from the repository. These tests pin the parser to every payload
// shape the HTTP clients can deliver and make sure the committed file describes the version being built.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/update/models/latest_version_info.dart';

void main() {
  group('parseLatestVersionInfo', () {
    const json = r'{"version": "1.18.0", "versionCode": 65, "changelog": "### Fixed\n\n- a\n"}';

    test('accepts a JSON string', () {
      final info = parseLatestVersionInfo(json);
      expect(info.version, '1.18.0');
      expect(info.versionCode, 65);
      expect(info.changelog, startsWith('### Fixed'));
    });

    test('accepts an already decoded map', () {
      final info = parseLatestVersionInfo(jsonDecode(json));
      expect(info.versionCode, 65);
    });

    test('accepts raw utf-8 bytes', () {
      final info = parseLatestVersionInfo(utf8.encode(json));
      expect(info.version, '1.18.0');
    });

    test('rejects html, arrays, missing or mistyped fields', () {
      expect(() => parseLatestVersionInfo('<html>blocked</html>'), throwsFormatException);
      expect(() => parseLatestVersionInfo('[1, 2]'), throwsFormatException);
      expect(() => parseLatestVersionInfo('{"version": "1.18.0"}'), throwsFormatException);
      expect(
        () => parseLatestVersionInfo('{"version": "1.18.0", "versionCode": "65", "changelog": ""}'),
        throwsFormatException,
      );
      expect(() => parseLatestVersionInfo(null), throwsFormatException);
      expect(() => parseLatestVersionInfo(42), throwsFormatException);
    });
  });

  group('version.json in the repository', () {
    test('matches pubspec.yaml and points at the official repository', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      final m = RegExp(r'^version:\s*([0-9.]+)\+([0-9]+)\s*$', multiLine: true).firstMatch(pubspec)!;
      final info = parseLatestVersionInfo(File('version.json').readAsStringSync());
      expect(info.version, m.group(1));
      expect(info.versionCode, int.parse(m.group(2)!));
      expect(info.changelog, isNotEmpty);
      expect(upgradeVersionInfoUrl, 'https://raw.githubusercontent.com/Carinoasd/tsdm_client/master/version.json');
    });
  });
}
