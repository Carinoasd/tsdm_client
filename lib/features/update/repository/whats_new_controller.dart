// Copyright (C) 2026 Carinoasd. MIT License.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:tsdm_client/features/update/models/changelog_release.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/git_info.dart';

/// The update the user can look at: the app is now [version], last seen at [since].
@immutable
final class WhatsNewPrompt {
  /// Constructor.
  const WhatsNewPrompt({required this.version, required this.since});

  /// Version installed now, `x.y.z`.
  final String version;

  /// Version the user last saw the news of, null when unknown (upgraded from an app that kept no record): only
  /// [version] is new then.
  final String? since;

  @override
  bool operator ==(Object other) => other is WhatsNewPrompt && other.version == version && other.since == since;

  @override
  int get hashCode => Object.hash(version, since);

  @override
  String toString() => 'WhatsNewPrompt($since -> $version)';
}

/// Whether [version] is one of the releases a page opened with [since] and [until] marks as new.
///
/// [since] null marks only [until].
bool isNewRelease(String version, {required String? since, required String until}) =>
    compareVersions(version, until) <= 0 &&
    (since == null ? compareVersions(version, until) == 0 : compareVersions(version, since) > 0);

/// Offers the news of the installed version once after an update.
///
/// The last version the user saw (dismissed the offer or opened the news) is kept in the storage under [storageKey].
/// A new install records the installed version and offers nothing; a version without an entry in the bundled
/// changelog (a build being developed), a pre-release build and a downgrade offer nothing and record nothing.
class WhatsNewController {
  /// Constructor.
  WhatsNewController({
    required Future<String?> Function(String key) read,
    required Future<void> Function(String key, String value) write,
    required String appVersion,
    required List<String> Function() releasedVersions,
  }) : _read = read,
       _write = write,
       _appVersion = appVersion,
       _releasedVersions = releasedVersions;

  /// The controller of the app: the settings storage, the version being run and the changelog built in.
  factory WhatsNewController.forApp(StorageProvider storage) => WhatsNewController(
    read: storage.getString,
    write: storage.saveString,
    appVersion: appVersion,
    releasedVersions: () => changelogVersions(bundledChangelog()),
  );

  /// Key of the last version seen.
  static const storageKey = 'whatsNewSeenVersion';

  final Future<String?> Function(String key) _read;
  final Future<void> Function(String key, String value) _write;
  final String _appVersion;
  final List<String> Function() _releasedVersions;

  /// The offer, null when there is nothing to offer.
  final ValueNotifier<WhatsNewPrompt?> prompt = ValueNotifier(null);

  /// Decide the offer of this start.
  ///
  /// [hadPriorData] tells whether the app stored anything before this start: no record of a seen version and no
  /// prior data is a new install, no record with prior data an update from an app that kept none.
  Future<void> resolve({required bool hadPriorData}) async {
    // A pre-release build records nothing, so its testers still get the offer of the release that follows.
    if (!isReleaseVersion(_appVersion)) {
      return;
    }
    final current = releaseVersionName(_appVersion);
    final seen = await _read(storageKey);
    if (seen == null && !hadPriorData) {
      await _write(storageKey, current);
      return;
    }
    if (seen != null && compareVersions(current, seen) <= 0) {
      return;
    }
    // The changelog is read only when there may be something to offer.
    if (!_releasedVersions().contains(current)) {
      return;
    }
    prompt.value = WhatsNewPrompt(version: current, since: seen);
  }

  /// The user dismissed the offer or opened the news: do not offer this version again.
  ///
  /// A failed write is logged; the offer then comes back at the next start.
  Future<void> markSeen() async {
    final p = prompt.value;
    if (p == null) {
      return;
    }
    prompt.value = null;
    try {
      await _write(storageKey, p.version);
    } on Object catch (e, st) {
      talker.handle(e, st, 'failed to record the update news as seen');
    }
  }

  /// Release resources.
  void dispose() => prompt.dispose();
}

/// `x.y.z` of [version] (`1.55.0+170` gives `1.55.0`).
String releaseVersionName(String version) => version.split('+').first.trim();

/// `x.y.z` of the running app.
String get runningVersionName => releaseVersionName(appVersion);

/// The `CHANGELOG.md` built into the app (see `scripts/read_changelog.dart`).
String bundledChangelog() => utf8.decode(base64Decode(encodedChangelog));
