import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/features/root/view/root_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/app_icon.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/custom_alert_dialog.dart';

/// The name of [icon], for the settings.
String appIconName(BuildContext context, AppIcon icon) {
  final tr = context.t.settingsPage.appearanceSection.appIcon;
  return switch (icon) {
    AppIcon.defaultIcon => tr.defaultIcon,
    AppIcon.dark => tr.dark,
    AppIcon.mono => tr.mono,
    AppIcon.pink => tr.pink,
  };
}

/// Show a dialog to let user select the app icon, [initialIcon] selected.
Future<AppIcon?> showSelectAppIconDialog(BuildContext context, AppIcon initialIcon) async => showDialog<AppIcon>(
  context: context,
  builder: (context) => RootPage(DialogPaths.selectAppIcon, _SelectAppIconDialog(initialIcon)),
);

class _SelectAppIconDialog extends StatelessWidget {
  const _SelectAppIconDialog(this.initialIcon);

  final AppIcon initialIcon;

  @override
  Widget build(BuildContext context) {
    final tr = context.t.settingsPage.appearanceSection.appIcon;
    final scheme = Theme.of(context).colorScheme;
    return CustomAlertDialog.sync(
      title: AppDialogTitle(icon: Icons.apps_outlined, title: tr.title),
      content: GridView.count(
        shrinkWrap: true,
        crossAxisCount: 2,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.95,
        children: [
          for (final icon in AppIcon.values)
            InkWell(
              key: ValueKey('app-icon-${icon.storedName}'),
              borderRadius: BorderRadius.circular(16),
              onTap: () => context.pop(icon),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: icon == initialIcon ? scheme.primary : scheme.outlineVariant,
                    width: icon == initialIcon ? 2 : 1,
                  ),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Image.asset(
                      'assets/images/app_icons/${icon.storedName}.png',
                      width: 72,
                      height: 72,
                      // A missing preview must not take the whole dialog down.
                      errorBuilder: (_, _, _) => const SizedBox(width: 72, height: 72),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      appIconName(context, icon),
                      style: TextStyle(color: icon == initialIcon ? scheme.primary : null),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
