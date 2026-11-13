// Copyright (C) 2026 Carinoasd. MIT License.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/features/update/models/changelog_release.dart';
import 'package:tsdm_client/features/update/repository/whats_new_controller.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_display.dart';
import 'package:tsdm_client/utils/git_info.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/indicator.dart';
import 'package:url_launcher/url_launcher.dart';

List<ChangelogRelease> _parseBundled(void _) => parseChangelog(bundledChangelog());

/// The releases in the changelog built into the app, newest first, parsed off the UI isolate.
Future<List<ChangelogRelease>> loadBundledReleases() => compute(_parseBundled, null);

/// The changelog of the app, a card per release from the newest to the oldest.
///
/// Opened from an update offer, the releases after [since] up to the running version are marked as new ([since] null
/// marks the running version only).
class WhatsNewPage extends StatefulWidget {
  /// Constructor.
  const WhatsNewPage({this.since, this.markNew = false, this.currentVersion, this.loadReleases, super.key});

  /// Last version seen before this update.
  final String? since;

  /// Mark the releases new since [since].
  final bool markNew;

  /// `x.y.z` of the running app, the version of the build by default.
  final String? currentVersion;

  /// Where the releases come from, the changelog built in by default.
  final Future<List<ChangelogRelease>> Function()? loadReleases;

  @override
  State<WhatsNewPage> createState() => _WhatsNewPageState();
}

class _WhatsNewPageState extends State<WhatsNewPage> {
  late final Future<List<ChangelogRelease>> _releases = (widget.loadReleases ?? loadBundledReleases)();

  String get _currentVersion => widget.currentVersion ?? appVersion.split('+').first;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(context.t.settingsPage.othersSection.changelog)),
      body: SafeArea(
        top: false,
        bottom: false,
        child: FutureBuilder(
          future: _releases,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return AppStateView(icon: Icons.error_outline, error: true, message: context.t.general.failedToLoad);
            }
            final releases = snapshot.data;
            if (releases == null) {
              return const CenteredCircularIndicator();
            }
            final shown = releases.where((e) => !e.isEmpty).toList();
            return AppCenteredList(
              maxWidth: appReadingMaxWidth,
              builder: (context, padding, _) => ListView.separated(
                key: const ValueKey('whats-new-list'),
                padding: padding.copyWith(top: 12, bottom: 24 + MediaQuery.paddingOf(context).bottom),
                itemCount: shown.length,
                separatorBuilder: (_, _) => const SizedBox(height: appSurfaceGap),
                itemBuilder: (context, index) {
                  final release = shown[index];
                  return _ReleaseCard(
                    key: ValueKey('whats-new-release-${release.version}'),
                    release: release,
                    isNew: widget.markNew && isNewRelease(release.version, since: widget.since, until: _currentVersion),
                  );
                },
              ),
            );
          },
        ),
      ),
    );
  }
}

class _ReleaseCard extends StatelessWidget {
  const _ReleaseCard({required this.release, required this.isNew, super.key});

  final ChangelogRelease release;

  final bool isNew;

  String _sectionTitle(BuildContext context, ChangelogSection section) {
    final tr = context.t.whatsNew.sections;
    return switch (section.kind) {
      ChangelogSectionKind.added => tr.added,
      ChangelogSectionKind.changed => tr.changed,
      ChangelogSectionKind.fixed => tr.fixed,
      ChangelogSectionKind.removed => tr.removed,
      ChangelogSectionKind.knownIssues => tr.knownIssues,
      ChangelogSectionKind.other => context.displayText(section.title),
    };
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final versionStyle = textTheme.titleMedium?.copyWith(
      fontWeight: FontWeight.bold,
      color: isNew ? colorScheme.onPrimaryContainer : null,
    );
    Widget markdown(String data) => MarkdownBody(
      data: context.displayText(data),
      onTapLink: (_, href, _) async {
        final uri = href == null ? null : Uri.tryParse(href);
        if (uri != null && (uri.scheme == 'https' || uri.scheme == 'http')) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        }
      },
    );
    return AppSurface(
      padding: edgeInsetsL16T16R16B16,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (isNew)
                DecoratedBox(
                  key: const ValueKey('whats-new-release-new'),
                  decoration: BoxDecoration(
                    color: colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(appInnerRadius),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                    child: Text(release.version, style: versionStyle),
                  ),
                )
              else
                Text(release.version, style: versionStyle),
              const Spacer(),
              if (release.date case final date?)
                Text(date, style: textTheme.labelMedium?.copyWith(color: colorScheme.onSurfaceVariant)),
            ],
          ),
          if (release.intro.isNotEmpty) ...[sizedBoxW8H8, markdown(release.intro)],
          for (final section in release.sections) ...[
            AppSectionHeader(_sectionTitle(context, section), padding: const EdgeInsets.only(top: 12, bottom: 4)),
            markdown(section.body),
          ],
        ],
      ),
    );
  }
}

/// Open the changelog marking the releases of the update offered by [controller], and do not offer it again.
Future<void> openWhatsNew(BuildContext context, WhatsNewController controller) async {
  final prompt = controller.prompt.value;
  if (prompt == null) {
    return;
  }
  unawaited(controller.markSeen());
  await context.pushNamed(
    ScreenPaths.localChangelog,
    queryParameters: {'new': '1', 'since': ?prompt.since},
  );
}
