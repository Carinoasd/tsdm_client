// The changelog built into the app (What's new, P8): the Keep a Changelog parser on every shape of `CHANGELOG.md`, the
// version comparisons, and the guard that the changelog built in describes the version being built.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/features/update/models/changelog_release.dart';
import 'package:tsdm_client/features/update/models/latest_version_info.dart';

const _changelog = '''
# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added

- 还没发布的条目。

## [2.1.0] - 2026-12-01

需要论坛接口插件 3.9.0。

### Added

- **加粗**的条目。
- 有子项的条目：
  - 子项一。
  - 子项二。

- 空行隔开的条目。

### Changed

### Fixed


- 修复一。


### Known Issues

- 已知问题。

### Removed

- 移除一项。

### Security

- 其他标题。

## [2.0.1]

### Fixed

- 没有日期的版本。

## [2.0.0] - 2026-11-01

## [1.10.0] - 2026-10-01

### Fixed

- 1.10。

## [1.9.0] - 2026-09-01

### Fixed

- 1.9。

[2.1.0]: https://example.com/compare/v2.0.1...v2.1.0
''';

void main() {
  group('parseChangelog', () {
    final releases = parseChangelog(_changelog);
    ChangelogRelease release(String v) => releases.firstWhere((e) => e.version == v);

    test('skips the head and [Unreleased], keeps the file order', () {
      expect(releases.map((e) => e.version), ['2.1.0', '2.0.1', '2.0.0', '1.10.0', '1.9.0']);
      expect(releases.expand((e) => e.sections).map((e) => e.body).join(), isNot(contains('还没发布')));
    });

    test('reads the date, the intro and the sections in order, empty ones dropped', () {
      final r = release('2.1.0');
      expect(r.date, '2026-12-01');
      expect(r.intro, '需要论坛接口插件 3.9.0。');
      expect(r.sections.map((e) => e.kind), [
        ChangelogSectionKind.added,
        ChangelogSectionKind.fixed,
        ChangelogSectionKind.knownIssues,
        ChangelogSectionKind.removed,
        ChangelogSectionKind.other,
      ]);
      expect(r.sections.last.title, 'Security');
    });

    test('keeps bold, nesting and loose lists as markdown, blank runs folded to one', () {
      final added = release('2.1.0').sections.first.body;
      expect(added, '- **加粗**的条目。\n- 有子项的条目：\n  - 子项一。\n  - 子项二。\n\n- 空行隔开的条目。');
      expect(release('2.1.0').sections[1].body, '- 修复一。');
    });

    test('link definitions are not content', () {
      expect(release('1.9.0').sections.single.body, '- 1.9。');
    });

    test('a release without a date or without content', () {
      expect(release('2.0.1').date, isNull);
      expect(release('2.0.1').sections.single.body, '- 没有日期的版本。');
      expect(release('2.0.0').isEmpty, isTrue);
    });

    test('changelogVersions reads only the headings', () {
      expect(changelogVersions(_changelog), ['2.1.0', '2.0.1', '2.0.0', '1.10.0', '1.9.0']);
      expect(parseChangelog(''), isEmpty);
      expect(parseChangelog('# Changelog\n\n## [Unreleased]\n'), isEmpty);
    });
  });

  group('versions', () {
    test('compare number by number', () {
      expect(compareVersions('1.10.0', '1.9.0'), greaterThan(0));
      expect(compareVersions('1.9.9', '1.10.0'), lessThan(0));
      expect(compareVersions('1.55.0+170', '1.55.0'), 0);
      expect(compareVersions('2.0.0', '1.99.99'), greaterThan(0));
      expect(compareVersions('1.27.1-blocking.3+82', '1.27.1'), 0);
    });

    test('release builds have no pre-release part', () {
      expect(isReleaseVersion('1.55.0+170'), isTrue);
      expect(isReleaseVersion('1.55.0'), isTrue);
      expect(isReleaseVersion('1.27.1-blocking.3+82'), isFalse);
      expect(isReleaseVersion('dev'), isFalse);
      expect(parseVersionNumbers('dev'), isNull);
    });
  });

  group('CHANGELOG.md of the repository', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final version = RegExp(r'^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+', multiLine: true).firstMatch(pubspec)!.group(1)!;
    final releases = parseChangelog(File('CHANGELOG.md').readAsStringSync());

    test('the newest release is the version in pubspec.yaml, with content', () {
      expect(releases.first.version, version, reason: 'CHANGELOG.md has no "## [$version]" section at the top');
      expect(releases.first.sections, isNotEmpty);
    });

    test('the parsed newest release keeps every line of version.json', () {
      final info = parseLatestVersionInfo(File('version.json').readAsStringSync());
      final r = releases.first;
      final parsed = [r.intro, for (final s in r.sections) '### ${s.title}\n\n${s.body}'].where((e) => e.isNotEmpty);
      String lines(String s) => const LineSplitter().convert(s).where((e) => e.trim().isNotEmpty).join('\n');
      expect(lines(parsed.join('\n\n')), lines(info.changelog));
    });

    test('releases go from the newest to the oldest, every one with content', () {
      for (var i = 1; i < releases.length; i++) {
        expect(
          compareVersions(releases[i - 1].version, releases[i].version),
          greaterThan(0),
          reason: releases[i].version,
        );
      }
      expect(releases.where((e) => e.isEmpty).map((e) => e.version), isEmpty);
      expect(releases.length, changelogVersions(File('CHANGELOG.md').readAsStringSync()).length);
    });

    test('the app builds CHANGELOG.md in through gitsumu', () {
      expect(File('scripts/read_changelog.dart').readAsStringSync(), contains("File('./CHANGELOG.md')"));
      final gitInfo = File('lib/utils/git_info.dart').readAsStringSync();
      expect(gitInfo, contains("@CustomInfo('encodedChangelog')"));
      expect(gitInfo, contains("'./scripts/read_changelog.dart'"));
      expect(File('build.yaml').readAsStringSync(), contains('lib/utils/git_info.dart'));
    });
  });
}
