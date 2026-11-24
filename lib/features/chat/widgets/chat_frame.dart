import 'package:flutter/material.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/themes/app_surfaces.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// Height of [ChatPeerHeader] when used as the bottom of an app bar.
const chatPeerHeaderHeight = 36.0;

/// Line under the title of the chat pages: who the conversation is with and, optionally, a status pill.
class ChatPeerHeader extends StatelessWidget implements PreferredSizeWidget {
  /// Constructor.
  const ChatPeerHeader({required this.text, this.status, this.online = false, super.key});

  /// Who the conversation is with, already translated.
  final String text;

  /// Optional status text shown in a pill (online or offline), already translated.
  final String? status;

  /// Color the status pill as online.
  final bool online;

  @override
  Size get preferredSize => const Size.fromHeight(chatPeerHeaderHeight);

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    // A fixed height line under the app bar: large fonts are clamped a little so the line and its pill are not cut.
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.2,
      child: SizedBox(
        height: chatPeerHeaderHeight,
        child: Padding(
          padding: edgeInsetsL16R16B12.copyWith(bottom: 8),
          child: Row(
            children: [
              Icon(Icons.person_outline, size: 16, color: colorScheme.onSurfaceVariant),
              sizedBoxW4H4,
              Flexible(
                child: Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.labelMedium?.copyWith(color: colorScheme.onSurfaceVariant),
                ),
              ),
              if (status != null) ...[
                sizedBoxW8H8,
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: online ? colorScheme.primaryContainer : colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(appInnerRadius),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.circle, size: 8, color: online ? colorScheme.primary : colorScheme.onSurfaceVariant),
                        sizedBoxW4H4,
                        Text(
                          status!,
                          maxLines: 1,
                          style: textTheme.labelSmall?.copyWith(
                            color: online ? colorScheme.onPrimaryContainer : colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Frame of the message input of the chat pages: full width background with a hairline on top, the input itself
/// centered at the width of the messages.
class ChatComposerFrame extends StatelessWidget {
  /// Constructor.
  const ChatComposerFrame({required this.child, super.key});

  /// The reply bar.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        // Same color as the collapsed reply bar, so the frame and the bar read as one area. The hairline on top is
        // drawn by the reply bar itself (UI phase 3), not twice.
        color: AppSurfaces.of(context).bar,
      ),
      child: AppContentWidth(maxWidth: appReadingMaxWidth, child: child),
    );
  }
}
