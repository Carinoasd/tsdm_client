import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:tsdm_client/constants/constants.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/update/cubit/update_cubit.dart';
import 'package:tsdm_client/features/update/widgets/update_download_card.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/git_info.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/section_list_tile.dart';
import 'package:url_launcher/url_launcher.dart';

/// Page for app update.
class UpdatePage extends StatefulWidget {
  /// Constructor.
  const UpdatePage({super.key});

  @override
  State<UpdatePage> createState() => _UpdatePageState();
}

class _UpdatePageState extends State<UpdatePage> {
  /// Current version and the check button; the source tip used to sit in a fixed 40 pixels app bar strip that cut it
  /// at large text scales.
  Widget _buildVersionSurface(BuildContext context, UpdateCubitState state) {
    final tr = context.t.updatePage;
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    return AppSurface(
      padding: edgeInsetsL16T16R16B16,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const AppIconTile(Icons.system_update_outlined, size: 48),
              sizedBoxW12H12,
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.t.aboutPage.version,
                      style: textTheme.labelMedium?.copyWith(color: colorScheme.outline),
                    ),
                    Text(appFullVersion, style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
            ],
          ),
          sizedBoxW12H12,
          Text(tr.sourceTip, style: textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant)),
          sizedBoxW12H12,
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: FilledButton.tonalIcon(
              icon: state.loading ? sizedCircularProgressIndicator : const Icon(Icons.refresh_outlined),
              label: Text(tr.checkLatest),
              onPressed: state.loading ? null : () async => context.read<UpdateCubit>().checkUpdate(),
            ),
          ),
        ],
      ),
    );
  }

  /// Result of the last check, only what the cubit holds: nothing before a check.
  ///
  /// The app wide update dialog is not shown on this page, so a newer version is described here with its changelog.
  Widget? _buildResult(BuildContext context, UpdateCubitState state) {
    final tr = context.t.updatePage;
    if (state.loading) {
      return null;
    }
    final info = state.latestVersionInfo;
    if (info == null) {
      return state.notice ? AppNoticeBanner(message: tr.failed, tone: AppNoticeTone.error) : null;
    }
    final current = appVersion.split('+').last.parseToInt() ?? 0;
    if (info.versionCode <= current) {
      return AppNoticeBanner(message: tr.alreadyLatest, icon: Icons.check_circle_outline);
    }
    return AppNoticeBanner(
      title: tr.availableDialog.title,
      message: tr.availableDialog.versionUpgrade(
        oldVersion: appVersion.split('+').first,
        newVersion: info.version,
      ),
      icon: Icons.new_releases_outlined,
    );
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.updatePage;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr.title),
        actions: [
          BlocSelector<UpdateCubit, UpdateCubitState, bool>(
            selector: (state) => state.loading,
            builder: (context, state) => IconButton(
              icon: state ? sizedCircularProgressIndicator : const Icon(Icons.refresh_outlined),
              tooltip: tr.checkLatest,
              onPressed: state ? null : () async => context.read<UpdateCubit>().checkUpdate(),
            ),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: BlocBuilder<UpdateCubit, UpdateCubitState>(
          builder: (context, state) {
            final result = _buildResult(context, state);
            final info = state.latestVersionInfo;
            final current = appVersion.split('+').last.parseToInt() ?? 0;
            final newer = !state.loading && info != null && info.versionCode > current ? info : null;
            return AppCenteredList(
              maxWidth: appFormMaxWidth,
              builder: (context, padding, _) => ListView(
                padding: padding.copyWith(top: 12, bottom: 24),
                children: [
                  _buildVersionSurface(context, state),
                  if (result != null) ...[const SizedBox(height: appSurfaceGap), result],
                  UpdateDownloadCard(cubit: context.read<UpdateCubit>().download, latest: newer),
                  if (newer != null && newer.changelog.isNotEmpty) ...[
                    const SizedBox(height: appSurfaceGap),
                    AppSurface(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          AppSectionHeader(tr.availableDialog.changelog, icon: Icons.history_outlined),
                          AppInsetBlock(
                            outlined: true,
                            padding: edgeInsetsL12T12R12B12,
                            child: MarkdownBody(data: newer.changelog),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: appSurfaceGap),
                  AppTileGroup(
                    children: [
                      SectionListTile(
                        leading: const Icon(Icons.campaign_outlined),
                        title: Text(tr.announcementThread),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () async => context.dispatchAsUrl('forum.php?mod=viewthread&tid=1265238'),
                      ),
                      SectionListTile(
                        leading: Icon(MdiIcons.github),
                        title: Text(tr.download.github),
                        subtitle: Text(tr.download.githubTip),
                        trailing: const Icon(Icons.open_in_new),
                        onTap: () async =>
                            launchUrl(Uri.parse(upgradeGithubReleaseUrl), mode: LaunchMode.externalApplication),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
