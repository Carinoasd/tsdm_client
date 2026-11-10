import 'package:flutter/material.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/netdisk/models/netdisk_link.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_display.dart';
import 'package:tsdm_client/utils/clipboard.dart';

/// A row of chips under an online storage link of a post: the service, its codes (tap to copy) and the button opening
/// the share.
class NetdiskRow extends StatelessWidget {
  /// Constructor.
  const NetdiskRow({required this.link, super.key});

  /// The link the row is for.
  final NetdiskLink link;

  @override
  Widget build(BuildContext context) {
    final extractCode = link.extractCode;
    final unzipPassword = link.unzipPassword;
    return Align(
      alignment: Alignment.centerLeft,
      child: Wrap(
        spacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _chip(context, icon: Icons.cloud_outlined, label: context.displayText(link.provider.name)),
          if (extractCode != null)
            _chip(
              context,
              icon: Icons.key_outlined,
              label: '${context.t.netdisk.extractCode} $extractCode',
              onPressed: () async => copyToClipboard(context, extractCode),
            ),
          if (unzipPassword != null)
            _chip(
              context,
              icon: Icons.lock_open_outlined,
              label: '${context.t.netdisk.unzipPassword} $unzipPassword',
              onPressed: () async => copyToClipboard(context, unzipPassword),
            ),
          _chip(
            context,
            icon: Icons.open_in_new,
            label: context.t.netdisk.open,
            onPressed: () async {
              // The code goes along in the url where the service takes it, otherwise it is copied for the page to ask.
              if (link.needsCopyBeforeOpen) {
                await copyToClipboard(context, link.extractCode!);
                if (!context.mounted) {
                  return;
                }
              }
              await context.dispatchAsUrl(link.openUrl, external: true);
            },
          ),
        ],
      ),
    );
  }

  Widget _chip(
    BuildContext context, {
    required IconData icon,
    required String label,
    Future<void> Function()? onPressed,
  }) {
    final avatar = Icon(icon, size: 16);
    const density = VisualDensity(horizontal: -4, vertical: -4);
    if (onPressed == null) {
      return Chip(
        avatar: avatar,
        label: Text(label),
        visualDensity: density,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      );
    }
    return ActionChip(
      avatar: avatar,
      label: Text(label),
      onPressed: onPressed,
      visualDensity: density,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }
}
