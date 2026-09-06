// Copyright (C) 2026 Carinoasd. MIT License.
//
// Regenerate `version.json` in the repository root from `pubspec.yaml` and `CHANGELOG.md`.
//
// The app's "check latest version" downloads this file from the repository (see `upgradeVersionInfoUrl`), so it
// must be refreshed in the same commit that bumps the version. `test/regression/test_042_version_info_test.dart`
// fails when the two drift apart.
//
// Usage: dart scripts/write_version_json.dart
import 'dart:convert';
import 'dart:io';

void main() {
  final pubspec = File('pubspec.yaml').readAsStringSync();
  final version = RegExp(r'^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)\s*$', multiLine: true).firstMatch(pubspec);
  if (version == null) {
    stderr.writeln('pubspec.yaml has no "version: x.y.z+N" line');
    exit(1);
  }
  final name = version.group(1)!;
  final code = int.parse(version.group(2)!);

  final changelog = File('CHANGELOG.md').readAsStringSync();
  final section = RegExp(
    r'^## \[' + RegExp.escape(name) + r'\][^\n]*\n(.*?)(?=^## \[|\Z)',
    multiLine: true,
    dotAll: true,
  ).firstMatch(changelog);
  if (section == null) {
    stderr.writeln('CHANGELOG.md has no "## [$name]" section');
    exit(1);
  }
  final notes = section.group(1)!.trim();

  const encoder = JsonEncoder.withIndent('  ');
  File(
    'version.json',
  ).writeAsStringSync('${encoder.convert({'version': name, 'versionCode': code, 'changelog': notes})}\n');
  stdout.writeln('version.json: $name+$code, ${notes.split('\n').length} changelog lines');
}
