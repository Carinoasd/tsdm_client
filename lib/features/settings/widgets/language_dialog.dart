import 'package:flutter/material.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/custom_alert_dialog.dart';
import 'package:tsdm_client/widgets/selectable_list_tile.dart';

/// Dialog to let user choose app locale.
class LanguageDialog extends StatelessWidget {
  /// Constructor.
  const LanguageDialog(this.currentLocale, {super.key});

  /// Current using locale.
  final String currentLocale;

  @override
  Widget build(BuildContext context) {
    return CustomAlertDialog.sync(
      title: AppDialogTitle(
        icon: Icons.translate_outlined,
        title: t.settingsPage.appearanceSection.languages.selectLanguage,
      ),
      content: Column(
        children: [
          SelectableListTile(
            leading: currentLocale == '' ? null : const Icon(Icons.phone_android_outlined),
            title: Text(t.settingsPage.appearanceSection.languages.followSystem),
            selected: currentLocale == '',
            onTap: () async => Navigator.of(context).pop((null, true)),
          ),
          const Divider(indent: 24, endIndent: 24),
          ...AppLocale.values.map(
            (e) => SelectableListTile(
              // Named here, not by `e.translations.locale`: a locale not loaded yet named Traditional Chinese "English".
              title: Text(switch (e.languageTag) {
                'en' => 'English',
                'zh-CN' => '简体中文',
                'zh-TW' => '繁體中文',
                final v => throw UnimplementedError(
                  'unsupported '
                  'language tag $v',
                ),
              }),
              subtitle: Text(e.languageTag),
              selected: currentLocale == e.languageTag,
              onTap: () async => Navigator.of(context).pop((e, false)),
            ),
          ),
        ],
      ),
      contentPadding: EdgeInsets.zero,
    );
  }
}
