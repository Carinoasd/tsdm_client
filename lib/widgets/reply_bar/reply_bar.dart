import 'dart:async';
import 'dart:convert';

import 'package:chat_bottom_container/chat_bottom_container.dart';
import 'package:dart_bbcode_parser/dart_bbcode_parser.dart';
import 'package:dart_quill_delta/dart_quill_delta.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bbcode_editor/flutter_bbcode_editor.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/bbcode_editor_controller.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/chat/models/models.dart';
import 'package:tsdm_client/features/editor/utils/custom_image_input.dart';
import 'package:tsdm_client/features/editor/widgets/editor_frame.dart';
import 'package:tsdm_client/features/editor/widgets/emoji_panel.dart';
import 'package:tsdm_client/features/editor/widgets/rich_editor.dart';
import 'package:tsdm_client/features/editor/widgets/toolbar.dart';
import 'package:tsdm_client/features/local_draft/models/local_draft.dart';
import 'package:tsdm_client/features/local_draft/repository/local_draft_store.dart';
import 'package:tsdm_client/features/local_draft/utils/draft_autosaver.dart';
import 'package:tsdm_client/features/local_draft/utils/draft_text.dart';
import 'package:tsdm_client/features/local_draft/widgets/draft_offer_banner.dart';
import 'package:tsdm_client/features/multi_user/widgets/current_account_avatar.dart';
import 'package:tsdm_client/features/post/utils/post_limits.dart';
import 'package:tsdm_client/features/post/widgets/sec_check_dialog.dart';
import 'package:tsdm_client/features/root/models/models.dart';
import 'package:tsdm_client/features/root/stream/root_location_stream.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/page_stack.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/utils/bbcode/spoiler_normalizer.dart';
import 'package:tsdm_client/utils/browser_launcher.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/utils/platform.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/heroes.dart';
import 'package:tsdm_client/widgets/reply_bar/bloc/reply_bloc.dart';
import 'package:tsdm_client/widgets/reply_bar/debate_stand_selector.dart';
import 'package:tsdm_client/widgets/reply_bar/models/reply_types.dart';
import 'package:tsdm_client/widgets/reply_bar/repository/reply_repository.dart';

part 'reply_bar_draft.dart';

enum _BottomPanelType { none, keyboard, toolbar, emoji }

/// The snack bar action of a failed reply that needs the website ([ReplyState.browserUrl]: the forum asks for a captcha
/// or a security question, or the reply form has fields the app cannot fill): open the page to reply on in the browser.
/// Null for any other failure.
SnackBarAction? replyInBrowserAction(BuildContext context, String? url) {
  if (url == null) {
    return null;
  }
  return SnackBarAction(
    label: context.t.threadPage.replyInBrowser,
    onPressed: () async {
      try {
        await openInExternalBrowser(Uri.parse(url));
      } on Object catch (e) {
        talker.error('failed to open the reply page in the browser: $e');
      }
    },
  );
}

/// An editor controller holding [body] (BBCode): from the editor's own document [delta] when it is known (what BBCode
/// does not carry comes back too), else parsed as the settings say.
BBCodeEditorController _editorControllerFor(String body, {String? delta}) {
  if (delta != null) {
    try {
      final json = jsonDecode(delta);
      if (json is List) {
        return buildBBCodeEditorController(initialDelta: Delta.fromJson(json));
      }
    } on Object catch (e) {
      talker.warning('reply bar: the kept document does not load, the text is parsed again: $e');
    }
  }
  final parserEnabled = getIt.get<SettingsRepository>().currentSettings.enableEditorBBCodeParser;
  // FIXME: CAUTION! This initial delta parsing step may cause ui jank.
  return parserEnabled
      ? buildBBCodeEditorController(initialDelta: parseBBCodeTextToDelta(body))
      : buildBBCodeEditorController(initialText: normalizeBlockMarkerNesting(body));
}

/// Widget provide reply functionality.
///
/// Actually is a wrapper for the real reply bar.
/// Wrapped so that a expandable reply bar can be set in page as bottom sheet.
///
/// What it holds is kept on this device as the local draft of the account and the target (the thread, the floor, the
/// member of a private message, see [LocalDraftStore]) while it is written, and offered again when the same target is
/// opened later; the reply bloc deletes it once sent.
class ReplyBar extends StatefulWidget {
  /// Constructor.
  const ReplyBar({
    required this.controller,
    required this.replyType,
    this.chatHistorySendTarget,
    this.chatSendTarget,
    this.disabledEditorFeatures = const {},
    this.fullScreenDisabledEditorFeatures = const {},
    this.fullScreen = false,
    super.key,
  });

  /// Controller passed from outside.
  final ReplyBarController controller;

  /// Usage type of [_ReplyBar].
  ///
  /// Different usages have different state and logic.
  final ReplyTypes replyType;

  /// Send target url and parameters when in chat history.
  final ChatHistorySendTarget? chatHistorySendTarget;

  /// Send url parameters when in chat page.
  final ChatSendTarget? chatSendTarget;

  /// Disable all bbcode editor features exists in this list.
  ///
  /// Those disabled features' corresponding widget will be invisible.
  final Set<EditorFeatures> disabledEditorFeatures;

  /// Disabled bbcode editor features when reply bar set to full screen.
  ///
  /// Usually is less than [disabledEditorFeatures].
  ///
  /// Those disabled features' corresponding widget will be invisible.
  final Set<EditorFeatures> fullScreenDisabledEditorFeatures;

  /// Constraints max height?
  final bool fullScreen;

  @override
  State<ReplyBar> createState() => _ReplyBarWrapperState();
}

class _ReplyBarWrapperState extends State<ReplyBar> {
  /// Text controller to display head part of entered bbcode.
  final controller = TextEditingController();

  /// Route of the page this bar is on, told about the reply not sent yet ([RouteDrafts]).
  Route<dynamic>? _route;

  /// Whether the user can write here: otherwise [controller] shows a hint (need login, thread closed), not a reply.
  bool _enabled = false;

  /// The draft target is looked at again after this frame.
  bool _targetScheduled = false;

  /// The dialog asking for the captcha or the security question is up.
  bool _verifying = false;

  _ReplyDraftSession get _drafts => widget.controller._drafts;

  /// Whether a reply is being written or was written and not sent.
  ///
  /// An open editor counts even while empty: the user is in the middle of writing.
  bool _hasDraft() => widget.controller._showingEditor || (_enabled && controller.text.trim().isNotEmpty);

  Future<void> showEditor() async {
    if (widget.controller._showingEditor) {
      // Now we already have an editor, not now override with another one.
      return;
    }

    // Here we actually want to ensure the editor is shown when user set hint
    // text: which means user want to reply to something.
    //
    // The debounce check above only filters duplicate editor, it's safe.

    final c = showBottomSheet(
      context: context,
      // Material 3 limits a bottom sheet to 640dp: on a phone in landscape the sheet was narrower than the page and
      // the collapsed bar showed on both sides of it, as a second reply box (feedback 111). The sheet spans the page
      // like the bar; its content keeps to the reading column by itself.
      constraints: const BoxConstraints(),
      builder: (_) => _ReplyBar(
        controller: widget.controller,
        outerTextController: controller,
        replyType: widget.replyType,
        chatHistorySendTarget: widget.chatHistorySendTarget,
        chatSendTarget: widget.chatSendTarget,
        disabledEditorFeatures: widget.disabledEditorFeatures,
        fullScreenDisabledEditorFeatures: widget.fullScreenDisabledEditorFeatures,
        fullScreen: widget.fullScreen,
      ),
    );

    rootLocationStream.add(const RootLocationEventEnter('<editor>'));
    widget.controller
      .._sheet = c
      .._showingEditor = true;
    // The draft offered in the box moves into the editor.
    setState(() {});
    await c.closed;
    rootLocationStream.add(const RootLocationEventLeave('<editor>'));
    // Another editor may already be open by the time this one finished closing: only forget our own sheet.
    if (identical(widget.controller._sheet, c) || widget.controller._sheet == null) {
      widget.controller
        .._sheet = null
        .._showingEditor = false;
    }
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void initState() {
    super.initState();
    widget.controller
      ..onSetHintText = showEditor
      .._outerTextController = controller
      .._onTargetChanged = _scheduleTarget;
    // The box shows a hint instead of a reply while nothing can be sent (need login, thread closed).
    _drafts.attach(outerText: () => _enabled ? controller.text : '');
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (!identical(route, _route)) {
      if (_route != null) {
        RouteDrafts.unregister(_route!, _hasDraft);
      }
      _route = route;
      if (route != null) {
        RouteDrafts.register(route, _hasDraft);
      }
    }
  }

  @override
  void didUpdateWidget(ReplyBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    _scheduleTarget();
  }

  @override
  void dispose() {
    if (_route != null) {
      RouteDrafts.unregister(_route!, _hasDraft);
    }
    // What the bar holds is kept on this device before the box goes.
    _drafts.detach();
    if (identical(widget.controller._onTargetChanged, _scheduleTarget)) {
      widget.controller._onTargetChanged = null;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.controller.dispose();
    });
    if (identical(widget.controller._outerTextController, controller)) {
      widget.controller._outerTextController = null;
    }
    // The page may build a new bar with the same controller: the thread page drops the bar while it reloads, e.g.
    // after an account switch. Keep the unsent reply for it; the text is not a reply while it is a hint instead.
    if (_enabled) {
      widget.controller._keptDraft = controller.text.trim().isEmpty ? null : controller.text;
    }
    controller.dispose();
    super.dispose();
  }

  /// Look at the target of the draft after this frame (the page told more, another floor was picked).
  void _scheduleTarget() {
    if (_targetScheduled) {
      return;
    }
    _targetScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _targetScheduled = false;
      if (mounted) {
        _drafts.retarget(_draftTarget());
      }
    });
  }

  /// What the draft of this bar is written for now, null while it cannot tell (no account, nothing to reply to yet).
  _ReplyDraftTarget? _draftTarget() {
    final uid = context.read<AuthenticationRepository>().currentUser?.uid;
    if (uid == null || uid <= 0 || !_enabled) {
      return null;
    }
    switch (widget.replyType) {
      case ReplyTypes.thread || ReplyTypes.notice:
        final parameters = context.read<ReplyBloc>().state.replyParameters;
        final action = widget.controller._replyAction;
        final query = action?.tryParseAsUri()?.queryParameters;
        final tid = parameters?.tid ?? query?['tid'];
        if (tid == null || !_positiveIdRe.hasMatch(tid)) {
          return null;
        }
        final fid = parameters?.fid ?? query?['fid'];
        final pid = _floorOfReplyAction(action);
        if (pid == null) {
          return _ReplyDraftTarget(uid: uid, key: LocalDraftKey.threadReply(tid), fid: fid);
        }
        return _ReplyDraftTarget(
          uid: uid,
          key: LocalDraftKey.floorReply(tid, pid),
          fid: fid,
          replyAction: action,
          hint: widget.controller._hintText,
          quote: widget.controller._quotedAction == null,
        );
      case ReplyTypes.chat:
        final peer = widget.chatSendTarget?.touid;
        return peer != null && _positiveIdRe.hasMatch(peer)
            ? _ReplyDraftTarget(uid: uid, key: LocalDraftKey.message(peer))
            : null;
      case ReplyTypes.chatHistory:
        final peer = widget.chatHistorySendTarget?.targetUrl.tryParseAsUri()?.queryParameters['topmuid'];
        return peer != null && _positiveIdRe.hasMatch(peer)
            ? _ReplyDraftTarget(uid: uid, key: LocalDraftKey.message(peer))
            : null;
    }
  }

  /// Restore the draft offered in the collapsed box: its target and its text, then the editor opens on it.
  void _restoreOffer() {
    final draft = _drafts.takeOffer();
    if (draft == null) {
      return;
    }
    controller.text = draft.body;
    _drafts
      ..setCollapsed(draft.body, delta: draft.delta)
      ..saver.flush();
    final hint = draft.hint;
    if (draft.key.kind == LocalDraftKind.floorReply && hint != null && hint.isNotEmpty) {
      widget.controller.setHintText(hint);
    } else {
      unawaited(showEditor());
    }
  }

  /// Ask the user for the captcha or the security question the forum asks before taking the reply, then send it
  /// again with the answers; not answered, the reply is not sent.
  Future<void> _askVerification(BuildContext context, ReplyState state) async {
    final bloc = context.read<ReplyBloc>();
    final check = state.secCheck;
    if (_verifying) {
      return;
    }
    if (check == null) {
      bloc.add(const ReplyVerificationCancelled());
      return;
    }
    _verifying = true;
    final SecCheckAnswer? answer;
    try {
      answer = await showSecCheckDialog(context, check, wrongAnswer: state.wrongAnswer, browserUrl: state.browserUrl);
    } finally {
      _verifying = false;
    }
    if (bloc.isClosed) {
      return;
    }
    bloc.add(answer == null ? const ReplyVerificationCancelled() : ReplyVerificationAnswered(answer));
  }

  @override
  Widget build(BuildContext context) {
    final hasLogin = context.select<AuthenticationRepository, bool>((repo) => repo.currentUser != null);
    final closed = context.select<ReplyBloc, bool>((bloc) => bloc.state.closed);
    // The target of the draft changes with the reply parameters (the thread loaded, another account).
    context.select<ReplyBloc, ReplyParameters?>((bloc) => bloc.state.replyParameters);
    // With several saved accounts the empty box names the account the reply goes out as (#184); watched, so an
    // account switch renames it.
    final account = watchCurrentAccount(context);
    final hintText = (account?.showsAccount ?? false)
        ? context.t.currentAccount.replyAs(username: account!.username)
        : context.t.threadPage.sendReplyHint;

    Future<void> Function()? onTapCallback;

    if (!hasLogin) {
      controller.text = context.t.threadPage.needLogin;
      onTapCallback = null;
    } else if (closed &&
        // Never close in chat page.
        (widget.replyType != ReplyTypes.chat && widget.replyType != ReplyTypes.chatHistory)) {
      controller.text = context.t.threadPage.closed;
      onTapCallback = null;
    } else {
      onTapCallback = showEditor;
      // The unsent reply of the bar this page showed before it reloaded.
      if (widget.controller._keptDraft case final draft?) {
        widget.controller._keptDraft = null;
        controller.text = draft;
      }
    }
    _enabled = onTapCallback != null;
    _scheduleTarget();

    return BlocConsumer<ReplyBloc, ReplyState>(
      // Only a status change may clear the draft: later states with an unchanged `success` status (e.g. reply
      // parameters refreshed after the thread reloaded) must keep the text and the pending floor target.
      listenWhen: (prev, curr) => prev.status != curr.status,
      listener: (context, state) {
        _drafts.onReplyStatus(state);
        // Clear the outer controller text.
        if (state.status == ReplyStatus.success) {
          controller.clear();
          widget.controller
            .._hintText = null
            .._replyAction = null
            .._quotedAction = null;
          _scheduleTarget();
        } else if (state.status == ReplyStatus.verification) {
          unawaited(_askVerification(context, state));
        }
      },
      buildWhen: (prev, curr) => prev.status != curr.status,
      builder: (context, state) {
        final loading = state.status == ReplyStatus.loading;
        final colorScheme = Theme.of(context).colorScheme;
        final border = OutlineInputBorder(
          borderRadius: BorderRadius.circular(appSurfaceRadius),
          borderSide: BorderSide(color: colorScheme.outlineVariant),
        );
        // The background reaches the screen edges; the field stays inside the side insets (cutout in landscape) and
        // above the gesture bar. Hosts do not wrap the bar in a horizontal SafeArea, which left a blank strip beside
        // the bar (feedback 110): with one, the insets are already consumed here and this adds nothing.
        final sideInsets = MediaQuery.paddingOf(context);
        final field = TextField(
          key: const ValueKey('reply-bar-field'),
          controller: controller,
          readOnly: true,
          enabled: onTapCallback != null,
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: colorScheme.surface,
            hintText: hintText,
            prefixIcon: Icon(
              onTapCallback == null ? Icons.lock_outline : Icons.edit_outlined,
              size: 20,
              color: onTapCallback == null ? colorScheme.outline : colorScheme.primary,
            ),
            suffix: loading ? sizedCircularProgressIndicator : null,
            border: border,
            enabledBorder: border,
            disabledBorder: border,
            focusedBorder: border.copyWith(borderSide: BorderSide(color: colorScheme.primary)),
          ),
          onTap: onTapCallback,
        );
        return DecoratedBox(
          key: const ValueKey('reply-bar-background'),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerLow,
            border: Border(top: BorderSide(color: colorScheme.outlineVariant.withValues(alpha: 0.6))),
          ),
          child: Padding(
            padding: edgeInsetsL12T8R12B8
                .add(EdgeInsets.only(left: sideInsets.left, right: sideInsets.right))
                .add(context.safePadding()),
            // Not AppContentWidth: its Align takes all the height it is offered, and a host that gives the bar a
            // bounded height (Scaffold.bottomNavigationBar) would get a bar as tall as the page, covering the editor
            // sheet above it. heightFactor 1 keeps the bar as tall as its field.
            child: Align(
              alignment: Alignment.topCenter,
              heightFactor: 1,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: appReadingMaxWidth),
                // One rounded box: the same field whether it invites a reply, keeps an unsent one, or explains why
                // replying is not possible (need login, thread closed). A draft kept on this device for the thread or
                // the member is offered above it while the box is empty.
                child: ValueListenableBuilder<DraftOffer?>(
                  valueListenable: _drafts.saver.offer,
                  builder: (context, offer, _) {
                    final offered =
                        offer != null &&
                        _enabled &&
                        !widget.controller._showingEditor &&
                        controller.text.trim().isEmpty;
                    if (!offered) {
                      return field;
                    }
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        DraftOfferBanner(
                          draft: offer.draft,
                          onRestore: _restoreOffer,
                          onDiscard: _drafts.saver.discardOffer,
                        ),
                        sizedBoxW8H8,
                        field,
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Widget provides the reply feature.
class _ReplyBar extends StatefulWidget {
  /// Constructor.
  const _ReplyBar({
    required this.controller,
    required this.replyType,
    required this.outerTextController,
    this.chatHistorySendTarget,
    this.chatSendTarget,
    this.disabledEditorFeatures = const {},
    this.fullScreenDisabledEditorFeatures = const {},
    this.fullScreen = false,
  });

  /// Controller passed from outside.
  final ReplyBarController controller;

  // FIXME: Bad practise. widget controller injected from outside and may
  // dispose earlier than the inner widget is anti-pattern and unstable.
  // Try another implementation to achieve syncing text to outside field.
  /// Text controller in the wrapper widget to show current entered text.
  final TextEditingController outerTextController;

  /// Usage type of [_ReplyBar].
  ///
  /// Different usages have different state and logic.
  final ReplyTypes replyType;

  /// Send target url and parameters when in chat history.
  final ChatHistorySendTarget? chatHistorySendTarget;

  /// Send url parameters when in chat page.
  final ChatSendTarget? chatSendTarget;

  /// Disable all bbcode editor features exists in this list.
  ///
  /// Those disabled features' corresponding widget will be invisible.
  final Set<EditorFeatures> disabledEditorFeatures;

  /// Disabled bbcode editor features when reply bar set to full screen.
  ///
  /// Usually is less than [disabledEditorFeatures].
  ///
  /// Those disabled features' corresponding widget will be invisible.
  final Set<EditorFeatures> fullScreenDisabledEditorFeatures;

  /// Constraints max height?
  final bool fullScreen;

  @override
  State<_ReplyBar> createState() => _ReplyBarState();
}

final class _ReplyBarState extends State<_ReplyBar> with LoggerMixin {
  final panelController = ChatBottomPanelContainerController<_BottomPanelType>();
  _BottomPanelType panelType = _BottomPanelType.none;

  /// Indicate current thread is closed.
  bool _closed = false;

  /// Allow reply bar full screen.
  ///
  /// Will not restrict reply bar height when set to true.
  late bool fullScreen;

  late final StreamSubscription<AuthStatus> _authStatusSub;

  /// Indicate whether have current login user.
  ///
  /// Should disable when no user login.
  bool _hasLogin = false;

  bool canSendReply = false;

  /// Hint text in text field.
  /// When reply to thread, use default hint.
  /// When reply to another post, show that post's info.
  String? _hintText;

  /// Indicate whether sending reply.
  bool isSendingReply = false;
  final _replyFocusNode = FocusNode();

  /// Parameters to reply to thread or post.
  ReplyParameters? _replyParameters;

  /// Url in "action" attribute when post reply.
  ///
  /// * In [ReplyTypes.thread], is the url to get the reply page, not the
  ///   target to post a reply.
  /// * In [ReplyTypes.chatHistory], is the url to post a reply.
  String? _replyAction;

  /// The editor fills the page instead of growing with the text ("全頁回覆").
  bool _maximized = false;

  /// The emoji panel is open: in place of the keyboard on mobile, under the editor on desktop.
  bool _emojiOpen = false;

  /// Ticks while the forum still refuses the next post ([ReplyState.retryAt]).
  Timer? _countdown;

  _ReplyDraftSession get _drafts => widget.controller._drafts;

  /////////// Editor Feature ///////////

  /// After switch editor mode, if we have the following condition before
  /// switching:
  ///
  /// * Editor has focus.
  /// * Editor cursor at the end of text.
  ///
  /// Should keep focus and cursor at the end of text.
  bool hasCursorAtEnd = false;

  /// Rich editor focus node.
  final focusNode = FocusNode();

  /// Show text attribute control button or not.
  bool showTextAttributeButtons = false;

  /// Rich editor controller.
  late BBCodeEditorController _replyRichController;

  /// Flag indicating whether can send the converted bbcode in reply bar to
  /// the outside controller.
  bool _canSyncBBCodeOnDispose = true;

  /// Method to update [_hintText].
  /// Use this method to update text and ui by calling [setState].
  void _setHintText(String hintText) {
    setState(() {
      _hintText = hintText;
    });
    // User set hint text means want to reply to something, then the editor pop
    // up, here should also request focus.
    focusNode.requestFocus();
  }

  // FIXME: Bad practise.
  /// Manually dispose the reply bar widget.
  ///
  /// This function is called when user rebuilt the outer page including:
  ///
  /// * Refresh thread page.
  /// * Change the thread page index.
  ///
  /// In the situations above, the `_ReplyBar` which placed as a bottom sheet
  /// did not auto-disposed somehow so the only way to close it is calling
  /// [ReplyBarController.dispose], which triggered an incorrect but worked
  /// dispose order:
  ///
  /// 1. The outer page (thread page) disposed.
  /// 2. In the `dispose` method of outer page, called `dispose` of
  ///  `ReplyBarController` finally triggered a manual dispose.
  ///
  /// So here everything inside the outer page is disposed, especially the
  /// outer text controller. Here set [_canSyncBBCodeOnDispose] to false to
  /// avoid using the outer text controller after it disposed.
  void _manuallyDispose() {
    _canSyncBBCodeOnDispose = false;
    widget.controller.closeEditor();
  }

  void _clearTextAndHint() {
    setState(() {
      _hintText = null;
      _replyAction = null;
    });
    // The side chosen for a debate reply goes with it (the forum keeps the side of the first reply anyway).
    widget.controller._debateStand = null;
    // Clear saved hint text in controller so text not restore
    // when next time opens.
    widget.controller._hintText = null;
    // Clear reply action to prevent the action applied again when user reopened
    // reply bar without any reply target.
    widget.controller
      .._replyAction = null
      .._quotedAction = null;
    // The draft goes with the editor to the reply to the thread.
    widget.controller._onTargetChanged?.call();
  }

  void _checkEditorContent() {
    final empty = _replyRichController.isEmpty;
    if (empty && canSendReply) {
      setState(() {
        canSendReply = false;
      });
    } else if (!empty && !canSendReply) {
      setState(() {
        canSendReply = true;
      });
    }
  }

  /// The editor changed: the draft is written soon, the counter of the forum's limits follows.
  void _onEditorChanged() {
    _drafts.changed();
    if (_limits != null && mounted) {
      setState(() {});
    }
  }

  /// The draft session told something new (a window info, an offer, another target).
  void _onDraftChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  /// The account and the key of the draft sent now.
  ({int? uid, String? key}) get _draftOfSend {
    _drafts.sending();
    final target = _drafts.target;
    return (uid: target?.uid, key: target?.key.value);
  }

  /// Post reply to thread tid/fid.
  /// This will add a post in thread, as reply to that thread.
  Future<void> _sendReplyThreadMessage() async {
    if (_replyParameters == null) {
      return;
    }
    if (_replyRichController.isEmpty) {
      error('refuse to send post to thread: empty rich text message');
      return;
    }
    final draft = _draftOfSend;
    context.read<ReplyBloc>().add(
      ReplyToThreadRequested(
        replyParameters: _replyParameters!,
        replyMessage: _replyRichController.toForumBBCode(),
        stand: _stand,
        draftUid: draft.uid,
        draftKey: draft.key,
      ),
    );
  }

  /// Post reply to another post in thread tid/fid.
  /// This will add a post in that thread, as a reply to another post.
  Future<void> _sendReplyPostMessage() async {
    if (_replyParameters == null || _replyAction == null) {
      error('failed to reply to post: reply action not set');
      return;
    }

    if (_replyRichController.isEmpty) {
      error('failed to reply to post: reply message is empty');
      return;
    }

    final draft = _draftOfSend;
    context.read<ReplyBloc>().add(
      ReplyToPostRequested(
        replyParameters: _replyParameters!,
        replyAction: _replyAction!,
        replyMessage: _replyRichController.toForumBBCode(), // data,
        stand: _stand,
        draftUid: draft.uid,
        draftKey: draft.key,
      ),
    );
  }

  /// Send message in chat history reply type.
  Future<void> _sendChatHistoryMessage() async {
    if (widget.chatHistorySendTarget == null) {
      error('failed to reply in chat history type: send target is null');
      return;
    }

    if (_replyRichController.isEmpty) {
      error('failed to reply chat history: reply message is empty');
      return;
    }

    final draft = _draftOfSend;
    context.read<ReplyBloc>().add(
      ReplyChatHistoryRequested(
        targetUrl: widget.chatHistorySendTarget!.targetUrl,
        formHash: widget.chatHistorySendTarget!.formHash,
        message: _replyRichController.toForumBBCode(),
        draftUid: draft.uid,
        draftKey: draft.key,
      ),
    );
  }

  Future<void> _sendChatMessage() async {
    if (widget.chatSendTarget == null) {
      error('failed to reply in chat: send target is null');
      return;
    }

    if (_replyRichController.isEmpty) {
      error('failed to reply chat: reply message is empty');
      return;
    }

    final draft = _draftOfSend;
    context.read<ReplyBloc>().add(
      ReplyChatRequested(
        widget.chatSendTarget!.touid,
        {
          'pmsubmit': widget.chatSendTarget!.pmsubmit,
          'touid': widget.chatSendTarget!.touid,
          'formhash': widget.chatSendTarget!.formHash,
          'handlekey': widget.chatSendTarget!.handleKey,
          'message': _replyRichController.toForumBBCode(),
          'messageappend': widget.chatSendTarget!.messageAppend,
        },
        draftUid: draft.uid,
        draftKey: draft.key,
      ),
    );
  }

  /// The side a reply takes in a debate ([ReplyParameters.debate]): the side the account took with its first reply,
  /// or the one chosen above the editor (neutral by default); null for any other thread.
  int? get _stand {
    final parameters = _replyParameters;
    if (parameters == null || !parameters.debate) {
      return null;
    }
    final taken = parameters.debateStand;
    return taken == 1 || taken == 2 ? taken : (widget.controller._debateStand ?? 0);
  }

  /// The side of the next debate reply was chosen elsewhere ([ReplyBarController.debateStand]).
  void _debateStandChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  /// The side of a debate reply, above the editor ([DebateStandSelector]); nothing for any other thread.
  Widget _buildDebateStandRow(BuildContext context) {
    final parameters = _replyParameters;
    if (parameters == null || !parameters.debate || _closed || !_hasLogin) {
      return sizedBoxEmpty;
    }
    return Padding(
      padding: edgeInsetsL12T8R12,
      child: DebateStandSelector(
        fixed: parameters.debateStand == 1 || parameters.debateStand == 2 ? parameters.debateStand : null,
        unknown: parameters.debateStand == null,
        value: widget.controller._debateStand ?? 0,
        onChanged: (stand) => setState(() => widget.controller._debateStand = stand),
      ),
    );
  }

  /// Send message, according to [ReplyTypes].
  Future<void> _sendMessage() async {
    switch (widget.replyType) {
      case ReplyTypes.thread || ReplyTypes.notice:
        {
          if (_replyAction == null && _replyParameters == null) {
            error(
              'failed to send reply: null action and '
              'parameters',
            );
            return;
          }
          _replyAction == null ? await _sendReplyThreadMessage() : await _sendReplyPostMessage();
        }
      case ReplyTypes.chatHistory:
        {
          await _sendChatHistoryMessage();
        }
      case ReplyTypes.chat:
        {
          await _sendChatMessage();
        }
    }
  }

  /// The reply window whose info this editor shows (the quote of the floor, the forum's limits): the floor's reply
  /// link (the quoting one while the quote is taken out), else the reply page of the thread; null in the chat pages
  /// and before the thread loaded.
  String? get _windowUrl {
    if (widget.replyType != ReplyTypes.thread && widget.replyType != ReplyTypes.notice) {
      return null;
    }
    final action = widget.controller._quotedAction ?? _replyAction;
    if (action != null) {
      // A quoting floor: its quote is shown. Its limits too, which only the app API's form tells.
      return action.contains('repquote=') || TsdmAppApi.knowsPostForm ? action : null;
    }
    // The reply to the thread: only the limits, which only the app API's form tells.
    final parameters = _replyParameters;
    return parameters == null || !TsdmAppApi.knowsPostForm
        ? null
        : 'forum.php?mod=post&action=reply&fid=${parameters.fid}&tid=${parameters.tid}&extra=';
  }

  /// The forum's size limits of the reply, null when not known (no app API, a chat page): only the editor's own
  /// judgment applies then (nothing empty is sent).
  MessageLimits? get _limits {
    if (widget.replyType != ReplyTypes.thread && widget.replyType != ReplyTypes.notice) {
      return null;
    }
    final url = _windowUrl;
    return (url == null ? null : _drafts.infoOf(url)?.limits) ?? _drafts.limitsOf(_replyParameters?.tid);
  }

  /// What keeps the reply from being sent as it is: too short or too long for the forum ([_limits]).
  String? _lengthIssue(MessageLimits? limits, String message) {
    if (limits == null || message.trim().isEmpty) {
      return null;
    }
    final tr = context.t.replyBar;
    if (limits.tooLong(message)) {
      return tr.tooLong(max: limits.max ?? 0, count: limits.bytesOf(message));
    }
    if (limits.tooShort(message)) {
      return tr.tooShort(min: limits.min ?? 0, count: limits.bytesOf(message));
    }
    return null;
  }

  /// Seconds left before the forum takes the next post, 0 when it does ([ReplyState.retryAt]).
  int _waitingSeconds(DateTime? retryAt) {
    if (retryAt == null) {
      return 0;
    }
    final left = retryAt.difference(DateTime.now());
    if (left <= Duration.zero) {
      return 0;
    }
    return (left.inMilliseconds / 1000).ceil();
  }

  /// Tick every second while [seconds] remain, then stop.
  void _keepCountingDown(int seconds) {
    if (seconds <= 0) {
      _countdown?.cancel();
      _countdown = null;
      return;
    }
    _countdown ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) {
        return;
      }
      setState(() {});
    });
  }

  /// Whether the send button is enabled: something to send, nothing in flight, thread open, user logged in.
  bool get _sendEnabled => canSendReply && !isSendingReply && !_closed && _hasLogin;

  /// Send from the keyboard, same rules as the send button (#18).
  void _sendByShortcut() {
    if (!_sendEnabled || _blocked) {
      debug('ignore send shortcut: send is disabled');
      return;
    }
    unawaited(_sendMessage());
  }

  /// The forum would refuse the reply as it is (its limits, its interval): the send button waits.
  bool _blocked = false;

  /// Ctrl+Enter and Alt+Enter send while the editor has the focus (#18).
  ///
  /// Desktop only: on mobile the IME owns the Enter key. The editor itself ignores Enter with a modifier held, so
  /// the binding is seen here; a matched binding is reported as handled, which keeps the platform text input from
  /// turning the key into a newline. The activators are exact, Ctrl+Shift+Enter is left alone.
  Widget _wrapWithSendShortcuts(Widget editor) {
    if (!isDesktop) {
      return editor;
    }
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, control: true): _sendByShortcut,
        const SingleActivator(LogicalKeyboardKey.numpadEnter, control: true): _sendByShortcut,
        const SingleActivator(LogicalKeyboardKey.enter, alt: true): _sendByShortcut,
        const SingleActivator(LogicalKeyboardKey.numpadEnter, alt: true): _sendByShortcut,
      },
      child: editor,
    );
  }

  /// Build an editor with bbcode support.
  Widget _buildRichEditor(BuildContext context) {
    return EditorFrame(
      focusNode: focusNode,
      // Room for the corner button that gives the editor the whole page.
      padding: const EdgeInsets.fromLTRB(12, 8, 36, 8),
      child: _wrapWithSendShortcuts(
        RichEditor(
          // Initial text is the text passed from outside.
          controller: _replyRichController,
          editorFocusNode: focusNode,
        ),
      ),
    );
  }

  /// Insert what the emoji panel gave: an emoji, or a saved image as BBCode. The panel stays open.
  void _insertPicked(String code) {
    if (isCustomImageBBCode(code)) {
      _replyRichController.insertBBCode(code);
    } else {
      _replyRichController.insertEmoji(code);
    }
    if (!isMobile) {
      focusNode.requestFocus();
    }
  }

  /// Open or close the emoji panel: in place of the keyboard on mobile, under the editor on desktop.
  void _toggleEmoji() {
    if (isMobile) {
      if (_emojiOpen) {
        panelController.updatePanelType(ChatBottomPanelType.keyboard);
      } else {
        setState(() => fullScreen = false);
        panelController.updatePanelType(ChatBottomPanelType.other, data: _BottomPanelType.emoji);
      }
      return;
    }
    setState(() => _emojiOpen = !_emojiOpen);
  }

  /// Take the quote of the floor out of the reply, or put it back: the reply to the floor goes with the forum's
  /// `reppost` link (the author is still told, nothing quoted) instead of its `repquote` one.
  void _setQuote({required bool quote}) {
    final controller = widget.controller;
    if (quote) {
      final quoted = controller._quotedAction;
      if (quoted == null) {
        return;
      }
      controller
        .._replyAction = quoted
        .._quotedAction = null;
      setState(() => _replyAction = quoted);
    } else {
      final plain = _withoutQuote(_replyAction);
      if (plain == null) {
        return;
      }
      controller
        .._quotedAction = _replyAction
        .._replyAction = plain;
      setState(() => _replyAction = plain);
    }
    controller._onTargetChanged?.call();
  }

  /// Restore the draft offered in the editor: its target (a floor, or the thread) and its text.
  void _restoreOffer() {
    final draft = _drafts.takeOffer();
    if (draft == null) {
      return;
    }
    _replyRichController.loadDraft(
      draft.body,
      delta: draft.delta,
      parse: getIt.get<SettingsRepository>().currentSettings.enableEditorBBCodeParser,
    );
    final hint = draft.hint;
    if (draft.key.kind == LocalDraftKind.floorReply && hint != null && hint.isNotEmpty) {
      widget.controller.setHintText(hint);
    }
    _drafts.saver.flush();
    focusNode.requestFocus();
  }

  /// A row above the reply text area to display some info if needed.
  ///
  /// Currently showing the floor user is replying to (if any), and a button to
  /// set to reply to thread (not any floor).
  Widget _buildHintTextRow(BuildContext context) {
    // No grip above the editor: the collapse button below is the one control that closes the sheet (#139), a second
    // one for the same thing only took room. Swiping the sheet down still works without it.
    final colorScheme = Theme.of(context).colorScheme;
    if (_hintText == null || _closed || !_hasLogin) {
      return sizedBoxW12H12;
    }
    // The floor this reply goes to, as a pill that can be dropped to reply to the thread instead.
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        sizedBoxW12H12,
        Padding(
          padding: edgeInsetsL12R12,
          child: AppInsetBlock(
            color: colorScheme.secondaryContainer,
            padding: const EdgeInsets.only(left: 12),
            child: Row(
              children: [
                Icon(Icons.reply_outlined, size: 18, color: colorScheme.onSecondaryContainer),
                sizedBoxW8H8,
                Expanded(
                  child: Text(
                    _hintText!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(color: colorScheme.onSecondaryContainer),
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.clear_outlined, color: colorScheme.onSecondaryContainer, size: 16),
                  tooltip: context.t.replyBar.notReplyToFloorTip,
                  visualDensity: VisualDensity.compact,
                  onPressed: _clearTextAndHint,
                ),
              ],
            ),
          ),
        ),
        _buildQuoteRow(context),
      ],
    );
  }

  /// The quote of the floor the forum puts in front of the reply (the floor's `repquote` link), with the choice to
  /// leave it out; nothing for the reply to the thread or to a floor that is not quoted (the first floor).
  Widget _buildQuoteRow(BuildContext context) {
    final controller = widget.controller;
    final quoted = controller._quotedAction;
    final action = quoted ?? _replyAction;
    if (action == null || !action.contains('repquote=')) {
      return sizedBoxEmpty;
    }
    final tr = context.t.replyBar;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    if (quoted != null) {
      return Padding(
        padding: edgeInsetsL12T4R12,
        child: Row(
          key: const ValueKey('reply-bar-quote-removed'),
          children: [
            Icon(Icons.format_quote_outlined, size: 16, color: colorScheme.outline),
            sizedBoxW4H4,
            Expanded(
              child: Text(tr.quoteRemoved, style: textTheme.bodySmall?.copyWith(color: colorScheme.outline)),
            ),
            TextButton(
              key: const ValueKey('reply-bar-quote-add'),
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
              onPressed: () => _setQuote(quote: true),
              child: Text(tr.quoteAdd),
            ),
          ],
        ),
      );
    }
    final quote = _drafts.infoOf(action)?.quote;
    final preview = quote == null ? null : quotePreviewOf(quote);
    return Padding(
      padding: edgeInsetsL12T4R12,
      child: Container(
        key: const ValueKey('reply-bar-quote-preview'),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(appInnerRadius),
          border: Border(left: BorderSide(color: colorScheme.primary.withValues(alpha: 0.6), width: 3)),
        ),
        padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    preview == null || preview.header.isEmpty ? tr.quoteLoading : tr.quoteOf(header: preview.header),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.labelMedium?.copyWith(color: colorScheme.outline),
                  ),
                  if (preview != null && preview.body.isNotEmpty)
                    Text(
                      preview.body,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
                    ),
                ],
              ),
            ),
            TextButton.icon(
              key: const ValueKey('reply-bar-quote-remove'),
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
              icon: const Icon(Icons.format_clear_outlined, size: 16),
              label: Text(tr.quoteRemove),
              onPressed: () => _setQuote(quote: false),
            ),
          ],
        ),
      ),
    );
  }

  /// The draft kept on this device for the target, offered while the editor holds something else.
  Widget _buildDraftOffer(BuildContext context) {
    final offer = _drafts.saver.offer.value;
    if (offer == null || _closed || !_hasLogin) {
      return sizedBoxEmpty;
    }
    return Padding(
      padding: edgeInsetsL12T8R12,
      child: DraftOfferBanner(draft: offer.draft, onRestore: _restoreOffer, onDiscard: _drafts.saver.discardOffer),
    );
  }

  /// The size of the reply as the forum counts it against its limits, and what is wrong with it.
  Widget _buildLengthRow(BuildContext context, MessageLimits? limits, String message, String? issue) {
    if (limits == null || message.trim().isEmpty) {
      return sizedBoxEmpty;
    }
    final tr = context.t.replyBar;
    final colorScheme = Theme.of(context).colorScheme;
    final count = limits.bytesOf(message);
    final max = limits.max;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 2),
      child: Text(
        issue ?? (max == null ? tr.lengthCountNoMax(count: count) : tr.lengthCount(count: count, max: max)),
        key: const ValueKey('reply-bar-length'),
        textAlign: TextAlign.end,
        style: Theme.of(
          context,
        ).textTheme.labelSmall?.copyWith(color: issue != null ? colorScheme.error : colorScheme.outline),
      ),
    );
  }

  Widget _buildDesktopToolbar(BuildContext context, ReplyState state) {
    if (isMobile) {
      return sizedBoxEmpty;
    }
    return EditorToolbar(
      bbcodeController: _replyRichController,
      disabledFeatures: fullScreen ? widget.fullScreenDisabledEditorFeatures : widget.disabledEditorFeatures,
      editorFocusNode: focusNode,
    );
  }

  Widget _buildMobileToolbar(BuildContext context, ReplyState state) {
    if (!isMobile) {
      return sizedBoxEmpty;
    }
    return ChatBottomPanelContainer<_BottomPanelType>(
      controller: panelController,
      inputFocusNode: focusNode,
      otherPanelWidget: (type) {
        return switch (type) {
          null => sizedBoxEmpty,
          _BottomPanelType.none => sizedBoxEmpty,
          _BottomPanelType.keyboard => sizedBoxEmpty,
          // The panel color reaches the screen edges, the toolbar buttons stay out of the side insets.
          _BottomPanelType.toolbar => Padding(
            padding: EdgeInsets.only(
              left: MediaQuery.paddingOf(context).left,
              right: MediaQuery.paddingOf(context).right,
            ),
            child: EditorToolbar(
              bbcodeController: _replyRichController,
              disabledFeatures: fullScreen ? widget.fullScreenDisabledEditorFeatures : widget.disabledEditorFeatures,
              editorFocusNode: focusNode,
            ),
          ),
          // As tall as the keyboard it takes the place of, once that was seen.
          _BottomPanelType.emoji => Padding(
            padding: EdgeInsets.only(
              left: MediaQuery.paddingOf(context).left,
              right: MediaQuery.paddingOf(context).right,
            ),
            child: EmojiPanel(
              height: panelController.keyboardHeight > 120 ? panelController.keyboardHeight : 280,
              onPicked: _insertPicked,
            ),
          ),
        };
      },
      onPanelTypeChange: (p, data) {
        final wasEmoji = _emojiOpen;
        switch (p) {
          case ChatBottomPanelType.none:
            panelType = _BottomPanelType.none;
          case ChatBottomPanelType.keyboard:
            panelType = _BottomPanelType.keyboard;
            // TODO: Remove the setState after tricky removed.
            // Some button in editor that use a popup menu does not reset
            // fullScreen flag as we are doing some tricky thing in toolbar.
            //
            // Font size button overridden with an empty font size button
            // option is so:
            //
            // QuillToolbarFontSizeButtonOptions(afterButtonPressed: () {}),
            //
            // Manually set to false.
            if (fullScreen) {
              setState(() {
                fullScreen = false;
              });
            }
          case ChatBottomPanelType.other:
            switch (data) {
              case null:
                panelType = _BottomPanelType.none;
              case _BottomPanelType.none:
                panelType = _BottomPanelType.none;
              case _BottomPanelType.keyboard:
                panelType = _BottomPanelType.keyboard;
              case _BottomPanelType.toolbar:
                panelType = _BottomPanelType.toolbar;
              case _BottomPanelType.emoji:
                panelType = _BottomPanelType.emoji;
            }
        }
        final isEmoji = panelType == _BottomPanelType.emoji;
        if (isEmoji != wasEmoji) {
          setState(() => _emojiOpen = isEmoji);
        }
      },
      panelBgColor: Theme.of(context).colorScheme.surfaceContainerLow,
    );
  }

  Widget _buildContent(BuildContext context, ReplyState state) {
    // The sheet is not in the safe area of the page: like the bar, its background reaches the screen edges and its
    // editor and buttons stay out of the side insets (cutout in landscape, feedback 110).
    final insets = MediaQuery.paddingOf(context);
    final sides = EdgeInsets.only(left: insets.left, right: insets.right);
    return LayoutBuilder(
      // The editor, its toolbar and buttons stay in the reading column of the page on wide windows; the sheet itself
      // and the mobile panel keep the full width.
      builder: (context, constraints) {
        final content = _buildContentIn(
          context,
          state,
          appCenteredPadding(constraints.maxWidth - sides.horizontal, maxWidth: appReadingMaxWidth, minPadding: 0) +
              sides,
        );
        if (!_maximized) {
          return content;
        }
        // The whole page the sheet may take, the editor taking what the rest leaves.
        final height = constraints.maxHeight.isFinite ? constraints.maxHeight : MediaQuery.sizeOf(context).height * 0.9;
        return SizedBox(height: height, child: content);
      },
    );
  }

  Widget _buildContentIn(BuildContext context, ReplyState state, EdgeInsets horizontal) {
    final tr = context.t.replyBar;
    final limits = _limits;
    final message = limits == null ? '' : _replyRichController.toForumBBCode();
    final issue = _lengthIssue(limits, message);
    final waiting = _waitingSeconds(state.retryAt);
    _keepCountingDown(waiting);
    _blocked = issue != null || waiting > 0;
    final windowUrl = _windowUrl;
    if (windowUrl != null) {
      _drafts.prefetch(windowUrl, context.readOrNull<ReplyRepository>() ?? const ReplyRepository());
    }

    final editor = Padding(
      padding: horizontal.add(const EdgeInsets.fromLTRB(12, 8, 12, 4)),
      child: Listener(
        onPointerUp:
            // Only collapse editor toolbar on mobile platforms.
            isMobile
            ? (_) {
                setState(() {
                  fullScreen = false;
                });
              }
            : null,
        // The whole page for a long reply, with what was written, the floor and its quote: a corner button of the
        // writing area, the button row is full on a phone.
        child: Stack(
          fit: _maximized ? StackFit.expand : StackFit.loose,
          children: [
            _buildRichEditor(context),
            PositionedDirectional(
              top: 0,
              end: 0,
              child: IconButton(
                key: const ValueKey('reply-bar-maximize'),
                visualDensity: VisualDensity.compact,
                iconSize: 18,
                color: Theme.of(context).colorScheme.outline,
                icon: Icon(_maximized ? Icons.close_fullscreen_outlined : Icons.open_in_full_outlined),
                tooltip: _maximized ? tr.restoreSizeTip : tr.maximizeTip,
                onPressed: () => setState(() => _maximized = !_maximized),
              ),
            ),
          ],
        ),
      ),
    );

    final Widget sendChild;
    if (isSendingReply) {
      sendChild = sizedCircularProgressIndicator;
    } else if (waiting > 0) {
      sendChild = Text('${waiting}s', key: const ValueKey('reply-bar-countdown'));
    } else {
      sendChild = const Icon(Icons.send);
    }

    final content = Column(
      mainAxisSize: _maximized ? MainAxisSize.max : MainAxisSize.min,
      children: [
        // A draft kept on this device for the target.
        Padding(padding: horizontal, child: _buildDraftOffer(context)),
        // Reply hint row, with the quote of the floor.
        Padding(padding: horizontal, child: _buildHintTextRow(context)),
        // The side of a debate reply.
        Padding(padding: horizontal, child: _buildDebateStandRow(context)),

        // Editor.
        if (_maximized) Expanded(child: editor) else Flexible(child: editor),

        Padding(padding: horizontal, child: _buildLengthRow(context, limits, message, issue)),
        if (!isMobile && _emojiOpen)
          Padding(
            padding: horizontal.add(edgeInsetsL12R12),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(appInnerRadius),
              child: EmojiPanel(height: 240, onPicked: _insertPicked),
            ),
          ),
        Padding(padding: horizontal, child: _buildDesktopToolbar(context, state)),
        Padding(
          padding: horizontal.add(edgeInsetsL12R12B12),
          child: Row(
            children: [
              // Only control expand or collapse on mobile platforms.
              // For desktop, always expand the toolbar.
              if (isMobile)
                IconButton(
                  icon: const Icon(Icons.expand_outlined),
                  selectedIcon: Icon(Icons.expand_outlined, color: Theme.of(context).primaryColor),
                  isSelected: fullScreen,
                  tooltip: fullScreen ? tr.collapseToolbarTip : tr.expandToolbarTip,
                  onPressed: () {
                    setState(() {
                      fullScreen = !fullScreen;
                    });
                    if (fullScreen) {
                      panelController.updatePanelType(ChatBottomPanelType.other, data: _BottomPanelType.toolbar);
                    } else {
                      panelController.updatePanelType(ChatBottomPanelType.keyboard);
                    }
                  },
                ),
              // The emoji panel, kept open while emojis go in; the keyboard comes back with the same button.
              IconButton(
                key: const ValueKey('reply-bar-emoji'),
                icon: Icon(_emojiOpen && isMobile ? Icons.keyboard_outlined : Icons.emoji_emotions_outlined),
                isSelected: _emojiOpen,
                selectedIcon: Icon(
                  isMobile ? Icons.keyboard_outlined : Icons.emoji_emotions,
                  color: Theme.of(context).colorScheme.primary,
                ),
                tooltip: _emojiOpen && isMobile ? tr.keyboardTip : tr.emojiTip,
                onPressed: _toggleEmoji,
              ),
              IconButton(
                icon: const Icon(Icons.quickreply_outlined),
                tooltip: context.t.fastReplyTemplate.title,
                onPressed: () async {
                  final pickResult = await context.pushNamed<FastReplyTemplateModel>(
                    ScreenPaths.fastReplyTemplate,
                    pathParameters: {'pick': 'true'},
                  );

                  if (!context.mounted) {
                    return;
                  }
                  if (pickResult != null) {
                    _replyRichController.insertBBCode(normalizeBlockMarkerNesting(pickResult.data));
                  }
                  focusNode.requestFocus();
                },
              ),
              // The account the reply goes out as, in the free room before the buttons (#184).
              const Expanded(
                child: Align(alignment: AlignmentDirectional.centerStart, child: _CurrentAccountLabel()),
              ),
              Tooltip(
                // "Collapse": the draft is kept in the reply box below, and on this device.
                message: MaterialLocalizations.of(context).expandedIconTapHint,
                child: FilledButton.tonal(
                  onPressed: widget.controller.closeEditor,
                  child: const Icon(Icons.unfold_less),
                ),
              ),
              sizedBoxW8H8,
              // Send Button
              Tooltip(
                message: waiting > 0 ? tr.floodWait(seconds: waiting) : (issue ?? context.t.threadPage.sendReply),
                child: FilledButton(
                  key: const ValueKey('reply-bar-send'),
                  onPressed: _sendEnabled && !_blocked ? () async => _sendMessage() : null,
                  child: sendChild,
                ),
              ),
            ],
          ),
        ),
        _buildMobileToolbar(context, state),
      ],
    );

    return ClipRRect(
      borderRadius: const BorderRadius.only(topLeft: Radius.circular(24), topRight: Radius.circular(24)),
      child: content,
    );
  }

  @override
  void initState() {
    super.initState();
    widget.controller._bind = this;
    final authRepo = context.read<AuthenticationRepository>();
    _hasLogin = authRepo.currentUser != null;
    final outer = widget.outerTextController.text;
    // The editor's own document when the box still holds what the editor left (styles BBCode does not carry), else
    // the text parsed again.
    _replyRichController = _editorControllerFor(outer, delta: _drafts.deltaFor(outer));
    _replyRichController
      ..addListener(_checkEditorContent)
      ..addListener(_onEditorChanged);
    _drafts
      ..attachEditor(_replyRichController)
      ..revision.addListener(_onDraftChanged)
      ..saver.offer.addListener(_onDraftChanged);
    _authStatusSub = authRepo.status.listen((status) {
      setState(() {
        status is AuthStatusAuthed ? _hasLogin = true : _hasLogin = false;
      });
    });
    fullScreen = widget.fullScreen;
    focusNode.requestFocus();
  }

  @override
  void dispose() {
    _countdown?.cancel();
    _replyFocusNode.dispose();
    unawaited(_authStatusSub.cancel());
    final text = _replyRichController.toForumBBCode();
    // Kept on this device now, and as the box's content (with the document, for the next editor).
    _drafts
      ..revision.removeListener(_onDraftChanged)
      ..saver.offer.removeListener(_onDraftChanged)
      ..detachEditor(body: text, delta: _replyRichController.toQuillDelta());
    if (!_canSyncBBCodeOnDispose) {
      // Closed because its bar went away (see [_manuallyDispose]): the page is gone, or it reloaded and builds a new
      // bar. The text written here is newer than what the old bar kept, give it to the new bar or keep it for it.
      // [ReplyBarController._outerTextController] is null or the box of a bar still alive.
      //
      // After this frame, like below: the tree is locked while disposing, and the box of a new bar shown before the
      // sheet finished closing (a quick reload) would rebuild its field now.
      final controller = widget.controller;
      final disposedOuter = widget.outerTextController;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final outer = controller._outerTextController;
        if (outer != null && !identical(outer, disposedOuter)) {
          outer.text = text;
        } else {
          controller._keptDraft = text.trim().isEmpty ? null : text;
        }
      });
    }
    if (_canSyncBBCodeOnDispose) {
      // Only save text that intend to reply when that text is not empty.
      //
      // Only send text to outside controller if could do so: In some situation
      // the `widget.outerTextController` may already disposed if the
      // `_ReplyBar` is manually disposed (by calling _manuallyDispose()).
      // Use the [_canSyncBBCodeOnDispose] to avoid that.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // The wrapper can go away in the same frame as this editor (the page was popped with the editor open, or
        // the thread reloaded): its controller is disposed by then and must not be written to.
        if (identical(widget.controller._outerTextController, widget.outerTextController)) {
          widget.outerTextController.text = text;
        }
      });
    }
    _replyRichController
      ..removeListener(_checkEditorContent)
      ..removeListener(_onEditorChanged)
      ..dispose();
    widget.controller._unbind(clearParameters: false);
    focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<ReplyBloc, ReplyState>(
      listener: (context, state) {
        // Clear text one time when user send request succeed.
        if (state.status == ReplyStatus.success && state.needClearText) {
          _replyRichController.clearWithoutRequestingFocus();
          // Reset flag because we only want to clear the sent text.
          context.read<ReplyBloc>().add(ReplyResetClearTextStateTriggered());
          _clearTextAndHint();
        }
      },
      child: BlocBuilder<ReplyBloc, ReplyState>(
        builder: (context, state) {
          if (state.status == ReplyStatus.loading) {
            // Now is pending reply actions.
            isSendingReply = true;
            canSendReply = false;
          } else if (state.status == ReplyStatus.success) {
            // Last reply is succeed, clear reply message.
            isSendingReply = false;
          } else if (state.status == ReplyStatus.failure || state.status == ReplyStatus.verification) {
            // Last reply action is failed (or waits for the answers to the forum's checks), only clear pending state.
            isSendingReply = false;
            // When failed to reply, we did NOT clear any text so is ready for
            // next try.
            canSendReply = true;
          }

          // Should update close state of the current reply bar because we may
          // not send reply to closed threads.
          _closed = switch (widget.replyType) {
            ReplyTypes.thread || ReplyTypes.notice => state.closed,
            ReplyTypes.chatHistory || ReplyTypes.chat => false,
          };
          _replyParameters = state.replyParameters;

          return _buildContent(context, state);
        },
      ),
    );
  }
}

/// Avatar and name of the account a reply goes out as, beside the send button of the editor (#184).
///
/// Only with more than one saved account, like [CurrentAccountChip]; unlike it the name shrinks to the room left in
/// the button row, so a long name never pushes the send button off a narrow phone.
class _CurrentAccountLabel extends StatelessWidget {
  const _CurrentAccountLabel();

  @override
  Widget build(BuildContext context) {
    final account = watchCurrentAccount(context);
    if (account == null || !account.showsAccount) {
      return const SizedBox.shrink();
    }
    final username = account.username;
    final colorScheme = Theme.of(context).colorScheme;
    return Tooltip(
      key: const ValueKey('reply-bar-account'),
      message: context.t.currentAccount.replyAs(username: username),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 6,
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: HeroUserAvatar(
                key: ValueKey(username),
                username: username,
                avatarUrl: account.avatarUrl,
                disableHero: true,
              ),
            ),
            Flexible(
              child: Text(
                username,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(color: colorScheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Controller of [ReplyBar].
///
/// Used to fill parameters and update state.
final class ReplyBarController with LoggerMixin {
  _ReplyBarState? _state;

  void Function()? _onSetHintTextCallback;

  /// The local draft of the bars of this controller ([_ReplyDraftSession]).
  late final _ReplyDraftSession _drafts = _ReplyDraftSession(this);

  /// Called when the target of the draft may have changed (another floor, the reply to the thread), by the bar on
  /// screen.
  VoidCallback? _onTargetChanged;

  /// The floor's quoting reply link (`repquote`) while the quote is taken out of the reply ([_replyAction] is then its
  /// `reppost` link), null otherwise.
  String? _quotedAction;

  /// Controller of the expanded editor (a bottom sheet), non-null while one is showing.
  PersistentBottomSheetController? _sheet;

  /// Text controller of the collapsed reply box currently on screen, null while no [ReplyBar] is mounted.
  ///
  /// The expanded editor syncs its draft back into it when it closes; the identity check tells whether that
  /// controller is still alive.
  TextEditingController? _outerTextController;

  /// Unsent reply of a bar that went away while its page stays (the thread page reloads without a bar), handed to the
  /// next bar built with this controller.
  ///
  /// Not cleared with the other values in [_unbind]: it outlives the bar on purpose. The account switch of the avatar
  /// menu reloads the thread page (GitHub #184 follow-up), and the reply written there must not be lost.
  String? _keptDraft;

  /// Flag indicating currently popping up the editor or not.
  ///
  /// Use this flag to keep only one editor popup.
  ///
  /// So the text in editor is persistent.
  bool _showingEditor = false;

  /// Flag indicating whe editor is expanded or not.
  bool get showingEditor => _showingEditor;

  /// The key of the local draft the bar writes now ([LocalDraftKey.value]), null while it has no target.
  @visibleForTesting
  String? get draftKey => _drafts.target?.key.value;

  /// The reply link the next reply to a floor goes with, null for the reply to the thread.
  @visibleForTesting
  String? get currentReplyAction => _replyAction;

  /// Close the expanded editor if it is showing, do nothing otherwise.
  ///
  /// Closes the bottom sheet through its own controller instead of popping the navigator: a pop issued once the
  /// sheet is already gone closes the page underneath. That is how a successful reply used to close the thread page:
  /// the page popped the sheet, reloaded the thread, the reload disposed the reply bar and the bar popped again.
  void closeEditor() {
    if (!_showingEditor) {
      return;
    }
    _showingEditor = false;
    final sheet = _sheet;
    _sheet = null;
    sheet?.close();
  }

  /// All values temporarily saved here MUST be cleared when [_unbind] called.
  ///
  /// Temporary value that saves before [_state] bind.
  /// Because sometimes we bind these values before bind a state.
  /// Defer sync values in [_state] till we have a state by called [_bind].
  String? _replyAction;
  bool? _closed;
  String? _hintText;

  /// The side chosen for a debate reply (0 neutral, 1 affirmative, 2 negative), kept across editors until a reply
  /// is sent; null when none was chosen (neutral).
  int? _debateStand;

  /// The side chosen for a debate reply, see [ReplyParameters.debate].
  int? get debateStand => _debateStand;

  /// Choose the side of the next debate reply (the debate card's "加入正方／反方").
  set debateStand(int? stand) {
    _debateStand = stand;
    _state?._debateStandChanged();
  }

  // Internal _bind setter.
  // ignore: avoid_setters_without_getters
  set _bind(_ReplyBarState state) {
    _state = state;
    // All values temporarily saved here MUST be cleared when `_unbind` called.
    if (_replyAction != null) {
      _state!._replyAction = _replyAction;
      debug('update reply action');
    }
    if (_closed != null) {
      _state!._closed = _closed!;
    }
    if (_hintText != null) {
      _state!._hintText = _hintText;
    }
  }

  /// Unbind state.
  ///
  /// This function is called when state got disposed.
  /// So that all actions triggered after state disposal and before next state
  /// init is:
  ///
  /// 1. Saved temporarily in controller.
  /// 2. Applied to new state when next state init.
  ///
  /// Clear [_replyAction], [_hintText] and [_closed].
  /// when [clearParameters] is true.
  /// Set [clearParameters] to false when you want to reserve these parameters.
  void _unbind({bool clearParameters = true}) {
    // Clear state.
    _state = null;

    // Clear temporarily saved values.
    if (clearParameters) {
      _replyAction = null;
      _hintText = null;
      _closed = null;
    }
  }

  /// Reply to the thread instead of a floor (a draft of the thread restored).
  void _replyToThread() {
    final state = _state;
    if (state != null) {
      state._clearTextAndHint();
      return;
    }
    _replyAction = null;
    _hintText = null;
    _quotedAction = null;
    _debateStand = null;
    _onTargetChanged?.call();
  }

  /// Set reply action url to current state. Call this when user try to reply
  /// to another post, before user writes the reply or sends it.
  ///
  // ignore: avoid_setters_without_getters
  set replyAction(String? replyAction) {
    // Save the reply action no matter state already constructed or not.
    //
    // Since the reply bar became more stateless in pre-release of v1, here the
    // reply action assignment will override with an outdated value if user
    // changed the post to reply when reply bar is in expanded state:
    //
    // 1. User clicked a floor #1, reply bar expanded and _state?._replyAction
    //   set to #1.
    // 2. User clicked another floor #2, reply bar still in expand state and
    //   _state._replyAction set to #2.
    // 3. User closed reply bar and state disposed.
    // 4. User reopened the reply bar without clicking any floor, from here it
    //   is expected to keep the same reply action which is held the last time
    //   which is #2 in this case, but the setter of _replyAction set it back
    //   to #2.
    //
    // save the reply action value no matter state is contructed or not, because
    // the controller class is a value storage lives longer than state itself.
    _replyAction = replyAction;
    // Another floor quotes as it comes.
    _quotedAction = null;
    _onTargetChanged?.call();
    if (_state == null) {
      return;
    }
    _state!._replyAction = replyAction;
    debug('update reply parameters');
  }

  /// Thread closed or not.
  bool get closed => _state?._closed ?? _closed ?? false;

  set closed(bool closed) {
    if (_state == null) {
      _closed = closed;
      return;
    }
    _state!._closed = closed;
  }

  /// Set the hint text.
  void setHintText(String hintText) {
    _onSetHintTextCallback?.call();
    // Save the hint text no matter state already constructed or not.
    // See setter `replyAction` for the reason.
    _hintText = hintText;
    _onTargetChanged?.call();
    if (_state == null) {
      return;
    }
    _state!._setHintText(hintText);
  }

  /// Function to call when [setHintText] called.
  ///
  /// Use this to popup editor.
  ///
  // ignore: avoid_setters_without_getters
  set onSetHintText(void Function() callback) {
    _onSetHintTextCallback = callback;
  }

  /// Let the [ReplyBar] get the focus.
  void requestFocus() {
    if (_closed ?? false) {
      _state?._replyFocusNode.requestFocus();
    }
  }

  // FIXME: Bad practise/anti-pattern. This method here only proves that current
  // implementation of syncing text through reply bar and the dispose process is
  // broken and need refactor. Currently the dispose order is complex and does
  // not following a correct child-to-parent order.
  /// Close the bound reply bar.
  void dispose() => _state?._manuallyDispose();
}
