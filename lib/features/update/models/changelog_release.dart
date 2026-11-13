// Copyright (C) 2026 Carinoasd. MIT License.

import 'dart:convert';

/// Kind of a `### ...` section of a release in `CHANGELOG.md` (Keep a Changelog).
enum ChangelogSectionKind {
  /// `### Added`.
  added,

  /// `### Changed`.
  changed,

  /// `### Fixed`.
  fixed,

  /// `### Removed`.
  removed,

  /// `### Known Issues`.
  knownIssues,

  /// Any other heading, shown with its own text.
  other
  ;

  /// The kind of the heading [title], [other] when unknown.
  static ChangelogSectionKind fromTitle(String title) => switch (title.trim().toLowerCase()) {
    'added' => added,
    'changed' => changed,
    'fixed' => fixed,
    'removed' => removed,
    'known issues' => knownIssues,
    _ => other,
  };
}

/// One `### ...` section of a release: its heading and the markdown under it.
final class ChangelogSection {
  /// Constructor.
  const ChangelogSection({required this.title, required this.body});

  /// Heading text, `Added`, `Fixed`…
  final String title;

  /// Markdown under the heading, trimmed; the list items keep their nesting.
  final String body;

  /// Kind of [title].
  ChangelogSectionKind get kind => ChangelogSectionKind.fromTitle(title);
}

/// One released version in `CHANGELOG.md`.
final class ChangelogRelease {
  /// Constructor.
  const ChangelogRelease({required this.version, required this.date, required this.intro, required this.sections});

  /// `1.55.0`.
  final String version;

  /// `2026-11-13`, null when the heading has none.
  final String? date;

  /// Markdown between the version heading and its first section, empty when none.
  final String intro;

  /// Sections in the order of the file, the empty ones dropped.
  final List<ChangelogSection> sections;

  /// Nothing to show.
  bool get isEmpty => intro.isEmpty && sections.isEmpty;
}

final _releaseHeading = RegExp(r'^## \[([^\]]+)\](?:\s*-\s*(\S+))?');
final _sectionHeading = RegExp(r'^### (.+?)\s*$');
final _linkDefinition = RegExp(r'^\[[^\]]+\]:\s*\S+');
final _versionNumbers = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)');

/// The `x.y.z` of [version] (`1.55.0+170`, `1.27.1-blocking.3+82`, `1.55.0`), null when it has none.
List<int>? parseVersionNumbers(String version) {
  final m = _versionNumbers.firstMatch(version.trim());
  if (m == null) {
    return null;
  }
  return [int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!)];
}

/// Whether [version] is a plain release version: `x.y.z` with at most a `+build`, no pre-release part.
bool isReleaseVersion(String version) => RegExp(r'^\d+\.\d+\.\d+(\+\d+)?$').hasMatch(version.trim());

/// Compare the `x.y.z` of two versions number by number; versions without one sort first.
int compareVersions(String a, String b) {
  final va = parseVersionNumbers(a);
  final vb = parseVersionNumbers(b);
  if (va == null || vb == null) {
    return (va == null ? 0 : 1) - (vb == null ? 0 : 1);
  }
  for (var i = 0; i < 3; i++) {
    final c = va[i].compareTo(vb[i]);
    if (c != 0) {
      return c;
    }
  }
  return 0;
}

/// The versions of the release headings of [changelog], in the order of the file, without parsing their content.
///
/// `[Unreleased]` and headings without an `x.y.z` are left out.
List<String> changelogVersions(String changelog) => [
  for (final line in const LineSplitter().convert(changelog))
    if (_releaseHeading.firstMatch(line) case final m? when parseVersionNumbers(m.group(1)!) != null)
      m.group(1)!.trim(),
];

/// Parse the releases of a Keep a Changelog [changelog], in the order of the file (newest first).
///
/// The head of the file, `[Unreleased]` and link reference definitions are left out; a release without any content
/// is kept with empty [ChangelogRelease.sections].
List<ChangelogRelease> parseChangelog(String changelog) {
  final releases = <ChangelogRelease>[];
  String? version;
  String? date;
  final intro = <String>[];
  final sections = <ChangelogSection>[];
  String? sectionTitle;
  final sectionLines = <String>[];

  void closeSection() {
    final body = _trimBlock(sectionLines);
    if (sectionTitle != null && body.isNotEmpty) {
      sections.add(ChangelogSection(title: sectionTitle!, body: body));
    }
    sectionTitle = null;
    sectionLines.clear();
  }

  void closeRelease() {
    closeSection();
    if (version != null) {
      releases.add(
        ChangelogRelease(version: version!, date: date, intro: _trimBlock(intro), sections: List.of(sections)),
      );
    }
    version = null;
    date = null;
    intro.clear();
    sections.clear();
  }

  // Not in a release: the head of the file or `[Unreleased]`.
  var skipping = true;
  for (final line in const LineSplitter().convert(changelog)) {
    if (line.startsWith('## ')) {
      closeRelease();
      final m = _releaseHeading.firstMatch(line);
      final name = m?.group(1)?.trim();
      skipping = name == null || parseVersionNumbers(name) == null;
      if (!skipping) {
        version = name;
        date = m!.group(2);
      }
      continue;
    }
    if (skipping || line.startsWith('# ') || _linkDefinition.hasMatch(line)) {
      continue;
    }
    if (_sectionHeading.firstMatch(line) case final m?) {
      closeSection();
      sectionTitle = m.group(1);
      continue;
    }
    (sectionTitle == null ? intro : sectionLines).add(line);
  }
  closeRelease();
  return releases;
}

/// [lines] joined, blank lines at both ends removed and runs of blank lines kept to one.
String _trimBlock(List<String> lines) {
  final out = <String>[];
  for (final line in lines) {
    final blank = line.trim().isEmpty;
    if (blank && (out.isEmpty || out.last.isEmpty)) {
      continue;
    }
    out.add(blank ? '' : line.trimRight());
  }
  while (out.isNotEmpty && out.last.isEmpty) {
    out.removeLast();
  }
  return out.join('\n');
}
