import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/jump_page/cubit/jump_page_cubit.dart';
import 'package:tsdm_client/features/jump_page/widgets/jump_page_dialog.dart';
import 'package:tsdm_client/features/local_notice/tap.dart';
import 'package:tsdm_client/features/multi_user/widgets/current_account_avatar.dart';
import 'package:tsdm_client/features/root/view/root_page.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/thread/v1/bloc/thread_bloc.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/widgets/list_app_bar/menu_actions.dart';
import 'package:tsdm_client/widgets/list_app_bar/menu_item_id.dart';
import 'package:tsdm_client/widgets/notice_button.dart';

/// Custom item in popup menu for list app bar.
@immutable
class MenuCustomItem {
  /// Constructor.
  const MenuCustomItem({required this.icon, required this.description, required this.onSelected});

  /// Icon to show in item of menu.
  final IconData icon;

  /// Menu description text.
  final String description;

  /// The callback to run when item is selected.
  final FutureOr<void> Function() onSelected;
}

/// Below this window width (scaled with the text) the page pill leaves out the total pages while the current account
/// button is shown.
const double _compactPillWidth = 360;

/// A app bar contains list and provides features including:
///
/// * Jump to the global search page.
/// * Specified title.
/// * Jump page.
class ListAppBar extends StatelessWidget implements PreferredSizeWidget {
  /// Constructor.
  const ListAppBar({
    required this.onRefresh,
    required this.onCopyUrl,
    required this.onOpenInBrowser,
    this.title,
    this.bottom,
    this.showReverseOrderAction = false,
    this.onSearch,
    this.onJumpPage,
    this.onBackToTop,
    this.onReverseOrder,
    this.customMenuItems = const [],
    super.key,
  });

  /// Callback that should navigate to global search page.
  final FutureOr<void> Function()? onSearch;

  /// Jump to another page in the list.
  ///
  /// Parameter is the page number.
  final FutureOr<void> Function(int)? onJumpPage;

  /// Widget title.
  final String? title;

  /// Callback to refresh current page.
  final FutureOr<void> Function() onRefresh;

  /// Callback to copy current page's url.
  final FutureOr<void> Function() onCopyUrl;

  /// Callback to open current page in browser.
  final FutureOr<void> Function() onOpenInBrowser;

  /// Callback to scroll current page to top.
  ///
  /// Do it if possible.
  final FutureOr<void> Function()? onBackToTop;

  /// Callback to view the page in reverse order.
  ///
  /// Trigger it on and off.
  ///
  /// Do it if possible.
  final FutureOr<void> Function()? onReverseOrder;

  /// Custom menu icons.
  ///
  /// Optional.
  final List<MenuCustomItem> customMenuItems;

  /// Extra bottom widget.
  final PreferredSizeWidget? bottom;

  /// Show the action to change "view order" between forward order and reverse
  /// order.
  final bool showReverseOrderAction;

  Future<void> _jumpPage(BuildContext context, int currentPage, int totalPages) async {
    if (currentPage <= 0 && currentPage > totalPages) {
      return;
    }
    final page = await showDialog<int>(
      context: context,
      builder: (context) =>
          RootPage(DialogPaths.jumpPage, JumpPageDialog(min: 1, current: currentPage, max: totalPages)),
    );
    if (page == null || page == currentPage) {
      return;
    }
    await onJumpPage?.call(page);
  }

  @override
  Widget build(BuildContext context) {
    var currentPage = 0;
    var totalPages = 0;
    var canJumpPage = false;
    if (onJumpPage != null) {
      final jumpPageState = context.watch<JumpPageCubit>().state;
      currentPage = jumpPageState.currentPage;
      totalPages = jumpPageState.totalPages;
      canJumpPage = jumpPageState.canJumpPage;
    }

    final threadBloc = context.readOrNull<ThreadBloc>();
    // Default is not reversed.
    // FIXME: Some threads may set reversed order, detect that in page
    //  (though impossible if only one page).
    final reverseOrder = threadBloc?.state.reverseOrder ?? false;

    final isLogin = context.select<AuthenticationRepository, bool>((repo) => repo.currentUser != null);

    // The current account button (GitHub #184) costs 48px. On a narrow window or with large text the page pill then
    // drops its " / total" part, so the actions still fit a 320px wide phone; the jump dialog shows the total anyway.
    final showsAccount = watchCurrentAccount(context)?.showsAccount ?? false;
    final compactPagePill =
        showsAccount && MediaQuery.sizeOf(context).width < MediaQuery.textScalerOf(context).scale(_compactPillWidth);

    return AppBar(
      title: title == null ? null : Text(title!),
      // TODO: Currently we always use a compact layout in list app bar for larger main content space.
      // If going to implement responsive layout, remember to wrap list app bar in `PreferredSize` in ALL places using
      // it, this is an issue or usage defined by Flutter, seems the AppBar checks if it's direct `bottom` widget is
      // preferred size or not, to determine the height of app bar, DISGUSTING.
      bottom: bottom,
      // bottom: PreferredSize(
      //   preferredSize: Size.fromHeight((bottom?.preferredSize.height ?? 0) + (isMobile ? 52 : 42)),
      //   child: Column(
      //     children: [
      //       Row(
      //         children: [
      //           Expanded(
      //             child: Padding(
      //               padding: edgeInsetsL4R4,
      //               child: SingleChildScrollView(
      //                 scrollDirection: Axis.horizontal,
      //                 reverse: true,
      //                 child: Row(
      //                   children: [
      //                     const OpenInAppPageButton(),
      //                     IconButton(
      //                       icon: const Icon(Icons.search_outlined),
      //                       tooltip: context.t.searchPage.title,
      //                       onPressed: onSearch,
      //                     ),
      //                     const OpenProfilePageButton(),
      //                     const NoticeButton(),
      //                     IconButton(
      //                       icon: const Icon(Icons.settings_outlined),
      //                       tooltip: context.t.general.openSettings,
      //                       onPressed: () async => context.pushNamed(ScreenPaths.settings.path),
      //                     ),
      //                   ],
      //                 ),
      //               ),
      //             ),
      //           ),
      //         ],
      //       ),
      //       ?bottom,
      //     ],
      //   ),
      // ),
      actions: [
        /**
         * Actions available in current page.
         */

        // Using three or more actions violates material design spec, but just do it.
        // The account that replies or posts from here, only with more than one saved account (GitHub #184). Both
        // pages using this app bar (forum, thread) are where one posts; see `compactPagePill` for the 48px it costs.
        const CurrentAccountAvatarButton(),
        const NoticeButton(),
        // Current page as a tonal pill ("3 / 12"), opening the jump dialog.
        if (onJumpPage != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Tooltip(
              message: context.t.jumpDialog.title,
              child: FilledButton.tonal(
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  minimumSize: const Size(0, 36),
                ),
                onPressed: canJumpPage ? () async => _jumpPage(context, currentPage, totalPages) : null,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.auto_stories_outlined, size: 16),
                    sizedBoxW4H4,
                    Text('${canJumpPage ? currentPage : "-"}'),
                    if (canJumpPage && totalPages > 0 && !compactPagePill)
                      Text(' / $totalPages', style: Theme.of(context).textTheme.labelSmall),
                  ],
                ),
              ),
            ),
          ),
        PopupMenuButton<MenuItemId>(
          // Same items as before, grouped: this page (refresh, back to top, order), the page's own items, its link,
          // then the app wide places, and the debug log when debug operations are on.
          itemBuilder: (context) {
            PopupMenuItem<MenuItemId> item(MenuItemId value, IconData icon, String text, {bool enabled = true}) =>
                PopupMenuItem(
                  enabled: enabled,
                  value: value,
                  child: Row(
                    children: [
                      Icon(icon),
                      sizedBoxPopupMenuItemIconSpacing,
                      Flexible(child: Text(text)),
                    ],
                  ),
                );
            const divider = PopupMenuDivider(height: 8);
            return <PopupMenuEntry<MenuItemId>>[
              /**
               * Actions available in current page.
               */
              item(MenuItemId.fixed(MenuActions.refresh), Icons.refresh_outlined, context.t.networkList.actionRefresh),
              item(
                MenuItemId.fixed(MenuActions.backToTop),
                Icons.vertical_align_top_outlined,
                context.t.networkList.actionBackToTop,
              ),
              if (showReverseOrderAction)
                item(
                  MenuItemId.fixed(MenuActions.reverseOrder),
                  reverseOrder ? Icons.align_vertical_bottom_outlined : Icons.align_vertical_top_outlined,
                  reverseOrder ? context.t.networkList.actionForwardOrder : context.t.networkList.actionReverseOrder,
                ),

              // Custom items.
              if (customMenuItems.isNotEmpty) ...[
                divider,
                ...customMenuItems.mapIndexed((idx, e) => item(MenuItemId.custom(idx), e.icon, e.description)),
              ],

              // Link of the page.
              divider,
              item(MenuItemId.fixed(MenuActions.copyUrl), Icons.copy_outlined, context.t.networkList.actionCopyUrl),
              item(
                MenuItemId.fixed(MenuActions.openInBrowser),
                Icons.open_in_browser,
                context.t.networkList.actionOpenInBrowser,
              ),

              /**
               * Global actions
               */
              divider,
              item(
                MenuItemId.fixed(MenuActions.openInApp),
                Symbols.open_in_phone,
                context.t.openInAppPage.entryTooltip,
              ),
              item(MenuItemId.fixed(MenuActions.openSearchPage), Icons.search_outlined, context.t.searchPage.title),
              item(
                MenuItemId.fixed(MenuActions.profile),
                Icons.person_outline,
                context.t.profilePage.title,
                enabled: isLogin,
              ),
              item(
                MenuItemId.fixed(MenuActions.openNoticePage),
                Icons.notifications_outlined,
                context.t.noticePage.title,
                enabled: isLogin,
              ),
              item(
                MenuItemId.fixed(MenuActions.openSettingsPage),
                Icons.settings_outlined,
                context.t.general.settings,
              ),

              if (context.read<SettingsBloc>().state.settingsMap.enableDebugOperations) ...[
                divider,
                item(
                  MenuItemId.fixed(MenuActions.debugViewLog),
                  Icons.bug_report_outlined,
                  context.t.settingsPage.debugSection.viewLog.title,
                ),
              ],
            ];
          },
          onSelected: (item) async {
            switch (item.action) {
              case MenuActions.refresh:
                await onRefresh.call();
              case MenuActions.copyUrl:
                await onCopyUrl.call();
              case MenuActions.openInBrowser:
                await onOpenInBrowser.call();
              case MenuActions.backToTop:
                await onBackToTop?.call();
              case MenuActions.reverseOrder:
                await onReverseOrder?.call();
              case MenuActions.openInApp:
                await context.pushNamed(ScreenPaths.openInApp);
              case MenuActions.openSearchPage:
                onSearch != null ? await onSearch?.call() : context.pushNamed(ScreenPaths.search);
              case MenuActions.profile:
                await context.pushNamed(ScreenPaths.profile);
              case MenuActions.openNoticePage:
                openNoticePageInApp(context);
              case MenuActions.openSettingsPage:
                await context.pushNamed(ScreenPaths.settings.path);
              case MenuActions.debugViewLog:
                await context.pushNamed(ScreenPaths.debugLog);
              case MenuActions.custom:
                // Custom actions.
                await customMenuItems.elementAt(item.customId!).onSelected.call();
            }
          },
        ),
      ],
    );
  }

  @override
  Size get preferredSize => Size.fromHeight(kToolbarHeight + (bottom?.preferredSize.height ?? 0));
}
