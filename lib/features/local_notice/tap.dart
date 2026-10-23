import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:rxdart/rxdart.dart' show MergeStream;
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/local_notice/keys.dart';
import 'package:tsdm_client/features/multi_user/bloc/switch_user_bloc.dart';
import 'package:tsdm_client/features/multi_user/utils/switch_account.dart';
import 'package:tsdm_client/features/notification/bloc/notification_bloc.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/features/notification/utils/notice_info.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/app_routes.dart';
import 'package:tsdm_client/routes/page_stack.dart';
import 'package:tsdm_client/routes/popup_route_observer.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/show_toast.dart';

/// What the app does with a tap on the auto sync notification.
enum LocalNoticeTapAction {
  /// No account in use: the notice page needs a login, stay where we are.
  needLogin,

  /// The notice page is already the page on top, nothing to open.
  alreadyOnNoticePage,

  /// A notice page is open under the pages on top, close those to show it again.
  returnToNoticePage,

  /// Push the notice page.
  openNoticePage,

  /// Push the page the notification is about ([LocalNoticeTarget]): the floor of the notice, the conversation.
  openTarget,
}

/// Decide what a tap on the auto sync notification does.
///
/// [topLocation] is the location of the page the router shows on top ([routerTopLocation]). That is the only thing
/// telling whether the notice page is really in front: the location stack kept by `RootLocationCubit` is fed by page
/// enter/leave events and used to drift, so a tap on the homepage was answered "already in the notice page" after the
/// notice page had been left once (GitHub #14).
///
/// [canReturnToNoticePage] tells whether a notice page further down can be shown again ([canReturnToPage]). Each tap
/// while reading a thread opened out of the notice page used to push another notice page, piling them up (GitHub #117).
LocalNoticeTapAction decideLocalNoticeTap({
  required bool loggedIn,
  required String? topLocation,
  bool canReturnToNoticePage = false,
}) {
  if (!loggedIn) {
    return LocalNoticeTapAction.needLogin;
  }
  if (topLocation == ScreenPaths.notice) {
    return LocalNoticeTapAction.alreadyOnNoticePage;
  }
  if (canReturnToNoticePage) {
    return LocalNoticeTapAction.returnToNoticePage;
  }
  return LocalNoticeTapAction.openNoticePage;
}

/// Carry out a tap on the auto sync notification on [router].
///
/// Returns the page that was on top before and what was done: [LocalNoticeTapAction.openNoticePage] also when going
/// back to the open notice page stopped early (a page refused to close) and another one was pushed instead. [hasPopup]
/// tells whether a dialog or sheet is open, the pages under it are then never closed.
({String? top, LocalNoticeTapAction action}) openNoticePageForTap(
  GoRouter router, {
  required bool loggedIn,
  required bool hasPopup,
}) {
  final top = routerTopLocation(router);
  var action = decideLocalNoticeTap(
    loggedIn: loggedIn,
    topLocation: top,
    canReturnToNoticePage: canReturnToPage(router, ScreenPaths.notice, hasPopup: hasPopup),
  );
  if (action == LocalNoticeTapAction.returnToNoticePage && !returnToPage(router, ScreenPaths.notice)) {
    action = LocalNoticeTapAction.openNoticePage;
  }
  if (action == LocalNoticeTapAction.openNoticePage) {
    // Completes only when the pushed page is closed, nothing to wait for.
    unawaited(router.pushNamed(ScreenPaths.notice));
  }
  return (top: top, action: action);
}

/// Open the notice page from a control inside the app: the bell of the app bars, the "notifications" item of their
/// menu and of the profile page's menu. Every way into the notice page goes through here or [openNoticePageForTap]
/// and nowhere pushes it by itself (a regression test checks the sources).
///
/// The same as a tap on the auto sync notification: a notice page already open under the pages on top is shown again
/// when they can all be closed quietly, otherwise one is pushed. Reading the notices one by one (notice page, a
/// thread, the bell of the thread page, the next thread...) pushed another notice page each time and piled them up,
/// as the notification tap did before GitHub #117 (GitHub #196).
///
/// The account is not checked here: the controls are only offered with one, and the notice page asks for a login
/// itself, as before. [popups] is the observer of the app's dialogs and menus ([popupRouteObserver] by default): with
/// one open the pages under it are never closed. A menu item runs after its menu closed, so it does not count.
void openNoticePageInApp(BuildContext context, {PopupRouteObserver? popups}) {
  final (:top, :action) = openNoticePageForTap(
    GoRouter.of(context),
    loggedIn: true,
    hasPopup: (popups ?? popupRouteObserver).hasPopupRoute,
  );
  talker.debug('open notice page in app: action=${action.name} top=$top');
}

/// What a tap on the notification of an account did about the account, see [openNoticePageOfAccount].
enum LocalNoticeAccountStep {
  /// The notification is about the account in use, names no account, or no account is in use: nothing to switch.
  current,

  /// Switched to the account of the notification, then the notice page was opened.
  switched,

  /// The account of the notification is no longer saved on this device: nothing opened, a toast says so.
  gone,

  /// The switch did not happen (it failed, the login expired, a reply was being sent, another switch ran, the sync
  /// kept fetching): nothing opened, the switch told why.
  notSwitched,
}

/// Switch to [account] the way the avatar menu does (PR #187): [switchAccount] with a bloc of its own.
Future<SwitchAccountResult> _switchLikeTheMenu(BuildContext context, UserLoginInfo account) async {
  final bloc = SwitchUserBloc(context.read<AuthenticationRepository>());
  try {
    return await switchAccount(context, bloc: bloc, userInfo: account);
  } finally {
    // The switch has ended by now (see [switchAccount]): closing the bloc stops nothing.
    await bloc.close();
  }
}

/// Carry out a tap on an auto sync notification about account [uid] from [context], a page under the app's providers
/// (the home page). [uid] is null for a notification that names no account (only the account in use is announced, or
/// the test notification of the settings page): the account in use.
///
/// With a [target] (a notification of a single new item) the page it names is opened instead of the notice page, once
/// the account is the right one, by the same rules ([openLocalNoticeTarget]); when the switch does not happen the
/// notice page of the account in use is opened instead, never the target. A target without [uid] is not opened.
///
/// * The account in use, no account named, or nobody logged in: [openNoticePageForTap] right away, as before.
/// * Another account saved on this device: switch to it right away, the same way as the avatar menu's quick switch
///   ([switchTo], [switchAccount] by default: its toasts, one switch at a time, none while a reply is being sent, the
///   in-app sync paused around it), then open the notice page once its lists are the new account's (up to
///   [reloadTimeout]). Every logged-in account is announced when asked to, and the account in use may have changed
///   since any notification was posted. At a cold start the homepage may still be verifying the stored login: its
///   answer arriving after the switch is refused under the identity lock and the homepage reloads for the new account
///   (`AuthenticationRepository.loginWithServedUser`).
/// * Another switch while the lists are awaited (the avatar menu) wins: the notice page is not opened.
/// * The switch does not happen: nothing is opened, the notice page would show the account in use and not the one the
///   notification is about.
/// * An account no longer on this device: nothing is opened, a toast says so.
///
/// Returns what was done about the account, and, when the notice page was asked for, the page that was on top before
/// and what was done ([openNoticePageForTap]). [popups] is the observer of the app's dialogs and menus
/// ([popupRouteObserver] by default).
Future<({LocalNoticeAccountStep step, String? top, LocalNoticeTapAction? action})> openNoticePageOfAccount(
  BuildContext context, {
  required int? uid,
  LocalNoticeTarget? target,
  PopupRouteObserver? popups,
  Future<SwitchAccountResult> Function(BuildContext context, UserLoginInfo account)? switchTo,
  Duration reloadTimeout = const Duration(seconds: 5),
}) async {
  ({LocalNoticeAccountStep step, String? top, LocalNoticeTapAction? action}) open(
    LocalNoticeAccountStep step, {
    required bool loggedIn,
    bool direct = true,
  }) {
    if (direct && target != null && loggedIn && openLocalNoticeTarget(context, target)) {
      return (step: step, top: routerTopLocation(GoRouter.of(context)), action: LocalNoticeTapAction.openTarget);
    }
    final (:top, :action) = openNoticePageForTap(
      GoRouter.of(context),
      loggedIn: loggedIn,
      hasPopup: (popups ?? popupRouteObserver).hasPopupRoute,
    );
    return (step: step, top: top, action: action);
  }

  const notOpened = (step: LocalNoticeAccountStep.notSwitched, top: null, action: null);
  final auth = context.read<AuthenticationRepository>();
  // The stored session counts: when a notification cold-starts the app the home page has its first frame before the
  // homepage fetch verified the login, and `currentUser` is still null at that point (#14).
  final current = auth.effectiveCurrentUid;
  if (uid == null || current == null || uid == current) {
    // A target is only opened for the account it names: never for a payload without one.
    return open(LocalNoticeAccountStep.current, loggedIn: current != null, direct: uid != null);
  }
  talker.info('notification of another account tapped: uid ${"$uid".obscured(4)}, switching to it first');
  final account = (await getIt.get<StorageProvider>().getAllUsers()).firstWhereOrNull((e) => e.uid == uid);
  if (!context.mounted) {
    return notOpened;
  }
  if (account == null) {
    showSnackBar(context: context, message: context.t.localNotification.accountGone);
    return (step: LocalNoticeAccountStep.gone, top: null, action: null);
  }
  final result = await (switchTo ?? _switchLikeTheMenu)(context, account);
  if (result != SwitchAccountResult.switched || !context.mounted) {
    // An item of a single new notification: the notice page of the account in use instead, never the item, which
    // belongs to the other account.
    if (target != null && context.mounted) {
      talker.info('notification of another account: not switched (${result.name}), notice page opened instead');
      return open(LocalNoticeAccountStep.notSwitched, loggedIn: true, direct: false);
    }
    talker.info('notification of another account: not switched (${result.name}), notice page not opened');
    return notOpened;
  }
  if (context.readOrNull<NotificationBloc>() case final bloc?) {
    await _noticesReloadedFor(
      bloc,
      uid,
      reloadTimeout,
      inUse: () => auth.effectiveCurrentUid,
      accountChanges: auth.status,
    );
    if (!context.mounted) {
      return notOpened;
    }
  }
  if (auth.effectiveCurrentUid != uid) {
    talker.info('notification of another account: switched away meanwhile, notice page not opened');
    return notOpened;
  }
  return open(LocalNoticeAccountStep.switched, loggedIn: true);
}

/// Wait up to [timeout] for the first event of [stream] that passes [test]; false when none came in time or the
/// stream ended. The subscription and the timer end with the wait, whatever ends it.
Future<bool> _firstWithin<T>(Stream<T> stream, bool Function(T event) test, Duration timeout) async {
  final done = Completer<bool>();
  void finish({required bool reached}) {
    if (!done.isCompleted) {
      done.complete(reached);
    }
  }

  final timer = Timer(timeout, () => finish(reached: false));
  final subscription = stream.listen((event) {
    if (test(event)) {
      finish(reached: true);
    }
  }, onDone: () => finish(reached: false));
  try {
    return await done.future;
  } finally {
    timer.cancel();
    await subscription.cancel();
  }
}

/// Wait up to [timeout] for the lists of [bloc] to be the ones of [uid], not loading; the wait also ends when the
/// account in use ([inUse], told by [accountChanges]) is not [uid] any more: another switch won.
///
/// A fetch of the previous account still running ends dropped (its account is not the one in use any more, the state
/// is reset), then the lists are rebuilt from storage for [uid]; without one they are rebuilt right away. The page
/// shows nothing of another account meanwhile anyway ([NotificationState.ownerUid]).
Future<void> _noticesReloadedFor(
  NotificationBloc bloc,
  int uid,
  Duration timeout, {
  required int? Function() inUse,
  required Stream<Object?> accountChanges,
}) async {
  bool ready(NotificationState s) => s.ownerUid == uid && s.status != NotificationStatus.loading;
  bool over(NotificationState s) => ready(s) || inUse() != uid;
  if (over(bloc.state)) {
    return;
  }
  Stream<Object?> changes() => MergeStream<Object?>([bloc.stream, accountChanges]);
  final reached = _firstWithin<Object?>(changes(), (_) => over(bloc.state), timeout);
  if (bloc.state.status == NotificationStatus.loading) {
    // The fetch of the previous account first: the reload is skipped while one runs.
    final previousEnded = await _firstWithin<Object?>(
      changes(),
      (_) => bloc.state.status != NotificationStatus.loading || inUse() != uid,
      timeout,
    );
    if (!previousEnded) {
      talker.warning('the fetch of the previous account did not end within ${timeout.inSeconds}s');
    }
  }
  if (!bloc.isClosed && inUse() == uid) {
    bloc.add(NotificationReloadFromStorageRequested());
  }
  if (!await reached) {
    talker.warning('the notices of the new account were not in within ${timeout.inSeconds}s, opening the page anyway');
  }
}

/// Location of the page on top of [router], `null` before the first route matched.
///
/// Walks into shell routes, so a page inside the home shell reports its own location instead of the shell's, and a
/// page opened with `pushNamed` reports itself. Dialogs and bottom sheets are not routes of the router: the page
/// under them is reported, which is what a tap wants to know.
String? routerTopLocation(GoRouter router) => router.routerDelegate.currentConfiguration.lastOrNull?.matchedLocation;

/// Open the page [target] names from [context], a page under the app's providers, for the account in use: the floor
/// of the notice (the thread when only that is known) or the conversation; the notice or the conversation is marked as
/// read, as a tap on its card does. False when [target] names nothing that can be opened.
bool openLocalNoticeTarget(BuildContext context, LocalNoticeTarget target) {
  final RecognizedRoute? route;
  if (target.pid != null || target.tid != null) {
    route = NoticeTarget(tid: target.tid, pid: target.pid).url.parseUrlToRoute();
  } else if (target.peerUid != null) {
    route = RecognizedRoute(ScreenPaths.chatHistory, pathParameters: {'uid': '${target.peerUid}'});
  } else {
    route = null;
  }
  if (route == null) {
    return false;
  }
  final uid = context.read<AuthenticationRepository>().effectiveCurrentUid;
  final bloc = context.readOrNull<NotificationBloc>();
  if (uid != null && bloc != null) {
    if (target.nid case final nid?) {
      bloc.add(NotificationMarkReadRequested(RecordMarkNotice(uid: uid, nid: nid, alreadyRead: true)));
    } else if (target.peerUid case final peerUid?) {
      bloc.add(
        NotificationMarkReadRequested(RecordMarkPersonalMessage(uid: uid, peerUid: peerUid, alreadyRead: true)),
      );
    }
  }
  // Completes only when the pushed page is closed, nothing to wait for.
  unawaited(
    GoRouter.of(
      context,
    ).pushNamed(route.screenPath, pathParameters: route.pathParameters, queryParameters: route.queryParameters),
  );
  return true;
}
