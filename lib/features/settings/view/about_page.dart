import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_svg/svg.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/constants.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/settings/widgets/support_development_dialog.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/clipboard.dart';
import 'package:tsdm_client/utils/git_info.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/section_list_tile.dart';
import 'package:url_launcher/url_launcher.dart';

/// Page to show the about information.
class AboutPage extends StatelessWidget {
  /// Constructor.
  const AboutPage({super.key});

  /// Logo, name, what the app is and the version, the head of the page.
  Widget _buildHead(BuildContext context) {
    final tr = context.t.aboutPage;
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    return AppSurface(
      padding: edgeInsetsL16T16R16B16,
      child: Column(
        children: [
          SvgPicture.asset(assetsLogoSvgPath, width: 120, height: 120),
          sizedBoxW12H12,
          Text(
            context.t.appName,
            textAlign: TextAlign.center,
            style: textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
          ),
          sizedBoxW4H4,
          Text(
            tr.description,
            textAlign: TextAlign.center,
            style: textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant),
          ),
          sizedBoxW12H12,
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              AppInfoPill(icon: Icons.terminal_outlined, label: appFullVersion, tooltip: tr.version),
              AppInfoPill(icon: Icons.balance_outlined, label: 'MIT license', tooltip: tr.license),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.aboutPage;
    return Scaffold(
      appBar: AppBar(
        title: Text(context.t.settingsPage.othersSection.about),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy_outlined),
            tooltip: tr.copyEnvironmentInfo,
            onPressed: () async {
              const data =
                  '''
## Info

* Version: $appFullVersion
* Flutter: $flutterVersion $flutterChannel ($flutterFrameworkRevision)
* Dart: $dartVersion
''';
              await copyToClipboard(context, data);
            },
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: AppCenteredList(
          maxWidth: appFormMaxWidth,
          builder: (context, padding, _) => ListView(
            padding: padding.copyWith(top: 12, bottom: 24),
            children: [
              _buildHead(context),
              const SizedBox(height: appSurfaceGap),
              AppTileGroup(
                title: tr.linksSection,
                icon: Icons.link_outlined,
                children: [
                  // The voluntary support entry first: it opens the dialog with the donation code and the feature
                  // request link, nothing is paid from here.
                  SectionListTile(
                    leading: Icon(Icons.favorite_border, color: Theme.of(context).colorScheme.primary),
                    title: Text(tr.supportDevelopment),
                    subtitle: Text(tr.supportDevelopmentSubtitle),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () async => showDialog<void>(
                      context: context,
                      builder: (_) => const SupportDevelopmentDialog(),
                    ),
                  ),
                  SectionListTile(
                    leading: const Icon(Icons.home_max_outlined),
                    title: Text(tr.forumHomepage),
                    subtitle: const Text(baseUrl),
                    trailing: const Icon(Icons.open_in_new),
                    onTap: () async {
                      await launchUrl(Uri.parse(baseUrl), mode: LaunchMode.externalApplication);
                    },
                  ),
                  SectionListTile(
                    leading: const Icon(Icons.home_outlined),
                    title: Text(tr.homepage),
                    subtitle: const Text('https://github.com/Carinoasd/tsdm_client'),
                    trailing: const Icon(Icons.open_in_new),
                    onTap: () async {
                      await launchUrl(
                        Uri.parse('https://github.com/Carinoasd/tsdm_client'),
                        mode: LaunchMode.externalApplication,
                      );
                    },
                  ),
                ],
              ),
              const SizedBox(height: appSurfaceGap),
              AppTileGroup(
                title: tr.buildSection,
                icon: Icons.info_outline,
                children: [
                  SectionListTile(
                    leading: const Icon(Icons.app_shortcut_outlined),
                    title: Text(tr.packageName),
                    subtitle: const Text('com.tsdm.tsdm_client'),
                  ),
                  SectionListTile(
                    leading: const Icon(Icons.terminal_outlined),
                    title: Text(tr.version),
                    subtitle: const Text(appFullVersion),
                  ),
                  SectionListTile(
                    key: const ValueKey('about-changelog'),
                    leading: const Icon(Icons.history_outlined),
                    title: Text(context.t.settingsPage.othersSection.changelog),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () async => context.pushNamed(ScreenPaths.localChangelog),
                  ),
                  SectionListTile(
                    leading: const FlutterLogo(),
                    title: Text(tr.flutterVersion),
                    subtitle: const Text('$flutterVersion ($flutterChannel) - $flutterFrameworkRevision'),
                    trailing: const Icon(Icons.open_in_new),
                    onTap: () async {
                      await launchUrl(Uri.parse('https://flutter.dev/'), mode: LaunchMode.externalApplication);
                    },
                  ),
                  SectionListTile(
                    leading: SvgPicture.asset(assetDartLogoPath, width: 22, height: 22),
                    title: Text(tr.dartVersion),
                    subtitle: const Text(dartVersion),
                    trailing: const Icon(Icons.open_in_new),
                    onTap: () async {
                      await launchUrl(Uri.parse('https://dart.dev/'), mode: LaunchMode.externalApplication);
                    },
                  ),
                  SectionListTile(
                    leading: const Icon(Icons.balance_outlined),
                    title: Text(tr.license),
                    subtitle: const Text('MIT license'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () async => context.pushNamed(ScreenPaths.license),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
