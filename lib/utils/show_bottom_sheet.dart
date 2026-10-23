import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:smooth_sheets/smooth_sheets.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/cache/bloc/image_cache_trigger_cubit.dart';
import 'package:tsdm_client/features/editor/widgets/custom_image_tab.dart';
import 'package:tsdm_client/features/friend/utils/approve_friend_link.dart';
import 'package:tsdm_client/features/image/utils/image_actions.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/clipboard.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/network_indicator_image.dart';
import 'package:tsdm_client/widgets/single_line_text.dart';

/// Show a bottom sheet with given [title] and build children
/// with [childrenBuilder].
Future<T?> showCustomBottomSheet<T>({
  required BuildContext context,
  required String title,
  List<Widget> Function(BuildContext context)? childrenBuilder,
  Widget Function(BuildContext context)? builder,
  Widget? bottomBar,
  BottomSheetTopBar? topBar,
}) async {
  assert(builder != null || childrenBuilder != null, 'must provide builder or childrenBuilder');
  final Widget content;
  if (builder != null) {
    content = builder.call(context);
  } else {
    content = ListView(
      shrinkWrap: true,
      padding: context.safePadding(),
      children: childrenBuilder!(context),
    );
  }

  // Copied from [showHeroDialog]
  final ret = Navigator.push<T>(
    context,
    ModalSheetRoute(
      maintainState: false,
      swipeDismissible: true,
      // Here we do not have a context carrying expected padding values.
      // Set the maximum height to 80% to avoid covered by status bar.
      viewportBuilder: (context, child) => SheetViewport(
        padding: EdgeInsets.only(
          // Add a top padding to avoid the status bar.
          top: MediaQuery.viewPaddingOf(context).top,
        ),
        child: child,
      ),
      builder: (context) {
        return ClipRRect(
          borderRadius: const BorderRadius.only(topLeft: Radius.circular(24), topRight: Radius.circular(24)),
          child: Sheet(
            decoration: const MaterialSheetDecoration(size: SheetSize.stretch),
            // snapGrid: const SheetSnapGrid(snaps: [SheetOffset(0.5), SheetOffset(1)]),
            // Specify a scroll configuration to make the sheet scrollable.
            scrollConfiguration: const SheetScrollConfiguration(),
            // Sheet widget works with any scrollable widget such as
            // ListView, GridView, CustomScrollView, etc.
            child: SheetContentScaffold(
              backgroundColor: Theme.of(context).bottomSheetTheme.backgroundColor,
              topBar: PreferredSize(
                preferredSize: Size.fromHeight(kToolbarHeight + (topBar?.height ?? 0)),
                // preferredSize: const Size.fromHeight(kToolbarHeight),
                child: Stack(
                  children: [
                    // Drag handle: the sheet can be swiped down to close.
                    Positioned(
                      top: 6,
                      left: 0,
                      right: 0,
                      child: Center(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.outlineVariant,
                            borderRadius: BorderRadius.circular(2),
                          ),
                          child: const SizedBox(width: 32, height: 4),
                        ),
                      ),
                    ),
                    // Title and close button share one row: a long title (or a large text scale) is cut with an
                    // ellipsis instead of running under the button.
                    Positioned(
                      top: 12,
                      left: 16,
                      right: 16,
                      height: kToolbarHeight - 12,
                      child: Row(
                        children: [
                          const SizedBox(width: 48),
                          Expanded(
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.close_outlined),
                            tooltip: context.t.general.close,
                            onPressed: () async => context.pop(),
                          ),
                        ],
                      ),
                    ),
                    if (topBar != null) Positioned(top: kToolbarHeight, child: topBar),
                  ],
                ),
              ),
              body: content,
              bottomBar: bottomBar,
            ),
          ),
        );
      },
      // transitionsBuilder: (context, ani1, ani2, child) {
      //   return FadeTransition(opacity: CurveTween(curve: Curves.easeIn).animate(ani1), child: child);
      // },
    ),
  );

  return ret;
}

/// Show a bottom sheet offers available actions of the image.
///
/// All available actions:
///
/// * Open image in full page ([onCheckDetail]: the gallery of its floor at this picture; the picture alone when null).
/// * Save the image, share it (the file, not its url), copy its url, open it in the browser.
/// * Jump to related href url (optional).
/// * Reload image, save it to the user's images.
/// * Its cache statistics ([onShowStatistics], the gallery).
///
/// [showCheckDetail] is false when the sheet is opened from the full page viewer itself.
///
/// [shownUrl] is the picture shown where the sheet was opened ([imageUrl] when null; a floor shows the thumbnail of an
/// attachment): the preview, only read from the cache (nothing is downloaded for it), and what "reload" loads again.
Future<void> showImageActionBottomSheet({
  required BuildContext context,
  required String imageUrl,
  String? hrefUrl,
  String? shownUrl,
  bool showCheckDetail = true,
  VoidCallback? onCheckDetail,
  VoidCallback? onShowStatistics,
}) async {
  final shown = shownUrl ?? imageUrl;
  final tr = context.t.imageBottomSheet;

  await showCustomBottomSheet<void>(
    context: context,
    title: tr.title,
    childrenBuilder: (context) => [
      Padding(
        padding: edgeInsetsL16R16,
        child: AppInsetBlock(
          outlined: true,
          padding: edgeInsetsT4B4,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 100),
              child: NetworkIndicatorImage(shown, cacheOnly: true),
            ),
          ),
        ),
      ),
      sizedBoxW12H12,

      if (showCheckDetail)
        ListTile(
          leading: const Icon(Icons.fullscreen_outlined),
          title: Text(tr.checkDetail),
          onTap: () async {
            if (onCheckDetail != null) {
              context.pop();
              onCheckDetail();
              return;
            }
            await context.pushNamed(ScreenPaths.imageDetail, pathParameters: {'imageUrl': imageUrl});
            if (context.mounted) {
              context.pop();
            }
          },
        ),
      ListTile(
        leading: const Icon(Icons.save_outlined),
        title: Text(tr.saveImage),
        onTap: () async {
          final saved = await saveImageOf(context, imageUrl);
          if (saved != null && context.mounted) {
            context.pop();
          }
        },
      ),
      if (canShareImageFiles)
        Builder(
          builder: (context) => ListTile(
            leading: const Icon(Icons.share_outlined),
            title: Text(tr.shareImage),
            onTap: () async {
              final shared = await shareImageOf(context, imageUrl, origin: shareOriginOf(context));
              if (shared && context.mounted) {
                context.pop();
              }
            },
          ),
        ),
      ListTile(
        leading: const Icon(Icons.copy_outlined),
        title: Text(tr.copyImageUrl),
        subtitle: Text(imageUrl),
        onTap: () async {
          await copyToClipboard(context, imageUrl);
          if (context.mounted) {
            context.pop();
          }
        },
      ),
      ListTile(
        leading: const Icon(Icons.open_in_browser_outlined),
        title: Text(tr.openInBrowser),
        onTap: () async {
          await openImageInBrowser(context, imageUrl);
          if (context.mounted) {
            context.pop();
          }
        },
      ),
      if (hrefUrl != null)
        ListTile(
          leading: const Icon(Icons.link_outlined),
          title: Text(tr.openLink),
          subtitle: Text(hrefUrl),
          onTap: () async {
            await context.dispatchAsUrl(hrefUrl);
            if (context.mounted) {
              context.pop();
            }
          },
        ),
      ListTile(
        leading: const Icon(Icons.refresh_outlined),
        title: Text(tr.reloadImage),
        onTap: () => context.read<ImageCacheTriggerCubit>().updateImageCache(shown, force: true),
      ),
      ListTile(
        leading: const Icon(Icons.collections_bookmark_outlined),
        title: Text(tr.saveAsSticker),
        onTap: () async {
          await saveImageAsCustomImage(context, imageUrl);
          if (context.mounted) {
            context.pop();
          }
        },
      ),
      if (onShowStatistics != null)
        ListTile(
          leading: const Icon(Icons.info_outline),
          title: Text(context.t.imageDetailPage.statistics),
          onTap: () {
            context.pop();
            onShowStatistics();
          },
        ),
    ],
  );
}

/// Show a bottom sheet for url info and related actions.
Future<void> showUrlInfoBottomSheet({
  required BuildContext context,
  required String url,
}) async {
  final tr = context.t.urlInfoBottomSheet;
  final theme = Theme.of(context);

  final route = url.parseUrlToRoute();
  final isInternal = route != null || friendApprovalUidOfUrl(url) != null;
  final parseResultTitle = isInternal ? tr.urlTypes.internal.title : tr.urlTypes.external.title;
  final parseResultDetail = isInternal ? tr.urlTypes.internal.detail : tr.urlTypes.external.detail;

  await showCustomBottomSheet<void>(
    context: context,
    title: tr.title,
    childrenBuilder: (context) {
      return [
        Padding(
          padding: edgeInsetsL16R16,
          child: AppInsetBlock(
            outlined: true,
            padding: edgeInsetsL12T12R12B12,
            child: Column(
              crossAxisAlignment: .start,
              spacing: 8,
              children: [
                SingleLineText(url, style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.primary)),
                Container(
                  padding: edgeInsetsL8R8.add(edgeInsetsL4R4),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(appInnerRadius),
                  ),
                  child: Text(parseResultTitle, style: theme.textTheme.labelSmall),
                ),
                Text(parseResultDetail, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        ),
        sizedBoxW12H12,
        ListTile(
          leading: const Icon(Symbols.open_in_phone),
          title: Text(tr.open),
          onTap: () async {
            await context.dispatchAsUrl(url);
            if (context.mounted) {
              context.pop();
            }
          },
        ),
        ListTile(
          leading: const Icon(Symbols.open_in_browser),
          title: Text(tr.openInBrowser),
          onTap: () async {
            await context.dispatchAsUrl(url, external: true);
            if (context.mounted) {
              context.pop();
            }
          },
        ),
        ListTile(
          leading: const Icon(Icons.copy_outlined),
          title: Text(tr.copyUrl),
          onTap: () async {
            // Copy only: this used to dispatch the url as well, opening the page the user only wanted to copy.
            await copyToClipboard(context, url);
            if (context.mounted) {
              context.pop();
            }
          },
        ),
      ];
    },
  );
}

/// Show a bottom sheet for an email [address]: copy it, or hand it to the mail app.
///
/// The address is shown before anything is launched. Addresses come from posts (Cloudflare-obfuscated `mailto:`
/// links decoded by the muncher), so the user sees where a tap would lead first.
Future<void> showEmailBottomSheet({required BuildContext context, required String address}) async {
  final tr = context.t.emailBottomSheet;
  final theme = Theme.of(context);
  await showCustomBottomSheet<void>(
    context: context,
    title: tr.title,
    childrenBuilder: (context) {
      return [
        Padding(
          padding: edgeInsetsL16R16,
          child: AppInsetBlock(
            outlined: true,
            padding: edgeInsetsL12T12R12B12,
            child: Row(
              children: [
                Icon(Icons.alternate_email_outlined, size: 20, color: theme.colorScheme.primary),
                sizedBoxW8H8,
                Expanded(
                  child: SingleLineText(
                    address,
                    style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.primary),
                  ),
                ),
              ],
            ),
          ),
        ),
        sizedBoxW12H12,
        ListTile(
          leading: const Icon(Icons.copy_outlined),
          title: Text(tr.copy),
          onTap: () async {
            await copyToClipboard(context, address);
            if (context.mounted) {
              context.pop();
            }
          },
        ),
        ListTile(
          leading: const Icon(Icons.email_outlined),
          title: Text(tr.send),
          onTap: () async {
            // Only ever a plain `mailto:` with the address, nothing appended.
            await context.dispatchAsUrl('mailto:$address', external: true);
            if (context.mounted) {
              context.pop();
            }
          },
        ),
      ];
    },
  );
}

/// The top bar of custom bottom sheet
///
/// Only use this widget in [showCustomBottomSheet]'s `topBar`.
class BottomSheetTopBar extends StatelessWidget {
  /// Constructor.
  const BottomSheetTopBar({required this.height, required this.child, this.alignment, super.key});

  /// Preferred height of top bar content.
  final double height;

  /// Content child widget.
  final Widget child;

  /// Horizontal alignment.
  final Alignment? alignment;

  @override
  Widget build(BuildContext context) {
    return PreferredSize(
      preferredSize: Size.fromHeight(height),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: height, maxWidth: MediaQuery.widthOf(context)),
        child: alignment != null ? Align(alignment: alignment!, child: child) : child,
      ),
    );
  }
}
