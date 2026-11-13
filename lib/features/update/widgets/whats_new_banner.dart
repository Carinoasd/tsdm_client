// Copyright (C) 2026 Carinoasd. MIT License.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/features/update/repository/whats_new_controller.dart';
import 'package:tsdm_client/features/update/view/whats_new_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// A line at the top of the homepage after an update: the version now installed, open its changelog or dismiss.
///
/// Nothing when there is no update to offer or no [WhatsNewController].
class WhatsNewBanner extends StatelessWidget {
  /// Constructor.
  const WhatsNewBanner({this.controller, this.padding = const EdgeInsets.only(bottom: appSurfaceGap), super.key});

  /// The offer, the one of the app by default.
  final WhatsNewController? controller;

  /// Room around the line when it shows.
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final controller =
        this.controller ?? (getIt.isRegistered<WhatsNewController>() ? getIt.get<WhatsNewController>() : null);
    if (controller == null) {
      return const SizedBox.shrink();
    }
    return ValueListenableBuilder(
      valueListenable: controller.prompt,
      builder: (context, prompt, _) {
        if (prompt == null) {
          return const SizedBox.shrink();
        }
        final tr = context.t.whatsNew;
        final colorScheme = Theme.of(context).colorScheme;
        final foreground = colorScheme.onSecondaryContainer;
        return Padding(
          padding: padding,
          child: AppInsetBlock(
            key: const ValueKey('whats-new-banner'),
            color: colorScheme.secondaryContainer,
            padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
            child: Row(
              children: [
                Icon(Icons.new_releases_outlined, size: 20, color: foreground),
                sizedBoxW12H12,
                Expanded(
                  child: Text(
                    tr.updated(version: prompt.version),
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(color: foreground),
                  ),
                ),
                TextButton(
                  key: const ValueKey('whats-new-banner-open'),
                  style: TextButton.styleFrom(foregroundColor: foreground, visualDensity: VisualDensity.compact),
                  onPressed: () async => openWhatsNew(context, controller),
                  child: Text(tr.open),
                ),
                IconButton(
                  key: const ValueKey('whats-new-banner-dismiss'),
                  icon: const Icon(Icons.close),
                  iconSize: 20,
                  color: foreground,
                  visualDensity: VisualDensity.compact,
                  tooltip: context.t.general.close,
                  onPressed: () => unawaited(controller.markSeen()),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
