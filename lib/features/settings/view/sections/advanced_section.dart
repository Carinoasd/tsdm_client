part of '../settings_page.dart';

/// Network: debug showcase (debug builds), the proxy and the forum API.
class _AdvancedSection extends StatelessWidget {
  const _AdvancedSection();

  @override
  Widget build(BuildContext context) => SettingsSelect(
    select: (m) => (
      enableAppPostRenderer: m.enableAppPostRenderer,
      netClientProxy: m.netClientProxy,
      netClientUseProxy: m.netClientUseProxy,
      useDetectedProxyWhenStartup: m.useDetectedProxyWhenStartup,
    ),
    builder: (context, s) {
      final netClientUseProxy = s.netClientUseProxy;
      final netClientProxy = s.netClientProxy;
      final useDetectedProxy = s.useDetectedProxyWhenStartup;
      String? host;
      String? port;
      if (netClientProxy.contains(':')) {
        final parts = netClientProxy.split(':');
        host = parts.elementAtOrNull(0);
        port = parts.elementAtOrNull(1);
      }
      final proxyAutomated = isAndroid || isMacOS || isIOS;
      final tr = context.t.settingsPage.advancedSection;

      return AppTileGroup(
        title: tr.title,
        icon: Icons.settings_ethernet_outlined,
        children: [
          if (!kReleaseMode)
            SectionListTile(
              leading: const Icon(Icons.developer_mode_outlined),
              title: const Text('DEBUG SHOWCASE'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async =>
                  Navigator.push(context, MaterialPageRoute<void>(builder: (context) => const DebugShowcasePage())),
            ),
          if (proxyAutomated)
            SectionListTile(
              leading: Icon(MdiIcons.networkOutline),
              title: Text(tr.useProxy),
              subtitle: Text(tr.proxySettings.automatedOnPlatform),
              enabled: false,
            )
          else
            SectionSwitchListTile(
              secondary: Icon(MdiIcons.networkOutline),
              title: Text(tr.useProxy),
              value: netClientUseProxy,
              onChanged: (v) {
                context.read<SettingsBloc>().add(SettingsValueChanged(SettingsKeys.netClientUseProxy, v));
                showSnackBar(context: context, message: context.t.general.affectAfterRestart);
              },
            ),
          if (!proxyAutomated)
            SectionSwitchListTile(
              secondary: const Icon(Symbols.network_manage),
              title: Text(tr.proxySettings.useDetectProxy.title),
              subtitle: Text(tr.proxySettings.useDetectProxy.detail),
              value: useDetectedProxy,
              onChanged: netClientUseProxy && !proxyAutomated
                  ? (v) async => context.read<SettingsBloc>().add(
                      SettingsValueChanged(SettingsKeys.useDetectedProxyWhenStartup, v),
                    )
                  : null,
            ),
          if (!proxyAutomated)
            SectionListTile(
              enabled: netClientUseProxy && !useDetectedProxy && !proxyAutomated,
              key: const ValueKey('settings-proxy'),
              leading: const Icon(Icons.network_locked_outlined),
              title: Text(tr.proxySettings.title),
              subtitle: host == null || port == null ? null : Text('$host:$port'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async => showDialog<void>(
                context: context,
                builder: (context) => RootPage(DialogPaths.setupProxy, ProxySettingsDialog(host: host, port: port)),
                barrierDismissible: false,
              ),
            ),
          const _ForumApiTile(),
          SectionSwitchListTile(
            key: const ValueKey('settings-app-post-renderer'),
            secondary: const Icon(Icons.science_outlined),
            title: Text(tr.appPostRenderer.title),
            subtitle: Text(tr.appPostRenderer.detail),
            value: s.enableAppPostRenderer,
            onChanged: (v) =>
                context.read<SettingsBloc>().add(SettingsValueChanged(SettingsKeys.enableAppPostRenderer, v)),
          ),
        ],
      );
    },
  );
}

/// The forum's app API: the plugin version the forum last named ([TsdmAppApi.pluginInfo], from a `status` or
/// `notify` answer of this run; nothing is asked here) beside the version this app was written against
/// ([expectedTsdmAppVersion]), and a line telling that some pages are parsed from the web page when the forum's is
/// older.
class _ForumApiTile extends StatelessWidget {
  const _ForumApiTile();

  @override
  Widget build(BuildContext context) {
    final tr = context.t.settingsPage.advancedSection.forumApi;
    return ValueListenableBuilder<TsdmAppPluginInfo?>(
      valueListenable: TsdmAppApi.pluginInfo,
      builder: (context, info, _) {
        final older = info?.olderThanExpected ?? false;
        final line = info == null
            ? tr.notDetected(expected: expectedTsdmAppVersion)
            : tr.detected(seen: info.version, expected: expectedTsdmAppVersion);
        return SectionListTile(
          key: const ValueKey('settings-forum-api'),
          leading: const Icon(Icons.api_outlined),
          title: Text(tr.title),
          subtitle: Text(older ? '$line\n${tr.olderNote}' : line),
          isThreeLine: older,
        );
      },
    );
  }
}
