import 'dart:async';
import 'dart:convert';

import 'package:chat_bottom_container/chat_bottom_container.dart';
import 'package:collection/collection.dart';
import 'package:dart_bbcode_parser/dart_bbcode_parser.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bbcode_editor/flutter_bbcode_editor.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:tsdm_client/constants/constants.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/bbcode_editor_controller.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/editor/widgets/editor_frame.dart';
import 'package:tsdm_client/features/editor/widgets/rich_editor.dart';
import 'package:tsdm_client/features/editor/widgets/toolbar.dart';
import 'package:tsdm_client/features/local_draft/models/local_draft.dart';
import 'package:tsdm_client/features/local_draft/repository/local_draft_store.dart';
import 'package:tsdm_client/features/local_draft/utils/draft_autosaver.dart';
import 'package:tsdm_client/features/local_draft/widgets/draft_offer_banner.dart';
import 'package:tsdm_client/features/multi_user/widgets/current_account_avatar.dart';
import 'package:tsdm_client/features/post/bloc/post_edit_bloc.dart';
import 'package:tsdm_client/features/post/models/models.dart';
import 'package:tsdm_client/features/post/models/poll_create.dart';
import 'package:tsdm_client/features/post/repository/post_edit_repository.dart';
import 'package:tsdm_client/features/post/utils/discuz_text.dart';
import 'package:tsdm_client/features/post/utils/flood_control.dart';
import 'package:tsdm_client/features/post/widgets/input_price_dialog.dart';
import 'package:tsdm_client/features/post/widgets/leave_edit_dialog.dart';
import 'package:tsdm_client/features/post/widgets/sec_check_dialog.dart';
import 'package:tsdm_client/features/post/widgets/select_perm_dialog.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/bbcode/spoiler_normalizer.dart';
import 'package:tsdm_client/utils/browser_launcher.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/utils/platform.dart';
import 'package:tsdm_client/utils/retry_button.dart';
import 'package:tsdm_client/utils/show_bottom_sheet.dart';
import 'package:tsdm_client/utils/show_dialog.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/indicator.dart';
import 'package:tsdm_client/widgets/section_switch_list_tile.dart';
import 'package:tsdm_client/widgets/selectable_list_tile.dart';

/// Default thread title text length (bytes size in utf-8 encoding).
///
/// Actually this value should be provided by the server. Only use this value
/// if not found.
const _defaultThreadTitleMaxlength = 210;

/// Enum indicating the way to save data, or call it post data to server.
///
/// When publishing a new thread or editing thread draft, user can choose one of
/// the following save method.
///
/// * Save in draft.
/// * Publish as new thread (no longer a draft).
///
/// So here is going to have two buttons for each method.
///
/// Use this enum to display different widget style so that user knows which
/// method was chosen.
enum _UploadMethod {
  /// No upload action triggered yet.
  notYet,

  /// Publish new thread action triggered.
  publish,

  /// Save thread in draft action triggered.
  saveDraft,
}

enum _BottomPanelType { none, keyboard, toolbar }

/// Page lets the user to edit a post.
///
/// This is a full screen page, as an alternative choice to edit a post.
///
/// Not only edit the post:
///
/// * Edit an existing post.
/// * Write a new thread. Because the "thread" is a special post that at the
///   first floor.
/// * Edit existing thread.
///
/// Though writing a new thread looks like a different reason, it is the same
/// with editing a new post.
///
/// # Pop back
///
/// This page is allowed to pop when editing, which means:
///
/// * The user is writing something new, new post or new thread.
/// * The user want to write the post without this page (e.g. in a `ReplyBar`).
///
/// Here we need to ensure:
///
/// * Pop the edit page safely.
/// * Pass the latest edit content back to where user enter this page.
///
/// So when pop back: let the route return value to be a valid object
/// representing the latest edit content.
///
/// Note that this kind of return value is NEVER going to happen when editing
/// something already existed (e.g. edit post and thread) because the all edit
/// ability MUST be in the page. And in this situation we need to notify
/// the user "You are going to leave this page and everything you edited will
/// lost".
class PostEditPage extends StatefulWidget {
  /// Constructor.
  const PostEditPage({
    required this.editType,
    required this.fid,
    required this.tid,
    required this.pid,
    this.pollOffered = false,
    this.transfer,
    super.key,
  });

  /// The forum page offered a poll creation link to the current account; only used for new threads.
  ///
  /// The poll page still validates the forum's own form before offering any input.
  final bool pollOffered;

  /// Subject and body carried over from the poll editor.
  final ThreadModeTransfer? transfer;

  /// Reason to enter [PostEditPage].
  ///
  /// This page is used by multiple reasons:
  ///
  /// * Write a new post.
  /// * Edit an existing post.
  final PostEditType editType;

  /// Forum id of the post.
  final String fid;

  /// Thread id of the post.
  final String? tid;

  /// Post id of the post.
  final String? pid;

  @override
  State<PostEditPage> createState() => _PostEditPageState();
}

class _PostEditPageState extends State<PostEditPage> with LoggerMixin {
  final panelController = ChatBottomPanelContainerController<_BottomPanelType>();
  _BottomPanelType panelType = _BottomPanelType.none;

  /// Allow reply bar full screen.
  ///
  /// Will not restrict reply bar height when set to true.
  late bool fullScreen;

  /// Show text attribute control button or not.
  bool showTextAttributeButtons = false;

  final focusNode = FocusNode();

  /// Key of the form.
  final formKey = GlobalKey<FormState>();

  /// User selected [ThreadType] value.
  PostEditThreadType? threadType;

  /// Text controller of thread type form field.
  ///
  /// This text is only a visible text, actual used thread type value is saved
  /// in [threadType].
  final threadTypeController = TextEditingController();

  /// Text controller of thread title form field.
  final threadTitleController = TextEditingController();

  /// Rest length that user can input.
  ///
  /// Thread title has a max length limited by server.
  /// Use this field to record how many bytes of char user can input.
  int threadTitleRestLength = 0;

  // TODO: Do NOT use bool flag.
  /// Flag to control only init state when first build in loaded state.
  ///
  /// This is ugly.
  bool init = false;

  /// Additional options used here.
  ///
  /// Here we copy and save the additional options in state to here. This avoid
  /// updating state when user just changed an option. Only apply these options
  /// to state when posting the data to server.
  ///
  /// Key is option's attribute name.
  /// Value is the option itself.
  Map<String, PostEditContentOption>? additionalOptionsMap;

  /// Optional permission set to access this thread.
  ///
  /// Only used when editing thread, not other floors' posts.
  ThreadPerm? threadPerm;

  /// Optional price set to this thread.
  ///
  /// Only used when editing thread, not other floors' posts.
  int? price;

  late BBCodeEditorController bbcodeController;

  bool initialized = false;
  bool _confirming = false;

  /// Content switched in from the poll editor by the same account, dropped on any identity change.
  ThreadModeTransfer? _transfer;

  // BBCode text attribute status.
  Color? foregroundColor;
  Color? backgroundColor;
  int? fontSizeLevel;

  /// Enum indicating which upload method user has triggered.
  ///
  /// Only used when:
  ///
  /// * Drafting a new thread.
  /// * Editing thread draft.
  _UploadMethod uploadMethod = _UploadMethod.notYet;

  /// The title and the post as loaded into the editor (an edit of an existing post or draft): leaving asks only when
  /// they changed. A new thread asks whenever there is anything.
  String? _loadedTitle;
  String? _loadedBody;

  /// The leave dialog is up.
  bool _leaving = false;

  /// The local draft of this editor, kept on this device while it is written ([LocalDraftStore]): `thread:<fid>` for a
  /// new thread, `edit:<pid>` for an edit; null without a post to key it by.
  late final LocalDraftKey? _draftKey = switch (widget.editType) {
    PostEditType.newThread => LocalDraftKey.newThread(widget.fid),
    PostEditType.editPost || PostEditType.editDraft => widget.pid == null ? null : LocalDraftKey.edit(widget.pid!),
  };

  /// The account the local draft belongs to: the one this editor opened for.
  int? _draftUid;

  /// Writes the local draft.
  late final DraftAutosaver _drafts = DraftAutosaver(read: _draftSnapshot);

  /// Nothing more is kept for the local draft: sent, discarded, or another account took over.
  bool _draftStopped = false;

  /// The stored draft was looked for, once the form loaded.
  bool _draftLooked = false;

  /// A name of the target for the list of drafts: the forum of a new thread, the title of an edited thread.
  String? _draftTitle;

  /// When the forum takes the next post after it refused one as too soon (`post_flood_ctrl`), null when it does.
  DateTime? _retryAt;

  /// Ticks while [_retryAt] is ahead.
  Timer? _countdown;

  /// The dialog asking for the captcha or the security question is up.
  bool _verifying = false;

  /// The form tells the forum's size limits of the post: its size is shown while it changes.
  bool _bodyCounted = false;

  /// What the editor holds as its local draft, nothing while the form is not loaded or nothing changed.
  DraftSnapshot? _draftSnapshot() {
    final uid = _draftUid;
    final key = _draftKey;
    if (uid == null || key == null || _draftStopped || !initialized) {
      return null;
    }
    if (!_hasUnsentContent) {
      return (uid: uid, key: key, draft: null);
    }
    return (
      uid: uid,
      key: key,
      draft: LocalDraft(
        key: key,
        body: bbcodeController.toForumBBCode(),
        delta: bbcodeController.toQuillDelta(),
        subject: threadTitleController.text,
        updatedAt: DateTime.now(),
        fid: widget.fid,
        tid: widget.tid,
        title: _draftTitle,
        typeId: threadType?.typeID,
      ),
    );
  }

  /// Offer the draft kept for this editor, once its form is in the editor.
  Future<void> _offerDraft() async {
    final uid = _draftUid;
    final key = _draftKey;
    if (_draftLooked || uid == null || key == null || !initialized) {
      return;
    }
    _draftLooked = true;
    await _drafts.offerStored(uid, (k) => k == key);
  }

  /// Put the offered draft into the editor: its title, its post and its thread type.
  void _restoreDraft(PostEditState state) {
    final draft = _drafts.takeOffer();
    if (draft == null) {
      return;
    }
    setState(() {
      if (draft.subject case final String subject) {
        threadTitleController.text = subject;
        threadTitleRestLength =
            (state.content?.threadTitleMaxLength ?? _defaultThreadTitleMaxlength) -
            (state.content?.titleLength(subject) ?? subject.parseUtf8Length);
      }
      final type = state.content?.threadTypeList?.firstWhereOrNull((e) => e.typeID == draft.typeId);
      if (draft.typeId != null && type != null) {
        threadType = type;
        threadTypeController.text = type.name;
      }
    });
    bbcodeController.loadDraft(
      draft.body,
      delta: draft.delta,
      parse: context.read<SettingsBloc>().state.settingsMap.enableEditorBBCodeParser,
    );
    _drafts.flush();
  }

  /// Keep nothing more for the local draft, and delete it when [delete] (sent, discarded).
  void _stopDraft({required bool delete}) {
    if (_draftStopped) {
      return;
    }
    final uid = _draftUid;
    final key = _draftKey;
    if (delete && uid != null && key != null) {
      _drafts.sent(uid, key);
    } else {
      _drafts.flush();
    }
    _draftStopped = true;
  }

  /// The post changed: written soon, its size against the forum's limits shown.
  void _onBodyChanged() {
    if (mounted && _bodyCounted) {
      // The post is also set while the page builds (the form loaded): shown after that frame.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    }
  }

  /// Seconds left before the forum takes the next post, 0 when it does.
  int get _waitingSeconds {
    final retryAt = _retryAt;
    if (retryAt == null) {
      return 0;
    }
    final left = retryAt.difference(DateTime.now());
    return left <= Duration.zero ? 0 : (left.inMilliseconds / 1000).ceil();
  }

  /// The forum refused the post as too soon after the previous one: the send buttons wait the time it said.
  void _waitForFlood(int seconds) {
    _retryAt = FloodControl.retryAt(_draftUid, seconds);
    _countdown?.cancel();
    _countdown = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_waitingSeconds <= 0) {
        timer.cancel();
        _countdown = null;
        _retryAt = null;
      }
      setState(() {});
    });
    setState(() {});
  }

  /// Whether the editor holds content not sent yet that leaving would drop.
  bool get _hasUnsentContent {
    final title = threadTitleController.text;
    final body = bbcodeController.toForumBBCode();
    if (widget.editType == PostEditType.newThread) {
      return title.trim().isNotEmpty || body.trim().isNotEmpty;
    }
    // Still loading: nothing typed yet.
    if (_loadedTitle == null || _loadedBody == null) {
      return false;
    }
    return title != _loadedTitle || body != _loadedBody;
  }

  /// Leave the page (the back button or gesture): with content not sent yet ([_hasUnsentContent]) while it is being
  /// edited, ask first whether to discard it, save it as a draft (when the form allows it) or keep editing. Used to
  /// drop the content right away.
  Future<void> _onLeave(BuildContext context) async {
    if (_leaving) {
      return;
    }
    final bloc = context.read<PostEditBloc>();
    if (_confirming) {
      // About to send: the confirmation decides.
      return;
    }
    if (bloc.state.status == PostEditStatus.uploading) {
      // Sending: leaving now hides whether it was stored, the user decides.
      final tr = context.t.postEditPage.leaveDialog;
      _leaving = true;
      final bool? leave;
      try {
        leave = await showQuestionDialog(context: context, title: tr.title, message: tr.sending, dangerous: true);
      } finally {
        _leaving = false;
      }
      if ((leave ?? false) && context.mounted) {
        context.pop();
      }
      return;
    }
    final editing =
        bloc.state.content != null &&
        (bloc.state.status == PostEditStatus.editing || bloc.state.status == PostEditStatus.failedToUpload);
    if (!editing || !_hasUnsentContent) {
      context.pop();
      return;
    }
    final canSaveDraft =
        widget.editType.isEditingDraft && (bloc.state.content?.canSaveDraft ?? false) && bloc.canSubmit;
    _leaving = true;
    final LeaveEditChoice choice;
    try {
      choice = await showLeaveEditDialog(
        context,
        canSaveDraft: canSaveDraft,
        keepsLocalDraft: _draftKey != null && _draftUid != null && !_draftStopped && LocalDraftStore.app != null,
      );
    } finally {
      _leaving = false;
    }
    if (!context.mounted) {
      return;
    }
    switch (choice) {
      case LeaveEditChoice.discard:
        // Discarded: the local draft goes too.
        _stopDraft(delete: true);
        context.pop();
      case LeaveEditChoice.keepDraft:
        // Written when the page goes.
        context.pop();
      case LeaveEditChoice.saveDraft:
        // Leaves by itself once the draft is saved; stays with the content when saving failed.
        await _onFinish(context, bloc.state, saveDraft: true, confirmed: true);
      case LeaveEditChoice.keepEditing:
        break;
    }
  }

  static String _formatDataUrl({required String fid, required String tid, required String pid}) {
    return '$baseUrl/forum.php?mod=post&action=edit&fid=$fid&tid=$tid&pid=$pid';
  }

  /// Continue this new thread or this edit on the website.
  Future<void> _openBrowser(BuildContext context) async {
    final url = widget.editType == PostEditType.newThread
        ? '$baseUrl/forum.php?mod=post&action=newthread&fid=${widget.fid}'
        : _formatDataUrl(fid: widget.fid, tid: widget.tid!, pid: widget.pid!);
    try {
      await openInExternalBrowser(Uri.parse(url));
    } on Object {
      if (context.mounted) showSnackBar(context: context, message: context.t.general.failedToLoad);
    }
  }

  EditorDocumentMetadata collectThreadMetata() {
    final metadata = EditorDocumentMetadata.empty().copyWith(
      title: threadTitleController.text,
      typeId: threadType?.typeID,
      additionalOptions: additionalOptionsMap?.values
          .map((e) => EditorDocumentAdditionalOption(name: e.name, checked: e.checked))
          .toList(),
      price: price,
      perm: threadPerm?.perm,
    );
    debug('collected editor metadata');
    return metadata;
  }

  void applyThreadMetadata(EditorDocumentMetadata metadata, PostEditState state) {
    if (metadata.isEmpty) {
      debug('empty thread metadata');
      return;
    }

    final metadataTitle = metadata.title;
    final metadataThreadType = state.content?.threadTypeList?.firstWhereOrNull(
      (e) => e.typeID == metadata.typeId,
    );
    final metadataAddtionalOptions = metadata.additionalOptions
        .where((e) => additionalOptionsMap?.containsKey(e.name) ?? false)
        .toList();
    final metadataPrice = metadata.price;
    final metadataPerm = state.content?.permList?.firstWhereOrNull(
      (e) => e.perm == metadata.perm,
    );

    if (metadataTitle == null &&
        metadataThreadType == null &&
        metadataAddtionalOptions.isEmpty &&
        metadataPrice == null &&
        metadataPerm == null) {
      debug(
        'failed to apply thread metadata: invalid metadata: '
        'title=$metadataTitle, threadType=$metadataThreadType, '
        'additionalOptions=${jsonEncode(metadataAddtionalOptions)}, '
        'price=$metadataPrice, perm=$metadataPerm',
      );
      return;
    }

    setState(() {
      if (metadataTitle != null) {
        threadTitleController.text = metadataTitle;
      }

      if (metadataThreadType != null) {
        threadType = metadataThreadType;
        threadTypeController.text = metadataThreadType.name;
      }

      if (additionalOptionsMap != null && metadataAddtionalOptions.isNotEmpty) {
        for (final option in metadataAddtionalOptions) {
          additionalOptionsMap![option.name] = additionalOptionsMap![option.name]!.copyWith(checked: option.checked);
        }
      }

      if (metadataPrice != null) {
        price = metadataPrice;
      }

      if (metadataPerm != null) {
        threadPerm = metadataPerm;
      }
    });

    debug('applied thread metadata');
  }

  Set<EditorFeatures> get _disabledFeatures {
    final disabledFeatures = Set<EditorFeatures>.from(
      fullScreen ? defaultFullScreenDisabledEditorFeatures : defaultEditorDisabledFeatures,
    );
    if (price != null) {
      // Having price means currently we are editing the first floor.
      disabledFeatures.remove(EditorFeatures.free);
    }

    return disabledFeatures;
  }

  /// Why the forum would refuse the type, the title or the post of a post form of its app API as they are (plugin
  /// 2.9.0), checked before anything is confirmed or sent: a type the forum requires, the title (escaped then
  /// `dstrlen`: an ASCII character 1, any other 2, `&` 5) against its limits, the post in UTF-8 bytes (the minimum
  /// without quotes). Null when nothing is wrong, and always for the web page, which tells none of this (the forum keeps
  /// the last word).
  String? _formIssue(BuildContext context, PostEditContent content) {
    final form = content.form;
    if (form == null) return null;
    final tr = context.t.postEditPage;
    final title = threadTitleController.text;
    final message = bbcodeController.toForumBBCode();
    final opening = form.action == 'newthread' || form.first;
    // The forum requires a type of an ordinary thread when the forum says so (a new thread, its first post edited).
    if (opening && form.typeInput != null && form.typeRequired && (int.tryParse(threadType?.typeID ?? '') ?? 0) <= 0) {
      return tr.threadTypeShouldNotBeEmpty;
    }
    if (form.subject != null) {
      if (opening && discuzTrim(title).isEmpty) return tr.titleShouldNotBeEmpty;
      if (content.titleTooLong(title, _defaultThreadTitleMaxlength)) {
        return tr.titleTooLongLimit(limit: form.subjectLimit);
      }
      if (content.titleTooShort(title)) return tr.titleTooShortLimit(limit: form.subjectMin ?? 0);
    }
    if (content.messageTooShort(message)) return tr.threadBodyTooShortLimit(limit: form.messageMin ?? 0);
    if (content.messageTooLong(message)) return tr.threadBodyTooLongLimit(limit: form.messageMax ?? 0);
    return null;
  }

  /// [confirmed]: the user already chose to save the draft (when leaving the page), not asked again.
  ///
  /// A new thread the forum asks a captcha or a security question for ([PostEditContent.secCheck], or [check] when it
  /// refused the last attempt for them, [wrongAnswer] when the answers sent were not taken) is sent with the answers the
  /// user gives first; the post is not sent when the user gives none. Asked again after such a refusal, the
  /// confirmations of the first attempt are not asked again.
  Future<void> _onFinish(
    BuildContext context,
    PostEditState state, {
    bool saveDraft = false,
    bool confirmed = false,
    SecCheck? check,
    bool wrongAnswer = false,
  }) async {
    final bloc = context.read<PostEditBloc>();
    if (_confirming || !bloc.canSubmit || !identical(state.content, bloc.state.content)) return;
    if (saveDraft && !state.content!.canSaveDraft) return;
    if (_waitingSeconds > 0) return;
    final issue = _formIssue(context, state.content!);
    if (issue != null) {
      showSnackBar(context: context, message: issue);
      return;
    }
    // Asked after the forum refused the post: the confirmations were given for it already.
    final again = check != null;
    setState(() => _confirming = true);
    try {
      if (widget.editType.isEditingDraft && !(saveDraft && confirmed) && !again) {
        final tr = context.t.postEditPage.threadPublish;
        final ret = await showQuestionDialog(
          context: context,
          title: saveDraft ? context.t.postEditPage.saveAsDraft : tr.title,
          message: saveDraft ? context.t.draftBox.saveConfirm : null,
          richMessage: saveDraft
              ? null
              : tr.warningBeforePost.body(
                  forumName: TextSpan(
                    text: state.forumName ?? '#${widget.fid}',
                    style: TextStyle(color: Theme.of(context).colorScheme.primary),
                  ),
                  threadTitle: TextSpan(
                    text: threadTitleController.text,
                    style: TextStyle(color: Theme.of(context).colorScheme.primary),
                  ),
                  threadType: TextSpan(
                    text: threadTypeController.text,
                    style: TextStyle(color: Theme.of(context).colorScheme.primary),
                  ),
                  warning: TextSpan(
                    text: tr.warningBeforePost.warning,
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ),
        );
        if (ret != true) {
          return;
        }
      }
      // The forum sends new posts of this forum to its moderators first (plugin 2.9.0, the form's `moderated`): say so
      // before anything is sent. A draft stays private and is not reviewed.
      if (!saveDraft && state.content!.moderated && !again) {
        if (!context.mounted) return;
        final tr = context.t.postEditPage.moderated;
        final ret = await showQuestionDialog(context: context, title: tr.title, message: tr.message);
        if (ret != true) {
          return;
        }
      }
      if (!context.mounted || !bloc.canSubmit || !identical(state.content, bloc.state.content)) {
        return;
      }

      // The captcha or the security question the forum asks for a new thread (an edit is never checked).
      SecCheckAnswer? verification;
      final asked = check ?? state.content!.secCheck;
      if (widget.editType == PostEditType.newThread && asked != null) {
        verification = await _askVerification(context, asked, wrongAnswer: wrongAnswer);
        if (verification == null || !context.mounted || !bloc.canSubmit) {
          return;
        }
      }

      final event = switch (widget.editType) {
        PostEditType.editPost || PostEditType.editDraft => PostEditCompleteEditRequested(
          formHash: state.content!.formHash,
          postTime: state.content!.postTime,
          delattachop: state.content?.delattachop ?? '0',
          page: state.content!.page!,
          wysiwyg: state.content!.wysiwyg,
          fid: widget.fid,
          // Not null when editing post
          tid: widget.tid!,
          // Not null when editing post
          pid: widget.pid!,
          threadType: threadType,
          threadTitle: threadTitleController.text,
          data: bbcodeController.toForumBBCode(),
          options: additionalOptionsMap?.values.toList() ?? [],
          save: saveDraft ? '1' : '',
          perm: threadPerm?.perm,
          price: price,
          draftKey: _draftKey?.value,
        ),
        PostEditType.newThread => ThreadPubPostThread(
          ThreadPublishInfo(
            formHash: state.content!.formHash,
            postTime: state.content!.postTime,
            delAttachOp: state.content?.delattachop ?? '0',
            wysiwyg: state.content?.wysiwyg ?? '0',
            fid: widget.fid,
            threadType: threadType,
            checkbox: '0',
            subject: threadTitleController.text,
            message: bbcodeController.toForumBBCode(),
            perm: threadPerm?.perm,
            price: price,
            save: saveDraft ? '1' : '',
            options: additionalOptionsMap?.values.toList() ?? [],
          ),
          verification: verification,
          draftKey: _draftKey?.value,
        ),
      };
      if (saveDraft) {
        uploadMethod = _UploadMethod.saveDraft;
      } else {
        uploadMethod = _UploadMethod.publish;
      }
      context.read<PostEditBloc>().add(event);
    } finally {
      if (mounted) setState(() => _confirming = false);
    }
  }

  /// Ask the user for the captcha and the security question of [check]; null when not answered.
  Future<SecCheckAnswer?> _askVerification(BuildContext context, SecCheck check, {bool wrongAnswer = false}) async {
    if (_verifying) {
      return null;
    }
    _verifying = true;
    try {
      return await showSecCheckDialog(
        context,
        check,
        wrongAnswer: wrongAnswer,
        browserUrl: '$baseUrl/forum.php?mod=post&action=newthread&fid=${widget.fid}',
      );
    } finally {
      _verifying = false;
    }
  }

  // TODO: Fix duplicate with same logic in fast reply edit page.
  Widget _buildMobileToolbar(BuildContext context, PostEditState state) {
    return ChatBottomPanelContainer<_BottomPanelType>(
      controller: panelController,
      inputFocusNode: focusNode,
      otherPanelWidget: (type) {
        return switch (type) {
          null => sizedBoxEmpty,
          _BottomPanelType.none => sizedBoxEmpty,
          _BottomPanelType.keyboard => sizedBoxEmpty,
          _BottomPanelType.toolbar => Align(
            child: EditorToolbar(
              bbcodeController: bbcodeController,
              disabledFeatures: _disabledFeatures,
              editorFocusNode: focusNode,
              collectDocumentMetadata: collectThreadMetata,
              applyDocumentMetadata: (metadata) => applyThreadMetadata(metadata, state),
            ),
          ),
        };
      },
      onPanelTypeChange: (p, data) {
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
            }
        }
      },
      panelBgColor: Theme.of(context).colorScheme.surfaceContainerLow,
    );
  }

  /// Show a modal bottom sheet to let user select a thread type.
  ///
  /// Note that the content data `state.content.threadTypeList` MUST be
  /// guaranteed to have values before calling this function.
  Future<void> _showSelectThreadTypeBottomSheet(BuildContext context, PostEditState state) async {
    await showCustomBottomSheet<void>(
      context: context,
      title: context.t.postEditPage.editPostTitle,
      childrenBuilder: (context) => state.content!.threadTypeList!
          .map(
            (e) => SelectableListTile(
              title: Text(e.name),
              selected: e.name == threadTypeController.text,
              onTap: () {
                threadType = e;
                threadTypeController.text = e.name;
                context.pop();
              },
            ),
          )
          .toList(),
    );
  }

  /// Show a bottom sheet to let user configure the additional options provided
  /// by the server side.
  ///
  /// Options are a list of checkbox.
  ///
  /// Note that the additional options map MUST NOT a null value.
  Future<void> _showAdditionalOptionBottomSheet(BuildContext context, PostEditState state) async {
    await showCustomBottomSheet<void>(
      context: context,
      title: context.t.postEditPage.additionalOptions,
      childrenBuilder: (context) => additionalOptionsMap!.values
          .map(
            (e) => StatefulBuilder(
              builder: (context, setState) {
                return SectionSwitchListTile(
                  title: Text(e.readableName),
                  value: additionalOptionsMap![e.name]!.checked,
                  onChanged: e.disabled
                      ? null
                      : (value) => setState(() {
                          additionalOptionsMap![e.name] = e.copyWith(checked: value);
                        }),
                );
              },
            ),
          )
          .toList(),
    );
  }

  /// Thread type and title fields: side by side on wide windows, the type above the title on phones and with large
  /// text, so neither field is squeezed.
  Widget _buildTitleRow(BuildContext context, PostEditState state) {
    final tr = context.t.postEditPage;

    Widget? typeField;
    if (state.content?.threadTypeList?.isNotEmpty ?? false) {
      typeField = TextFormField(
        key: formKey,
        controller: threadTypeController,
        decoration: InputDecoration(labelText: tr.threadType, suffixIcon: const Icon(Icons.arrow_drop_down)),
        readOnly: true,
        onTap: () async => _showSelectThreadTypeBottomSheet(context, state),
        // Only auto focus to title field when writing new thread.
        validator: (v) {
          if (widget.editType.isEditingPost) {
            // Skip check when editing post, post have no thread type.
            return null;
          }

          // Thread type should not be null nor no more than zero.
          if (v == null ||
              threadType == null ||
              threadType!.typeID == null ||
              ((threadType!.typeID?.parseToInt() ?? -1) <= 0)) {
            return tr.threadTypeShouldNotBeEmpty;
          }
          return null;
        },
      );
    }

    // Always add title no matter thread type presents or not.
    // All thread floors have a legal "subject" here.
    //
    // With the post form of the forum's app API the title counts as the forum counts it (an ASCII character 1, any
    // other 2) against its limit, in the error color when it is outside the limits; the web page tells no limit, the
    // bytes left of the editor's own limit are shown.
    final form = state.content?.form;
    final title = threadTitleController.text;
    final titleOutOfLimits =
        form != null &&
        form.subject != null &&
        title.isNotEmpty &&
        ((state.content?.titleTooLong(title, _defaultThreadTitleMaxlength) ?? false) ||
            (state.content?.titleTooShort(title) ?? false));
    final titleField = TextFormField(
      controller: threadTitleController,
      decoration: InputDecoration(
        labelText: tr.title,
        suffixText: form != null && form.subject != null
            ? ' ${tr.titleCount(count: discuzSubjectLength(title), max: form.subjectLimit)}'
            : ' $threadTitleRestLength',
        suffixStyle: titleOutOfLimits ? TextStyle(color: Theme.of(context).colorScheme.error) : null,
        suffixIcon: IconButton(
          icon: const Icon(Icons.info_outline),
          onPressed: () async => showMessageSingleButtonDialog(
            context: context,
            title: tr.whyTitleDialog.title,
            message: tr.whyTitleDialog.detail,
          ),
        ),
      ),
      onChanged: (value) {
        setState(() {
          threadTitleRestLength =
              (state.content?.threadTitleMaxLength ?? _defaultThreadTitleMaxlength) -
              (state.content?.titleLength(value) ?? value.parseUtf8Length);
        });
      },
      validator: (v) {
        if (widget.editType.isEditingPost) {
          // Skip check when editing post, post have no thread type.
          return null;
        }
        if (v == null) {
          return tr.titleShouldNotBeEmpty;
        }
        final titleLength = state.content?.titleLength(v) ?? v.parseUtf8Length;
        if (titleLength <= 0) {
          return tr.titleShouldNotBeEmpty;
        }
        if (state.content?.titleTooLong(v, _defaultThreadTitleMaxlength) ??
            titleLength >= _defaultThreadTitleMaxlength) {
          return tr.titleTooLong;
        }
        return null;
      },
    );
    if (typeField == null) {
      return titleField;
    }
    final type = typeField;
    return LayoutBuilder(
      builder: (context, constraints) {
        // Keep the title at least ~16 characters wide beside the type, otherwise stack them.
        final stacked = constraints.maxWidth < MediaQuery.textScalerOf(context).scale(520);
        if (stacked) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [type, sizedBoxW8H8, titleField],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 180, child: type),
            sizedBoxW12H12,
            Expanded(child: titleField),
          ],
        );
      },
    );
  }

  /// Build the row of editor controls (toolbar, options, templates, permission, price) under the writing area.
  Widget _buildControlRow(BuildContext context, PostEditState state, EdgeInsets horizontalPadding) {
    return EditorControlBar(
      padding: horizontalPadding.add(edgeInsetsT4B4),
      leading: [
        // Only control expand or collapse on mobile platforms.
        // For desktop, always expand the toolbar.
        if (isMobile)
          IconButton(
            icon: const Icon(Icons.expand),
            tooltip: context.t.bbcodeEditor.toolbar,
            selectedIcon: Icon(Icons.expand_outlined, color: Theme.of(context).primaryColor),
            isSelected: fullScreen,
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
        if (additionalOptionsMap != null)
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: context.t.bbcodeEditor.additionalOptions,
            onPressed: () async => _showAdditionalOptionBottomSheet(context, state),
          ),
        // Reply template
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
              bbcodeController.insertBBCode(normalizeBlockMarkerNesting(pickResult.data));
            }
            focusNode.requestFocus();
          },
        ),
        if (state.content?.permList?.isNotEmpty ?? false)
          Badge(
            label: Text(threadPerm?.perm ?? ''),
            offset: const Offset(-4, 4),
            isLabelVisible: threadPerm != null && threadPerm!.perm.isNotEmpty,
            child: IconButton(
              icon: const Icon(Icons.lock_open_outlined),
              selectedIcon: const Icon(Icons.lock_outline),
              isSelected: threadPerm != null && threadPerm!.perm.isNotEmpty,
              tooltip: context.t.bbcodeEditor.readPerm,
              onPressed: () async {
                final selectedPerm = await showSelectPermDialog(context, state.content!.permList!, threadPerm);
                if (selectedPerm == null || !context.mounted) {
                  return;
                }
                setState(() {
                  threadPerm = selectedPerm;
                });
              },
            ),
          ),
        if (price != null)
          Badge(
            label: Text('$price'),
            textStyle: Theme.of(context).textTheme.labelSmall,
            offset: const Offset(-4, 4),
            isLabelVisible: price != null && price != 0,
            child: IconButton(
              icon: const Icon(Icons.money_off_outlined),
              tooltip: context.t.postEditPage.priceDialog.entryTooltip,
              selectedIcon: const Icon(Icons.attach_money_outlined),
              isSelected: price != null && price != 0,
              onPressed: () async {
                // TODO: show a dialog to set price.
                final inputPrice = await showInputPriceDialog(context, price, state.content?.maxPrice);
                if (inputPrice != null) {
                  setState(() {
                    price = inputPrice;
                  });
                }
              },
            ),
          ),
      ],
    );
  }

  /// The size of the post as the forum counts it against its limits (the post form of its app API), in the error
  /// color outside of them; nothing for the web page, which tells no limit.
  Widget _buildBodyLength(BuildContext context, PostEditState state, EdgeInsets horizontal) {
    final content = state.content;
    final limits = content?.messageLimits;
    if (content == null || limits == null) {
      return sizedBoxEmpty;
    }
    final message = bbcodeController.toForumBBCode();
    if (message.trim().isEmpty) {
      return sizedBoxEmpty;
    }
    final tr = context.t.postEditPage;
    final count = limits.bytesOf(message);
    final String text;
    var invalid = true;
    if (content.messageTooLong(message)) {
      text = tr.threadBodyTooLongLimit(limit: limits.max ?? 0);
    } else if (content.messageTooShort(message)) {
      text = tr.threadBodyTooShortLimit(limit: limits.min ?? 0);
    } else {
      invalid = false;
      final max = limits.max;
      text = max == null ? tr.bodyCountNoMax(count: count) : tr.bodyCount(count: count, max: max);
    }
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: horizontal.add(const EdgeInsets.fromLTRB(4, 0, 4, 4)),
      child: Text(
        text,
        key: const ValueKey('post-edit-body-length'),
        textAlign: TextAlign.end,
        style: Theme.of(
          context,
        ).textTheme.labelSmall?.copyWith(color: invalid ? colorScheme.error : colorScheme.outline),
      ),
    );
  }

  Widget _buildBody(BuildContext context, PostEditState state) {
    if (state.status == PostEditStatus.identityChanged) {
      return AppStateView(icon: Icons.manage_accounts_outlined, message: context.t.draftBox.accountChanged);
    }
    if (state.status == PostEditStatus.unsupported || state.status == PostEditStatus.verificationRequired) {
      // Switched in from the poll editor: what the member typed there stays to read and copy for the website.
      final transfer = _transfer;
      final transferred = transfer != null && (transfer.subject.trim().isNotEmpty || transfer.body.trim().isNotEmpty);
      final view = AppStateView(
        icon: state.status == PostEditStatus.verificationRequired ? Icons.verified_user_outlined : Icons.web_outlined,
        message: state.status == PostEditStatus.verificationRequired
            ? context.t.postEditPage.verificationRequired
            : context.t.draftBox.unsupported,
        action: TextButton.icon(
          icon: const Icon(Icons.open_in_browser_outlined),
          onPressed: () async => _openBrowser(context),
          label: Text(context.t.draftBox.openBrowser),
        ),
        scrollable: !transferred,
      );
      if (!transferred) {
        return view;
      }
      return SingleChildScrollView(
        padding: edgeInsetsL16R16B12,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            view,
            _TransferredContent(transfer: transfer),
          ],
        ),
      );
    }
    if (state.status == PostEditStatus.initial || state.status == PostEditStatus.loading) {
      return const CenteredCircularIndicator();
    }
    if (state.status == PostEditStatus.failedToLoad) {
      // The forum's message shown instead of the form, when it told one (plugin 2.9.0: no permission, a password
      // forum, an edit time limit…).
      return buildRetryButton(context, () {
        switch (widget.editType) {
          case PostEditType.editPost || PostEditType.editDraft:
            context.read<PostEditBloc>().add(
              PostEditLoadDataRequested(
                _formatDataUrl(
                  fid: widget.fid,
                  // Not null when editing post
                  tid: widget.tid!,
                  // Not null when editing post
                  pid: widget.pid!,
                ),
              ),
            );
          case PostEditType.newThread:
            context.read<PostEditBloc>().add(ThreadPubFetchInfoRequested(fid: widget.fid));
        }
      }, message: state.errorText);
    }

    if (!initialized) {
      final data = _transfer?.body ?? state.content?.data;
      if (data != null) {
        if (context.read<SettingsBloc>().state.settingsMap.enableEditorBBCodeParser) {
          final delta = parseBBCodeTextToDelta(normalizeBlockMarkerNesting(data));
          bbcodeController.setDocumentFromDelta(delta);
        } else {
          bbcodeController.setDocumentFromRawText(normalizeBlockMarkerNesting(data));
        }
      }
      _loadedBody = bbcodeController.toForumBBCode();
      initialized = true;
    }

    // Title fields and the writing area stay at a readable width on wide windows; the bars under them keep the full
    // width of the page with their buttons aligned to the same column.
    return LayoutBuilder(
      builder: (context, constraints) {
        final horizontal = appCenteredPadding(constraints.maxWidth, maxWidth: appReadingMaxWidth);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // The draft kept on this device for this new thread or this edit.
            ValueListenableBuilder<DraftOffer?>(
              valueListenable: _drafts.offer,
              builder: (context, offer, _) => offer == null
                  ? sizedBoxEmpty
                  : Padding(
                      padding: horizontal.add(edgeInsetsT12),
                      child: DraftOfferBanner(
                        draft: offer.draft,
                        onRestore: () => _restoreDraft(state),
                        onDiscard: _drafts.discardOffer,
                      ),
                    ),
            ),
            Padding(padding: horizontal.add(edgeInsetsT12), child: _buildTitleRow(context, state)),
            // Post data editor.
            // Now we don't restrict the thread type and thread title, so it's better to focus on content area.
            Expanded(
              child: Padding(
                padding: horizontal.add(const EdgeInsets.symmetric(vertical: 12)),
                child: EditorFrame(
                  focusNode: focusNode,
                  child: RichEditor(autoFocus: true, controller: bbcodeController, editorFocusNode: focusNode),
                ),
              ),
            ),
            _buildBodyLength(context, state, horizontal),
            if (isDesktop)
              ColoredBox(
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                child: Padding(
                  padding: horizontal.add(edgeInsetsT4),
                  child: EditorToolbar(
                    bbcodeController: bbcodeController,
                    disabledFeatures: _disabledFeatures,
                    editorFocusNode: focusNode,
                    collectDocumentMetadata: collectThreadMetata,
                    applyDocumentMetadata: (metadata) => applyThreadMetadata(metadata, state),
                  ),
                ),
              ),
            _buildControlRow(context, state, horizontal),
            if (isMobile) _buildMobileToolbar(context, state),
          ],
        );
      },
    );
  }

  Future<void> _onListen(BuildContext context, PostEditState state) async {
    _bodyCounted = state.content?.messageLimits != null;
    if (state.status == PostEditStatus.identityChanged) {
      // What was written stays the draft of the account it was written for; nothing goes to the next one.
      _stopDraft(delete: false);
      _transfer = null;
      threadTitleController.clear();
      threadTypeController.clear();
      bbcodeController.setDocumentFromRawText('');
      additionalOptionsMap = null;
      return;
    }
    if (state.status == PostEditStatus.failedToUpload && state.secCheck != null) {
      // The forum asks for a captcha or a security question (or did not take the answers): asked, then sent again.
      final check = state.secCheck!;
      final saveDraft = uploadMethod == _UploadMethod.saveDraft;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!context.mounted) return;
        await _onFinish(
          context,
          context.read<PostEditBloc>().state,
          saveDraft: saveDraft,
          confirmed: true,
          check: check,
          wrongAnswer: state.wrongAnswer,
        );
      });
      return;
    }
    if (state.status == PostEditStatus.failedToUpload) {
      // Sent too soon after the previous post: the send buttons count down the forum's interval.
      if (floodControlSeconds(state.errorText) case final seconds?) {
        _waitForFlood(seconds);
      }
      showSnackBar(
        context: context,
        // The forum asked for a captcha or a security question when the post was sent: nothing was posted, the
        // content stays to continue on the website.
        message: state.needsBrowser
            ? context.t.postEditPage.verificationRequired
            : state.errorText ??
                  (widget.editType.isEditingPost
                      ? context.t.draftBox.editUnconfirmed
                      : context.t.draftBox.submitUnconfirmed),
        action: state.needsBrowser
            ? SnackBarAction(label: context.t.draftBox.openBrowser, onPressed: () async => _openBrowser(context))
            : null,
      );
      if (isMobile) {
        WidgetsBinding.instance.focusManager.primaryFocus?.unfocus();
      }
    } else if (state.status == PostEditStatus.draftUnconfirmed) {
      _stopDraft(delete: true);
      await showMessageSingleButtonDialog(
        context: context,
        title: context.t.draftBox.title,
        message: context.t.draftBox.acceptedUnconfirmed,
      );
      if (context.mounted && context.read<PostEditRepository>().isCurrent) context.pop(true);
    } else if (state.status == PostEditStatus.stillDraft) {
      _stopDraft(delete: true);
      // Published from the app, but the forum keeps it a draft (a scheduled publication): no "go to the new thread".
      await showMessageSingleButtonDialog(
        context: context,
        title: context.t.draftBox.title,
        message: context.t.draftBox.stillDraft,
      );
      if (context.mounted && context.read<PostEditRepository>().isCurrent) context.pop(true);
    } else if (state.status == PostEditStatus.success) {
      // Sent: the local draft goes (the bloc deleted it already, also for a page closed meanwhile).
      _stopDraft(delete: true);
      if (uploadMethod == _UploadMethod.saveDraft) {
        if (widget.editType == PostEditType.editDraft) {
          showSnackBar(context: context, message: context.t.draftBox.saved);
          context.pop(true);
          return;
        }
        final view = await showQuestionDialog(
          context: context,
          title: context.t.draftBox.saved,
          message: context.t.draftBox.viewSaved,
        );
        if (!context.mounted || !context.read<PostEditRepository>().isCurrent) return;
        if (view ?? false) {
          context.pushReplacementNamed(ScreenPaths.myThread, queryParameters: {'tab': 'drafts'});
        } else {
          context.pop(true);
        }
        return;
      }
      // Some action succeeded.
      if (widget.editType.isEditingPost) {
        // Edit post.
        showSnackBar(context: context, message: context.t.postEditPage.editSuccess);
        context.pop(true);
        return;
      } else if (widget.editType.isEditingDraft) {
        // Writing new post.
        //
        // Ask for a redirect to just published thread page.
        if (state.redirectTid != null) {
          // Could redirect to new thread page.
          final tr = context.t.postEditPage.threadPublish.afterPostDialog;
          final result = await showQuestionDialog(context: context, title: tr.title, message: tr.message);
          if (!context.mounted || !context.read<PostEditRepository>().isCurrent) {
            return;
          }
          if (result ?? false) {
            context.pushReplacementNamed(ScreenPaths.threadV1, queryParameters: {'tid': state.redirectTid});
            return;
          }
        }

        context.pop(true);
      }
    } else if (state.status == PostEditStatus.editing && !init) {
      threadTypeController.text = state.content?.threadType?.name ?? '  ';
      threadTitleController.text = _transfer?.subject ?? state.content?.threadTitle ?? '';
      _loadedTitle = threadTitleController.text;
      // Update the length of chars user can still input.
      // Bytes of chars for title in utf-8 encoding.
      threadTitleRestLength =
          (state.content?.threadTitleMaxLength ?? _defaultThreadTitleMaxlength) -
          (state.content?.titleLength(threadTitleController.text) ?? threadTitleController.text.parseUtf8Length);
      if (state.content?.options != null) {
        additionalOptionsMap = Map.fromEntries(state.content!.options!.map((e) => MapEntry(e.name, e)));
      }

      setState(() {
        threadType ??= state.content?.threadType;
        // Automatically select the first thread type like the server
        // does.
        //
        // Usually the first type is a hint to choose type with 0 as
        // value.
        threadType ??= state.content?.threadTypeList?.firstOrNull;
        threadTypeController.text = threadType?.name ?? '';
        threadPerm = state.content?.permList?.where((e) => e.selected).lastOrNull;
        price = state.content?.price;
      });

      init = true;
      // The list of drafts names the target: the edited thread, the forum of a new one.
      final loadedTitle = state.content?.threadTitle?.trim() ?? '';
      _draftTitle = widget.editType == PostEditType.newThread || loadedTitle.isEmpty ? state.forumName : loadedTitle;
      // Once the post is in the editor (this frame), the draft kept for it is offered.
      WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_offerDraft()));
    } else if (state.status == PostEditStatus.editing) {
      setState(() {
        threadPerm = state.content?.permList?.where((e) => e.selected).lastOrNull;
        price = state.content?.price;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    debug(
      'enter post edit page: '
      'editType=${widget.editType}, fid=${widget.fid}',
    );
    bbcodeController = buildBBCodeEditorController();
    fullScreen = isDesktop;
    // The local draft: written while the title and the post change, for the account this editor opened for.
    _draftUid = context.read<AuthenticationRepository>().effectiveCurrentUid;
    threadTitleController.addListener(_drafts.changed);
    bbcodeController
      ..addListener(_drafts.changed)
      ..addListener(_onBodyChanged);
    _drafts.attach();
    final transfer = widget.transfer;
    if (widget.editType == PostEditType.newThread &&
        transfer != null &&
        transfer.appliesTo(uid: context.read<AuthenticationRepository>().effectiveCurrentUid, fid: widget.fid)) {
      _transfer = transfer;
    }
  }

  /// Intentional mode switch: subject and body go to the poll page, which fetches its own form; nothing is posted.
  void _switchToPoll(BuildContext context) {
    if (!mounted || ModalRoute.of(context)?.isActive == false || !context.read<PostEditRepository>().isCurrent) {
      return;
    }
    final uid = context.read<AuthenticationRepository>().effectiveCurrentUid;
    context.pushReplacementNamed(
      ScreenPaths.createPoll,
      pathParameters: {'fid': widget.fid},
      extra: uid == null || !initialized
          ? null
          : ThreadModeTransfer(
              uid: uid,
              fid: widget.fid,
              subject: threadTitleController.text,
              body: bbcodeController.toForumBBCode(),
            ),
    );
  }

  @override
  void dispose() {
    _countdown?.cancel();
    // What is not sent is kept on this device before the editor goes.
    _drafts.dispose();
    bbcodeController.dispose();
    focusNode.dispose();
    threadTypeController.dispose();
    threadTitleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final title = switch (widget.editType) {
      PostEditType.newThread => context.t.postEditPage.newThreadTitle,
      PostEditType.editPost || PostEditType.editDraft => context.t.postEditPage.editPostTitle,
    };

    return MultiBlocProvider(
      providers: [
        RepositoryProvider(
          create: (context) => PostEditRepository(
            client: getIt.get<NetClientProvider>(),
            currentUid: () => context.read<AuthenticationRepository>().effectiveCurrentUid,
          ),
        ),
        BlocProvider(
          create: (context) {
            final bloc = PostEditBloc(
              postEditRepository: context.repo(),
              authenticationChanges: context.read<AuthenticationRepository>().status,
            );

            final event = switch (widget.editType) {
              PostEditType.editPost || PostEditType.editDraft => PostEditLoadDataRequested(
                _formatDataUrl(fid: widget.fid, tid: widget.tid!, pid: widget.pid!),
              ),
              PostEditType.newThread => ThreadPubFetchInfoRequested(fid: widget.fid),
            };
            bloc.add(event);
            return bloc;
          },
        ),
      ],
      child: BlocConsumer<PostEditBloc, PostEditState>(
        listener: (context, state) async => _onListen(context, state),
        builder: (context, state) {
          // Below the bloc: leaving asks what to do with content not sent yet, and may save it as a draft.
          return PopScope(
            canPop: false,
            onPopInvokedWithResult: (didPop, _) async {
              if (didPop) {
                return;
              }
              await _onLeave(context);
            },
            child: Scaffold(
              // Required by chat_bottom_container in the reply bar.
              resizeToAvoidBottomInset: false,
              appBar: AppBar(
                title: Text(title),
                // Under the title, not among the actions: beside three buttons a name squeezed the title away on a
                // phone (#184).
                bottom: postingAsBarOf(context),
                actions: [
                  if (widget.editType == PostEditType.newThread &&
                      widget.pollOffered &&
                      state.status != PostEditStatus.uploading &&
                      state.status != PostEditStatus.success &&
                      state.status != PostEditStatus.draftUnconfirmed &&
                      state.status != PostEditStatus.identityChanged)
                    IconButton(
                      tooltip: context.t.pollCreate.switchToPoll,
                      icon: const Icon(Icons.poll_outlined),
                      onPressed: _confirming ? null : () => _switchToPoll(context),
                    ),
                  if (widget.editType.isEditingDraft && (state.content?.canSaveDraft ?? false)) ...[
                    IconButton(
                      onPressed: _confirming || _waitingSeconds > 0 || !context.read<PostEditBloc>().canSubmit
                          ? null
                          : () async => _onFinish(context, state, saveDraft: true),
                      icon: state.status == PostEditStatus.uploading && uploadMethod == _UploadMethod.saveDraft
                          ? sizedCircularProgressIndicator
                          : Icon(MdiIcons.contentSaveEditOutline, color: Theme.of(context).colorScheme.secondary),
                      tooltip: context.t.postEditPage.saveAsDraft,
                    ),
                  ],
                  IconButton(
                    key: const ValueKey('post-edit-publish'),
                    // Refused as too soon after the previous post: the seconds the forum still waits.
                    tooltip: _waitingSeconds > 0
                        ? context.t.replyBar.floodWait(seconds: _waitingSeconds)
                        : context.t.postEditPage.publish,
                    icon: state.status == PostEditStatus.uploading && uploadMethod == _UploadMethod.publish
                        ? sizedCircularProgressIndicator
                        : _waitingSeconds > 0
                        ? Text('${_waitingSeconds}s', key: const ValueKey('post-edit-countdown'))
                        : const Icon(Icons.send),
                    onPressed: _confirming || _waitingSeconds > 0 || !context.read<PostEditBloc>().canSubmit
                        ? null
                        : () async => _onFinish(context, state),
                  ),
                ],
              ),
              body: SafeArea(bottom: false, child: _buildBody(context, state)),
            ),
          );
        },
      ),
    );
  }
}

/// The title and the post the member typed in the poll editor before switching here, shown when this editor cannot
/// take the form (the website instead): selectable, with a button copying both.
class _TransferredContent extends StatelessWidget {
  const _TransferredContent({required this.transfer});

  final ThreadModeTransfer transfer;

  @override
  Widget build(BuildContext context) {
    final tr = context.t.postEditPage;
    final text = [transfer.subject, transfer.body].where((e) => e.trim().isNotEmpty).join('\n\n');
    return Card(
      margin: edgeInsetsT12,
      child: Padding(
        padding: edgeInsetsL16T16R16B16,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr.transferredContent, style: Theme.of(context).textTheme.titleSmall),
            sizedBoxW8H8,
            if (transfer.subject.trim().isNotEmpty)
              SelectableText(transfer.subject, style: Theme.of(context).textTheme.titleMedium),
            if (transfer.subject.trim().isNotEmpty && transfer.body.trim().isNotEmpty) sizedBoxW8H8,
            if (transfer.body.trim().isNotEmpty) SelectableText(transfer.body),
            sizedBoxW8H8,
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                icon: const Icon(Icons.copy_outlined),
                label: Text(tr.copyTransferred),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: text));
                  if (context.mounted) showSnackBar(context: context, message: context.t.general.copiedToClipboard);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
