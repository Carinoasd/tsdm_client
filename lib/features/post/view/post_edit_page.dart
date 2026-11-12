import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chat_bottom_container/chat_bottom_container.dart';
import 'package:collection/collection.dart';
import 'package:dart_bbcode_parser/dart_bbcode_parser.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bbcode_editor/flutter_bbcode_editor.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tsdm_client/constants/constants.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/bbcode_editor_controller.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/extensions/date_time.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/custom_emoji/models/custom_emoji.dart';
import 'package:tsdm_client/features/custom_emoji/repository/custom_emoji_store.dart';
import 'package:tsdm_client/features/custom_emoji/utils/custom_emoji_send.dart';
import 'package:tsdm_client/features/custom_emoji/widgets/custom_emoji_grid.dart';
import 'package:tsdm_client/features/editor/utils/mention_suggestions.dart';
import 'package:tsdm_client/features/editor/utils/paste_aware_controller.dart';
import 'package:tsdm_client/features/editor/widgets/editor_frame.dart';
import 'package:tsdm_client/features/editor/widgets/mention_suggestion_bar.dart';
import 'package:tsdm_client/features/editor/widgets/rich_editor.dart';
import 'package:tsdm_client/features/editor/widgets/toolbar.dart';
import 'package:tsdm_client/features/keyboard/widgets/keyboard_shortcuts_host.dart';
import 'package:tsdm_client/features/local_draft/models/local_draft.dart';
import 'package:tsdm_client/features/local_draft/repository/local_draft_store.dart';
import 'package:tsdm_client/features/local_draft/utils/draft_autosaver.dart';
import 'package:tsdm_client/features/local_draft/widgets/draft_offer_banner.dart';
import 'package:tsdm_client/features/multi_user/widgets/current_account_avatar.dart';
import 'package:tsdm_client/features/post/bloc/post_edit_bloc.dart';
import 'package:tsdm_client/features/post/models/models.dart';
import 'package:tsdm_client/features/post/models/poll_create.dart';
import 'package:tsdm_client/features/post/models/post_form.dart';
import 'package:tsdm_client/features/post/models/special_thread_form.dart';
import 'package:tsdm_client/features/post/repository/post_edit_repository.dart';
import 'package:tsdm_client/features/post/utils/attachment_upload.dart';
import 'package:tsdm_client/features/post/utils/discuz_text.dart';
import 'package:tsdm_client/features/post/utils/edit_attachments.dart';
import 'package:tsdm_client/features/post/utils/flood_control.dart';
import 'package:tsdm_client/features/post/utils/image_edits.dart';
import 'package:tsdm_client/features/post/utils/pasted_image.dart';
import 'package:tsdm_client/features/post/view/image_upload_edit_page.dart';
import 'package:tsdm_client/features/post/widgets/activity_dialog.dart';
import 'package:tsdm_client/features/post/widgets/cron_publish_dialog.dart';
import 'package:tsdm_client/features/post/widgets/debate_dialog.dart';
import 'package:tsdm_client/features/post/widgets/edit_attachments_button.dart';
import 'package:tsdm_client/features/post/widgets/hongbao_dialog.dart';
import 'package:tsdm_client/features/post/widgets/image_drop_area.dart';
import 'package:tsdm_client/features/post/widgets/image_upload_button.dart';
import 'package:tsdm_client/features/post/widgets/input_price_dialog.dart';
import 'package:tsdm_client/features/post/widgets/leave_edit_dialog.dart';
import 'package:tsdm_client/features/post/widgets/poll_settings_dialog.dart';
import 'package:tsdm_client/features/post/widgets/reward_price_dialog.dart';
import 'package:tsdm_client/features/post/widgets/sec_check_dialog.dart';
import 'package:tsdm_client/features/post/widgets/select_perm_dialog.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/share_receive/models/shared_content.dart';
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
    this.threadKind = ThreadKind.normal,
    this.transfer,
    this.mentionSuggestions,
    this.sharedImages,
    this.canDeleteAttachments,
    super.key,
  });

  /// The kind of new thread to write (the forum's form of that kind); only used for new threads.
  final ThreadKind threadKind;

  /// Images another app shared to this one, to upload as attachments of this new thread once its form is loaded
  /// (paths of copies in this app's cache, deleted after the upload); null or empty when none.
  final List<String>? sharedImages;

  /// The forum page offered a poll creation link to the current account; only used for new threads.
  ///
  /// The poll page still validates the forum's own form before offering any input.
  final bool pollOffered;

  /// Subject and body carried over from the poll editor.
  final ThreadModeTransfer? transfer;

  /// The authors of the thread a floor is edited from, suggested for a typed `@`; null when not opened from a thread.
  final List<MentionSuggestion>? mentionSuggestions;

  /// Whether deleting the attachments of the edited floor is offered, as the page of the floor told
  /// (`editedFloorAttachmentDeletion`); null when it did not tell: offered, the forum decides.
  final bool? canDeleteAttachments;

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

  /// The activity of a new activity thread, null until set.
  ActivityEdits? activity;

  /// The debate of a new debate thread, null until set.
  DebateEdits? debate;

  /// The poll settings of the first post of a poll edited, as served until the member changes them.
  PollEdits? poll;

  /// When the new thread is published, null for now.
  DateTime? cronPublish;

  /// The reward credits of a new reward thread, null until set; the price of an open reward thread edited, raised by
  /// the member.
  int? rewardPrice;

  /// The red packet of a new red packet thread, null until set.
  HongbaoEdits? hongbao;

  late BBCodeEditorController bbcodeController;

  bool initialized = false;
  bool _confirming = false;

  /// The shared images were taken (uploading, or done): they are uploaded once, whatever rebuilds the page.
  bool _sharedImagesTaken = false;

  /// Images going up to the forum one batch after another (shared, pasted, dropped), in the order they came.
  Future<void> _imageUploadQueue = Future<void>.value();

  /// The batches queued on [_imageUploadQueue] and not done yet.
  int _imageUploadBatches = 0;

  /// An image is on its way to the forum: nothing is sent or saved until it is there.
  bool get _uploadingImages => _imageUploadBatches > 0;

  /// What a paste takes from the clipboard instead of text.
  final _clipboardImages = ClipboardImageReader.platform();

  /// The attachments uploaded for this thread, by aid ([PostFormEdits.attachNew]).
  final _attachNew = <int>[];

  /// The context of the page's builder, under its providers (the page's own one is above them): what an image upload
  /// started outside a build (a paste, a shared image) reads the bloc and the repository from.
  BuildContext? _below;

  /// Custom emojis going up as attachments.
  int _uploadingCustomEmoji = 0;

  /// The custom emojis already attachments of this post, by SHA-256 of the image ([sendCustomEmojiAttachment]).
  final _customEmojiAids = <String, int>{};

  /// An image (shared or a custom emoji) is on its way to the forum.
  bool get _uploading => _uploadingImages || _uploadingCustomEmoji > 0;

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

  /// The kind of new thread this editor is switching to ([_switchKind]): the draft it writes last is that editor's.
  ThreadKind? _leavingFor;

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

  /// Sending failed after the request left: the local draft is marked as maybe sent.
  bool _draftMaybeSent = false;

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
        maybeSent: _draftMaybeSent,
        // Written for every new thread, `normal` too: a draft without it was written before the kinds were kept.
        threadKind: widget.editType == PostEditType.newThread ? (_leavingFor ?? widget.threadKind).name : null,
        rewardPrice: rewardPrice,
        hongbao: hongbao?.toJson(),
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
    // The editor opened with the draft restored in the editor of another kind: it is this one's.
    if (_transfer?.restoredDraft ?? false) {
      return;
    }
    await _drafts.offerStored(uid, (k) => k == key);
  }

  /// Put the offered draft into the editor: its title, its post and its thread type.
  ///
  /// The draft of an edit is put over the post as loaded now: asked first, with the time the draft was saved (the post
  /// may have been edited on the forum since).
  Future<void> _restoreDraft(BuildContext context, PostEditState state) async {
    final offered = _drafts.offer.value?.draft;
    if (offered == null) {
      return;
    }
    if (offered.key.kind == LocalDraftKind.edit) {
      final tr = context.t.localDraft;
      final ok = await showQuestionDialog(
        context: context,
        title: tr.restoreEditTitle,
        message: tr.restoreEditMessage(time: offered.updatedAt.yyyyMMDDHHMM()),
      );
      if (!(ok ?? false) || !mounted || !context.mounted) {
        return;
      }
    }
    final draft = _drafts.takeOffer();
    if (draft == null) {
      return;
    }
    // A new thread written as another kind: its editor opens with it (this one writes nothing more over it). A draft
    // written before the kinds were kept is restored here.
    final kind = ThreadKind.fromQuery(draft.threadKind);
    if (widget.editType == PostEditType.newThread &&
        draft.threadKind != null &&
        kind != widget.threadKind &&
        _kindsOffered(state).contains(kind) &&
        _draftUid != null &&
        _switchKind(
          context,
          kind,
          transfer: ThreadModeTransfer(
            uid: _draftUid!,
            fid: widget.fid,
            subject: draft.subject ?? '',
            body: draft.body,
            delta: draft.delta,
            typeId: draft.typeId,
            attachNew: List.of(_attachNew),
            rewardPrice: draft.rewardPrice ?? rewardPrice,
            hongbao: HongbaoEdits.fromJson(draft.hongbao) ?? hongbao,
            restoredDraft: true,
          ),
        )) {
      _draftStopped = true;
      return;
    }
    setState(() {
      // The settings of the kinds: the reward price of an edit only where the member may raise it.
      if (widget.editType == PostEditType.newThread) {
        rewardPrice = draft.rewardPrice ?? rewardPrice;
      } else if ((state.content?.form?.reward, draft.rewardPrice) case (
        final info?,
        final int kept,
      ) when info.raising) {
        // Never below the price now: it may have been raised since the draft was kept.
        rewardPrice = kept > info.current! ? kept : info.current;
      }
      if (widget.editType == PostEditType.newThread) {
        hongbao = HongbaoEdits.fromJson(draft.hongbao) ?? hongbao;
      }
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

  /// Whether the poll settings were changed in their dialog: not kept in the local draft, they are lost when leaving.
  bool get _pollChanged => poll != null && poll != context.read<PostEditBloc>().state.content?.form?.pollEdit?.served;

  /// Leave the page (the back button or gesture): with content not sent yet ([_hasUnsentContent], [_pollChanged])
  /// while it is being edited, ask first whether to discard it, save it as a draft (when the form allows it) or keep
  /// editing. Used to drop the content right away.
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
    if (!editing || !(_hasUnsentContent || _pollChanged)) {
      context.pop();
      return;
    }
    // Not offered while shared images are still going up: saving would be refused without a word (see _onFinish).
    final canSaveDraft =
        widget.editType.isEditingDraft && (bloc.state.content?.canSaveDraft ?? false) && bloc.canSubmit && !_uploading;
    _leaving = true;
    final LeaveEditChoice choice;
    try {
      choice = await showLeaveEditDialog(
        context,
        canSaveDraft: canSaveDraft,
        // Only the title and the post are kept on this device: nothing to keep when only the poll settings changed.
        keepsLocalDraft:
            _hasUnsentContent &&
            _draftKey != null &&
            _draftUid != null &&
            !_draftStopped &&
            LocalDraftStore.app != null,
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

  /// Upload the images another app shared ([PostEditPage.sharedImages]) as attachments of this thread
  /// ([_queueImageUpload]). The shared files are deleted either way.
  void _uploadSharedImages(List<String> paths) => _queueImageUpload(
    (_) async => (files: [for (final path in paths) UploadImageFile(path, temporary: true)], refused: const <String>[]),
    discard: paths,
  );

  /// A paste in the editor ([buildPasteAwareEditorController]): images on the clipboard without text
  /// ([ClipboardImageReader]) are uploaded and shown at the cursor instead ([_queueImageUpload]); anything else is
  /// pasted by the editor as before.
  Future<bool> _onClipboardPaste() async {
    if (!mounted || !initialized) return false;
    final images = await _clipboardImages.read();
    if (images == null || !mounted) return false;
    _uploadClipboardImages(images);
    return true;
  }

  /// Upload what [images] took from the clipboard: the copied files as [_uploadImageFiles], a picture written to a
  /// temporary file ([writeUploadImage]); through the image editor when [edit] (null: as the settings say).
  void _uploadClipboardImages(ClipboardImages images, {bool? edit}) {
    switch (images) {
      case ClipboardImagePaths(:final paths):
        _uploadImageFiles(paths, edit: edit);
      case ClipboardImageBytes(:final bytes):
        _queueImageUpload(edit: edit, (upload) async {
          final stem = 'paste_${DateTime.now().millisecondsSinceEpoch}';
          UploadImageFile? file;
          try {
            file = await writeUploadImage(bytes, dir: await _uploadTempDir(), stem: stem, accepts: upload.acceptsImage);
          } on Object catch (e, st) {
            handleRaw(e, st);
          }
          // Told as the file it would have been.
          return (files: [?file], refused: [if (file == null) '$stem.${sniffImageExtension(bytes) ?? 'bin'}']);
        });
    }
  }

  /// Images to upload from [source] (the image button), through the image editor when [edit].
  Future<void> _pickImages(ImageUploadSource source, {required bool edit}) async {
    try {
      await _pickImagesFrom(source, edit: edit);
    } on Object catch (e, st) {
      // A picker refused (no camera permission) or failed: nothing picked.
      handleRaw(e, st);
    }
  }

  Future<void> _pickImagesFrom(ImageUploadSource source, {required bool edit}) async {
    switch (source) {
      case ImageUploadSource.gallery:
        final picked = await FilePicker.platform.pickFiles(type: FileType.image, allowMultiple: true);
        final paths = picked?.files.map((e) => e.path).nonNulls.toList() ?? const <String>[];
        if (paths.isNotEmpty && mounted) _uploadImageFiles(paths, edit: edit);
      case ImageUploadSource.camera:
        final photo = await ImagePicker().pickImage(source: ImageSource.camera);
        // The photo is a copy the picker wrote for the app: gone once it went up.
        if (photo != null && mounted) _uploadImageFiles([photo.path], edit: edit, temporary: true);
      case ImageUploadSource.clipboard:
        // Asked for: text beside the picture does not keep it.
        final images = await _clipboardImages.read(textWins: false);
        if (!mounted) return;
        if (images == null) {
          showSnackBar(context: context, message: context.t.imageUpload.noClipboardImage);
        } else {
          _uploadClipboardImages(images, edit: edit);
        }
    }
  }

  /// Upload the image files at [paths] (dropped, copied in the file manager, picked), each as it is when the forum
  /// takes its type, else as a PNG copy ([prepareImageFile]); through the image editor when [edit] (null: as the
  /// settings say). The member's files are kept, [temporary] ones deleted.
  void _uploadImageFiles(List<String> paths, {bool? edit, bool temporary = false}) =>
      _queueImageUpload(edit: edit, discard: temporary ? paths : const [], (upload) async {
        final dir = await _uploadTempDir();
        final stamp = DateTime.now().millisecondsSinceEpoch;
        final files = <UploadImageFile>[];
        final refused = <String>[];
        for (final (i, path) in paths.indexed) {
          UploadImageFile? file;
          try {
            file = await prepareImageFile(path, dir: dir, stem: 'image_${stamp}_$i', accepts: upload.acceptsImage);
          } on Object catch (e, st) {
            // A copy that could not be written: this one is refused, the copies written before still go up and away.
            handleRaw(e, st);
          }
          if (file != null) {
            files.add(file);
          } else {
            refused.add(path.split(RegExp(r'[/\\]')).last);
          }
        }
        return (files: files, refused: refused);
      });

  /// Where the images written for an upload go until they went up.
  static Future<Directory> _uploadTempDir() async =>
      Directory('${(await getTemporaryDirectory()).path}${Platform.pathSeparator}image_upload');

  /// Upload a batch of images as attachments of this post, after the batches before it: [prepare] gets the upload
  /// of the form and returns the files to send (writing the temporary ones) and the names of those the forum takes
  /// in no form. Each image is shown in the post at the cursor as the website's image list inserts it
  /// (`[attachimg]aid[/attachimg]`) and bound to the post when it is published or the edit saved
  /// ([PostFormEdits.attachNew]); the temporary files are deleted once tried.
  ///
  /// Only the form of the forum's app API offers the upload ([PostForm.attachmentUpload]); a page without it, or a
  /// forum where the account may not upload images, is told so and [discard] (temporary files already written) are
  /// deleted.
  ///
  /// With [edit] (null: as the settings say, [SettingsMap.editImageBeforeUpload]) each image opens the image editor
  /// first ([ImageUploadEditPage]); leaving it uploads nothing of that image. Otherwise an image larger than the
  /// size set ([SettingsMap.uploadImageMaxSide]) is scaled down ([writeEditedImage]).
  void _queueImageUpload(
    Future<({List<UploadImageFile> files, List<String> refused})> Function(AttachmentUpload upload) prepare, {
    List<String> discard = const [],
    bool? edit,
  }) {
    setState(() => _imageUploadBatches++);
    _imageUploadQueue = _imageUploadQueue.then((_) async {
      try {
        await _runImageUpload(prepare, discard, edit: edit);
      } on Object catch (e, st) {
        handleRaw(e, st);
        discardSharedFiles(discard);
      } finally {
        _imageUploadBatches--;
        if (mounted) setState(() {});
      }
    });
  }

  Future<void> _runImageUpload(
    Future<({List<UploadImageFile> files, List<String> refused})> Function(AttachmentUpload upload) prepare,
    List<String> discard, {
    required bool? edit,
  }) async {
    final below = _below;
    if (!mounted || below == null || !below.mounted) {
      discardSharedFiles(discard);
      return;
    }
    final tr = context.t.shareReceive;
    final state = below.read<PostEditBloc>().state;
    if (state.status == PostEditStatus.uploading || state.status == PostEditStatus.success) {
      // The post is on its way or gone: an image now would be bound to nothing.
      discardSharedFiles(discard);
      return;
    }
    final upload = state.content?.form?.attachmentUpload;
    if (upload == null || !upload.image) {
      discardSharedFiles(discard);
      showSnackBar(context: context, message: tr.uploadUnavailable);
      return;
    }
    final repo = below.read<PostEditRepository>();
    // Read before the files are written: once they are, only the try below deletes them.
    final settings = context.read<SettingsBloc>().state.settingsMap;
    final (:files, :refused) = await prepare(upload);
    // What went wrong, told once at the end: one failure with its reason, several as their count.
    final failures = [for (final name in refused) tr.uploadRefusedType(name: name)];
    final edits = edit ?? settings.editImageBeforeUpload;
    // The edited copies, deleted with the other temporary files.
    final written = <String>[];
    try {
      for (final picked in files) {
        if (!mounted || !repo.isCurrent) {
          break;
        }
        final file = await _editedForUpload(picked, upload, settings, edit: edits);
        if (file == null || !mounted || !repo.isCurrent) {
          continue;
        }
        if (file != picked) written.add(file.path);
        final result = await repo.uploadImage(upload, file.path).run();
        if (!mounted) {
          break;
        }
        result.match(
          (e) {
            handle(e);
            final name = file.path.split(RegExp(r'[/\\]')).last;
            failures.add(switch (e) {
              AttachmentUploadFailedException(reason: AttachmentUploadRefusal.type) => tr.uploadRefusedType(name: name),
              AttachmentUploadFailedException(reason: AttachmentUploadRefusal.size) => tr.uploadRefusedSize(
                name: name,
                limit: upload.maxKb ?? 0,
              ),
              AttachmentUploadFailedException(:final code?) => tr.uploadFailed(code: '$code'),
              _ => tr.uploadFailed(code: ''),
            });
          },
          (aid) {
            _attachNew.add(aid);
            bbcodeController.insertTextAtCursor('${attachmentImageBBCode(aid)}\n');
          },
        );
      }
    } finally {
      discardSharedFiles({
        ...discard,
        ...written,
        for (final file in files)
          if (file.temporary) file.path,
      });
      if (mounted) {
        if (failures.length == 1) {
          showSnackBar(context: context, message: failures.single);
        } else if (failures.length > 1) {
          showSnackBar(
            context: context,
            message: tr.uploadFailedCount(count: failures.length),
          );
        }
      }
    }
  }

  /// Whether the custom emoji packs are offered: the form of the forum's app API lets the member upload images here.
  bool _offersCustomEmoji(PostEditState state) => state.content?.form?.attachmentUpload?.image ?? false;

  /// Put the custom emoji [emoji] into the post as an attachment ([CustomEmojiSender]): the code of the attachment
  /// it already is in this post, of the account's unused upload of the image the form lists (bound to the post when
  /// it is published), else of a new upload, remembered for the account ([CustomEmojiStore.rememberUpload]). Null
  /// when it cannot go up (told why). [below] is a context under the page's providers.
  Future<String?> _sendCustomEmoji(BuildContext below, CustomEmoji emoji) async {
    final form = below.read<PostEditBloc>().state.content?.form;
    setState(() => _uploadingCustomEmoji++);
    try {
      return await sendCustomEmojiAttachment(
        context,
        emoji: emoji,
        repo: below.read<PostEditRepository>(),
        upload: form?.attachmentUpload,
        unused: form?.unusedAttachmentImages ?? const {},
        used: form?.usedAttachments ?? const {},
        inPost: _customEmojiAids,
        bind: (aid) {
          if (!_attachNew.contains(aid)) _attachNew.add(aid);
        },
        stillHere: () => mounted,
      );
    } finally {
      if (mounted) setState(() => _uploadingCustomEmoji--);
    }
  }

  /// [file] as it goes up: edited in the image editor when [edit] (null when the editor was left: not uploaded),
  /// else scaled down to the size of [settings]; [file] itself when nothing changes or it can not be edited.
  Future<UploadImageFile?> _editedForUpload(
    UploadImageFile file,
    AttachmentUpload upload,
    SettingsMap settings, {
    required bool edit,
  }) async {
    var edits = ImageEdits(maxSide: settings.uploadImageMaxSide, quality: settings.uploadImageQuality);
    Uint8List? bytes;
    if (edit) {
      try {
        bytes = await File(file.path).readAsBytes();
      } on Object {
        return file;
      }
      if (!isEditableImage(bytes) || !mounted) return file;
      final chosen = await ImageUploadEditPage.show(context, bytes, maxSide: edits.maxSide, quality: edits.quality);
      if (chosen == null) return null;
      edits = chosen;
    }
    try {
      return await writeEditedImage(
        file,
        edits,
        dir: await _uploadTempDir(),
        stem: 'edited_${DateTime.now().microsecondsSinceEpoch}',
        accepts: upload.acceptsImage,
        bytes: bytes,
      );
    } on Object catch (e, st) {
      handleRaw(e, st);
      return file;
    }
  }

  /// Continue this new thread or this edit on the website.
  Future<void> _openBrowser(BuildContext context) async {
    final url = widget.editType == PostEditType.newThread
        ? PostEditRepository.newThreadPageUrl(widget.fid, kind: widget.threadKind)
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
    // Shared images still going up: sent now, the post would miss them and the rest would be uploaded for nothing.
    if (_uploading) return;
    if (saveDraft && !state.content!.canSaveDraft) return;
    if (_waitingSeconds > 0) return;
    final issue = _formIssue(context, state.content!);
    if (issue != null) {
      showSnackBar(context: context, message: issue);
      return;
    }
    // A reward thread needs its price (an edit only a price the forum takes: raised, within the group's range, paid).
    if (state.content!.form?.reward case final info? when info.editable) {
      if (info.check(rewardPrice) case final problem?) {
        showSnackBar(
          context: context,
          message: rewardPrice == null
              ? context.t.postEditPage.rewardDialog.required
              : rewardIssueText(context, info, problem),
        );
        return;
      }
    }
    // An activity needs its time, category and place, a debate its two points (an edit too: the forum checks them
    // again), a red packet thread its packet: the forum refuses the post without them.
    final form = state.content!.form;
    if (form?.activity case final info?) {
      final set = activity;
      final problem = set?.check(info);
      if (set == null || problem != null) {
        showSnackBar(
          context: context,
          message: set == null
              ? context.t.postEditPage.activityDialog.required
              : activityIssueText(context, info, problem!),
        );
        return;
      }
    }
    if (form?.debate != null) {
      final set = debate;
      final problem = set?.check(DateTime.now());
      if (set == null || problem != null) {
        showSnackBar(
          context: context,
          message: switch (problem) {
            _ when set == null => context.t.postEditPage.debateDialog.required,
            // The debate edited has ended (its end as it is): posted with it, the forum refuses the whole edit.
            DebateIssue.endPassed
                when widget.editType == PostEditType.editPost && set.end == form?.debate?.served?.end =>
              context.t.postEditPage.debateDialog.ended,
            _ => debateIssueText(context, problem!),
          },
        );
        return;
      }
    }
    if ((form?.pollEdit, poll) case (final info?, final set?)) {
      if (set.check(info) case final problem?) {
        showSnackBar(context: context, message: pollEditIssueText(context, info, problem));
        return;
      }
    }
    if (widget.editType == PostEditType.newThread) {
      // A time passed meanwhile would publish the thread now.
      if (cronPublish case final at? when !saveDraft && (form?.offersCronPublish ?? false)) {
        if (!cronPublishAhead(at, DateTime.now())) {
          showSnackBar(context: context, message: context.t.postEditPage.cronPublish.passed);
          return;
        }
      }
      // A draft is saved without the packet (PostForm.bodyWith): nothing to check for it.
      if (form?.hongbao case final info? when !saveDraft) {
        final packet = hongbao;
        if (packet == null) {
          showSnackBar(context: context, message: context.t.postEditPage.hongbaoDialog.required);
          return;
        }
        if (packet.check(info) case final problem?) {
          showSnackBar(context: context, message: hongbaoIssueText(context, info, packet, problem));
          return;
        }
      }
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
          attachNew: attachmentsInMessage(bbcodeController.toForumBBCode(), _attachNew),
          rewardPrice: (state.content!.form?.reward?.editable ?? false) ? rewardPrice : null,
          activity: state.content!.form?.activity == null ? null : activity,
          debate: state.content!.form?.debate == null ? null : debate,
          poll: state.content!.form?.pollEdit == null ? null : poll,
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
          // Only the uploads the post still shows; one the member deleted from it is left unused.
          attachNew: attachmentsInMessage(bbcodeController.toForumBBCode(), _attachNew),
          rewardPrice: state.content!.form?.reward == null ? null : rewardPrice,
          hongbao: state.content!.form?.hongbao == null ? null : hongbao,
          activity: state.content!.form?.activity == null ? null : activity,
          debate: state.content!.form?.debate == null ? null : debate,
          // A draft saved is no publication: not scheduled.
          cronPublish: (state.content!.form?.offersCronPublish ?? false) && !saveDraft ? cronPublish : null,
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
        browserUrl: PostEditRepository.newThreadPageUrl(widget.fid, kind: widget.threadKind),
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
              sendCustomEmoji: _offersCustomEmoji(state) ? (emoji) => _sendCustomEmoji(context, emoji) : null,
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
        if (state.content?.form?.attachmentUpload?.image ?? false)
          ImageUploadButton(
            editsByDefault: context.read<SettingsBloc>().state.settingsMap.editImageBeforeUpload,
            onPicked: (source, {required edit}) async => _pickImages(source, edit: edit),
          ),
        // The attachments of the edited post, as the website's edit page lists them, to delete.
        if ((state.content, editAttachmentsOf(state.content?.postForm), context.read<PostEditBloc>()) case (
          PostEditContent(:final tid?, :final pid?, :final formHash, :final form?),
          final attachments,
          final bloc,
        ) when attachments.isNotEmpty && widget.editType != PostEditType.newThread)
          EditAttachmentsButton(
            attachments: attachments,
            tid: tid,
            pid: pid,
            formHash: formHash,
            formUid: form.uid,
            canDelete: widget.canDeleteAttachments ?? true,
            // The answer may come once the editor is gone: nothing to tell then.
            onDeleted: (aid) {
              if (!bloc.isClosed) bloc.add(PostEditAttachmentDeleted(aid));
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
                final inputPrice = await showInputPriceDialog(context, price, state.content?.maxPrice);
                if (inputPrice != null) {
                  setState(() {
                    price = inputPrice;
                  });
                }
              },
            ),
          ),
        if (state.content?.form?.reward case final info? when info.editable)
          Badge(
            label: Text('${rewardPrice ?? ''}'),
            textStyle: Theme.of(context).textTheme.labelSmall,
            offset: const Offset(-4, 4),
            isLabelVisible: rewardPrice != null,
            child: IconButton(
              icon: const Icon(Icons.emoji_events_outlined),
              selectedIcon: const Icon(Icons.emoji_events),
              isSelected: rewardPrice != null,
              tooltip: context.t.postEditPage.rewardDialog.entryTooltip,
              onPressed: () async {
                final set = await showRewardPriceDialog(context, info, rewardPrice);
                if (set != null && mounted) {
                  setState(() => rewardPrice = set);
                  _drafts.changed();
                }
              },
            ),
          ),
        if (state.content?.form?.hongbao case final info?)
          Badge(
            label: Text('${hongbao?.total ?? ''}'),
            textStyle: Theme.of(context).textTheme.labelSmall,
            offset: const Offset(-4, 4),
            isLabelVisible: hongbao?.total != null,
            child: IconButton(
              icon: const Icon(Icons.card_giftcard_outlined),
              selectedIcon: const Icon(Icons.card_giftcard),
              isSelected: hongbao != null,
              tooltip: context.t.postEditPage.hongbaoDialog.entryTooltip,
              onPressed: () async {
                final set = await showHongbaoDialog(context, info, hongbao);
                if (set != null && mounted) {
                  setState(() => hongbao = set);
                  _drafts.changed();
                }
              },
            ),
          ),
        if (state.content?.form?.activity case final info?)
          IconButton(
            icon: const Icon(Icons.event_outlined),
            selectedIcon: const Icon(Icons.event),
            isSelected: activity != null,
            tooltip: context.t.postEditPage.activityDialog.entryTooltip,
            onPressed: () async {
              final set = await showActivityDialog(context, info, activity);
              if (set != null && mounted) {
                setState(() => activity = set);
              }
            },
          ),
        if ((state.content?.form?.pollEdit, poll) case (final info?, final set?))
          IconButton(
            icon: const Icon(Icons.poll_outlined),
            selectedIcon: const Icon(Icons.poll),
            isSelected: set != info.served,
            tooltip: context.t.postEditPage.pollDialog.entryTooltip,
            onPressed: () async {
              final changed = await showPollSettingsDialog(context, info, set);
              if (changed != null && mounted) {
                setState(() => poll = changed);
              }
            },
          ),
        if (state.content?.form case final form?
            when widget.editType == PostEditType.newThread && form.offersCronPublish)
          IconButton(
            icon: const Icon(Icons.schedule_outlined),
            selectedIcon: const Icon(Icons.schedule),
            isSelected: cronPublish != null,
            tooltip: context.t.postEditPage.cronPublish.entryTooltip,
            onPressed: () async {
              final set = await showCronPublishDialog(context, cronPublish);
              if (set != null && mounted) {
                setState(() => cronPublish = set.at);
              }
            },
          ),
        if (state.content?.form?.debate case final info?)
          IconButton(
            icon: const Icon(Icons.balance_outlined),
            selectedIcon: const Icon(Icons.balance),
            isSelected: debate != null,
            tooltip: context.t.postEditPage.debateDialog.entryTooltip,
            onPressed: () async {
              final set = await showDebateDialog(context, info, debate);
              if (set != null && mounted) {
                setState(() => debate = set);
              }
            },
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
            context.read<PostEditBloc>().add(ThreadPubFetchInfoRequested(fid: widget.fid, kind: widget.threadKind));
        }
      }, message: state.errorText);
    }

    if (!initialized) {
      final data = _transfer?.body ?? state.content?.data;
      if (_transfer case ThreadModeTransfer(:final body, :final String delta)) {
        // The thread editor's own document: what BBCode does not carry comes back as well.
        bbcodeController.loadDraft(
          body,
          delta: delta,
          parse: context.read<SettingsBloc>().state.settingsMap.enableEditorBBCodeParser,
        );
      } else if (data != null) {
        if (context.read<SettingsBloc>().state.settingsMap.enableEditorBBCodeParser) {
          final delta = parseBBCodeTextToDelta(normalizeBlockMarkerNesting(data));
          bbcodeController.setDocumentFromDelta(delta);
        } else {
          bbcodeController.setDocumentFromRawText(normalizeBlockMarkerNesting(data));
        }
      }
      _loadedBody = bbcodeController.toForumBBCode();
      initialized = true;
      final shared = widget.sharedImages;
      if (!_sharedImagesTaken && shared != null && shared.isNotEmpty && widget.editType == PostEditType.newThread) {
        _sharedImagesTaken = true;
        WidgetsBinding.instance.addPostFrameCallback((_) => _uploadSharedImages(shared));
      }
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
                        onRestore: () async => _restoreDraft(context, state),
                        onDiscard: _drafts.discardOffer,
                      ),
                    ),
            ),
            if (_uploading) const LinearProgressIndicator(minHeight: 2),
            Padding(padding: horizontal.add(edgeInsetsT12), child: _buildTitleRow(context, state)),
            // Post data editor.
            // Now we don't restrict the thread type and thread title, so it's better to focus on content area.
            Expanded(
              child: Padding(
                padding: horizontal.add(const EdgeInsets.symmetric(vertical: 12)),
                child: ImageDropArea(
                  onImages: initialized ? _uploadImageFiles : null,
                  child: EditorFrame(
                    focusNode: focusNode,
                    child: MentionSuggestionsScope(
                      suggestions: widget.mentionSuggestions ?? const [],
                      child: RichEditor(autoFocus: true, controller: bbcodeController, editorFocusNode: focusNode),
                    ),
                  ),
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
                    sendCustomEmoji: _offersCustomEmoji(state) ? (emoji) => _sendCustomEmoji(context, emoji) : null,
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
    final shared = widget.sharedImages;
    if (!_sharedImagesTaken &&
        shared != null &&
        shared.isNotEmpty &&
        (state.status == PostEditStatus.unsupported || state.status == PostEditStatus.verificationRequired)) {
      // The editor never opens here: the shared images cannot be uploaded; the text stays to copy.
      _sharedImagesTaken = true;
      discardSharedFiles(shared);
      showSnackBar(context: context, message: context.t.shareReceive.uploadUnavailable);
    }
    if (state.status == PostEditStatus.identityChanged) {
      // What was written stays the draft of the account it was written for; nothing goes to the next one.
      _stopDraft(delete: false);
      _transfer = null;
      _attachNew.clear();
      _customEmojiAids.clear();
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
      if (state.maybeSent) {
        _draftMaybeSent = true;
        _drafts.flush();
      }
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
        // Also when other plugins' fields of the form (not shown here) are what the forum asks for.
        action: state.offersBrowser
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
    } else if (state.status == PostEditStatus.scheduled) {
      _stopDraft(delete: true);
      // Kept a draft until its time: no thread to go to yet, the drafts tell when. The time shown is the device's
      // clock of the instant posted (the forum got its own wall clock of it, PostForm.cronPublishDate); the field is
      // not changed while posting (the editor is locked).
      final tr = context.t.postEditPage.cronPublish;
      final view = await showQuestionDialog(
        context: context,
        title: tr.scheduled,
        message: tr.scheduledMessage(time: cronPublish == null ? '' : discuzDateTime(cronPublish!)),
      );
      if (!context.mounted || !context.read<PostEditRepository>().isCurrent) return;
      if (view ?? false) {
        context.pushReplacementNamed(ScreenPaths.myThread, queryParameters: {'tab': 'drafts'});
      } else {
        context.pop(true);
      }
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
      if (state.notice case final notice?) {
        // Taken as far as the forum tells, then the plugin's notice (the red packet was not made): told, back to the
        // forum; the local draft stays, marked as maybe sent, until the member has seen the thread.
        _draftMaybeSent = true;
        _stopDraft(delete: false);
        final tr = context.t.postEditPage.postedWithNotice;
        await showMessageSingleButtonDialog(
          context: context,
          title: tr.title,
          message: tr.message(notice: notice),
        );
        if (context.mounted && context.read<PostEditRepository>().isCurrent) context.pop(true);
        return;
      }
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
        // The thread type chosen in the editor switched from, when this form offers it.
        if (_transfer?.typeId case final String id) {
          threadType ??= state.content?.threadTypeList?.firstWhereOrNull((e) => e.typeID == id);
        }
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
        // The first post of an open reward thread: its price, which the member may raise.
        if (state.content?.form?.reward case final info? when info.raising) {
          rewardPrice = info.current;
        }
        // The first post of an activity or a debate thread: the activity or the debate as it is.
        if (widget.editType != PostEditType.newThread) {
          activity = state.content?.form?.activity?.served;
          debate = state.content?.form?.debate?.served;
          poll = state.content?.form?.pollEdit?.served;
        }
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
    // A pasted image goes up as an attachment.
    bbcodeController = buildPasteAwareEditorController(onPaste: _onClipboardPaste);
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
      // The attachments uploaded in the editor switched from stay bound to the post.
      _attachNew.addAll(transfer.attachNew);
      // The settings of the kinds the member set, posted only on the form of their kind (PostForm.bodyWith).
      rewardPrice = transfer.rewardPrice;
      hongbao = transfer.hongbao;
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
              rewardPrice: rewardPrice,
              hongbao: hongbao,
              typeId: threadType?.typeID,
            ),
    );
  }

  /// The kinds of new thread the loaded form offers (`special.allowed`, the thread plugins): the ordinary thread, a
  /// reward when the member may post one, a red packet when the forum has the plugin; only the kind of the page
  /// when the form does not tell (the web page).
  List<ThreadKind> _kindsOffered(PostEditState state) {
    final form = state.content?.form;
    if (form == null) {
      return [widget.threadKind];
    }
    final allowed = form.specialAllowed;
    return [
      if (allowed.contains(0) || widget.threadKind == ThreadKind.normal) ThreadKind.normal,
      if (allowed.contains(3) || widget.threadKind == ThreadKind.reward) ThreadKind.reward,
      if (allowed.contains(4) || widget.threadKind == ThreadKind.activity) ThreadKind.activity,
      if (allowed.contains(5) || widget.threadKind == ThreadKind.debate) ThreadKind.debate,
      if (form.threadPlugins.any((e) => e.$1 == ThreadKind.hongbaoPlugin) || widget.threadKind == ThreadKind.hongbao)
        ThreadKind.hongbao,
    ];
  }

  static IconData _kindIcon(ThreadKind kind) => switch (kind) {
    ThreadKind.normal => Icons.article_outlined,
    ThreadKind.reward => Icons.emoji_events_outlined,
    ThreadKind.hongbao => Icons.card_giftcard_outlined,
    ThreadKind.activity => Icons.event_outlined,
    ThreadKind.debate => Icons.balance_outlined,
  };

  static String _kindLabel(BuildContext context, ThreadKind kind) {
    final tr = context.t.postEditPage.threadKind;
    return switch (kind) {
      ThreadKind.normal => tr.normal,
      ThreadKind.reward => tr.reward,
      ThreadKind.hongbao => tr.hongbao,
      ThreadKind.activity => tr.activity,
      ThreadKind.debate => tr.debate,
    };
  }

  /// Intentional kind switch: subject and body go to the editor of [kind], which fetches the forum's form of that
  /// kind; nothing is posted. The reward price and the red packet set go along: posted on the form of their kind only,
  /// set again when the member is back there. [transfer] instead of what this editor holds (a restored local draft).
  ///
  /// Whether the editor of [kind] was opened.
  bool _switchKind(BuildContext context, ThreadKind kind, {ThreadModeTransfer? transfer}) {
    if (kind == widget.threadKind ||
        !mounted ||
        ModalRoute.of(context)?.isActive == false ||
        !context.read<PostEditRepository>().isCurrent) {
      return false;
    }
    final uid = context.read<AuthenticationRepository>().effectiveCurrentUid;
    _leavingFor = kind;
    context.pushReplacementNamed(
      ScreenPaths.editPost,
      pathParameters: {'editType': '${PostEditType.newThread.index}', 'fid': widget.fid},
      queryParameters: {if (widget.pollOffered) 'poll': '1', 'kind': ?kind.query},
      extra: uid == null || !initialized
          ? null
          : transfer ??
                ThreadModeTransfer(
                  uid: uid,
                  fid: widget.fid,
                  subject: threadTitleController.text,
                  body: bbcodeController.toForumBBCode(),
                  attachNew: List.of(_attachNew),
                  rewardPrice: rewardPrice,
                  hongbao: hongbao,
                  delta: bbcodeController.toQuillDelta(),
                  typeId: threadType?.typeID,
                ),
    );
    return true;
  }

  @override
  void dispose() {
    _countdown?.cancel();
    // Shared images never uploaded (the page was left before its form came): their copies go.
    if (!_sharedImagesTaken && widget.sharedImages != null) {
      discardSharedFiles(widget.sharedImages!);
    }
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
              PostEditType.newThread => ThreadPubFetchInfoRequested(fid: widget.fid, kind: widget.threadKind),
            };
            bloc.add(event);
            return bloc;
          },
        ),
      ],
      child: BlocConsumer<PostEditBloc, PostEditState>(
        listener: (context, state) async => _onListen(context, state),
        builder: (context, state) {
          _below = context;
          bool canPublish() =>
              !(_confirming || _uploading || _waitingSeconds > 0 || !context.read<PostEditBloc>().canSubmit);
          // Below the bloc: leaving asks what to do with content not sent yet, and may save it as a draft.
          return PopScope(
            canPop: false,
            onPopInvokedWithResult: (didPop, _) async {
              if (didPop) {
                return;
              }
              await _onLeave(context);
            },
            child: _wrapWithSendShortcut(
              onSend: () {
                if (canPublish()) {
                  unawaited(_onFinish(context, state));
                }
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
                        state.status == PostEditStatus.editing &&
                        _kindsOffered(state).length > 1)
                      PopupMenuButton<ThreadKind>(
                        tooltip: context.t.postEditPage.threadKind.tooltip,
                        icon: Icon(_kindIcon(widget.threadKind)),
                        enabled: !_confirming,
                        onSelected: (kind) => _switchKind(context, kind),
                        itemBuilder: (context) => [
                          for (final kind in _kindsOffered(state))
                            CheckedPopupMenuItem(
                              value: kind,
                              checked: kind == widget.threadKind,
                              child: Text(_kindLabel(context, kind)),
                            ),
                        ],
                      ),
                    if (widget.editType == PostEditType.newThread &&
                        widget.pollOffered &&
                        state.status != PostEditStatus.uploading &&
                        state.status != PostEditStatus.success &&
                        state.status != PostEditStatus.draftUnconfirmed &&
                        state.status != PostEditStatus.stillDraft &&
                        state.status != PostEditStatus.scheduled &&
                        state.status != PostEditStatus.identityChanged)
                      IconButton(
                        tooltip: context.t.pollCreate.switchToPoll,
                        icon: const Icon(Icons.poll_outlined),
                        onPressed: _confirming ? null : () => _switchToPoll(context),
                      ),
                    if (widget.editType.isEditingDraft && (state.content?.canSaveDraft ?? false)) ...[
                      IconButton(
                        onPressed:
                            _confirming || _uploading || _waitingSeconds > 0 || !context.read<PostEditBloc>().canSubmit
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
                      onPressed: canPublish() ? () async => _onFinish(context, state) : null,
                    ),
                  ],
                ),
                body: SafeArea(bottom: false, child: _buildBody(context, state)),
              ),
            ),
          );
        },
      ),
    );
  }

  /// Ctrl+Enter (Cmd+Enter) publishes while the title or the editor has the focus; desktop only, as on mobile the input
  /// method owns the Enter key.
  Widget _wrapWithSendShortcut({required VoidCallback onSend, required Widget child}) {
    if (!keyboardShortcutsEnabled) {
      return child;
    }
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, control: true): onSend,
        const SingleActivator(LogicalKeyboardKey.numpadEnter, control: true): onSend,
        const SingleActivator(LogicalKeyboardKey.enter, meta: true): onSend,
        const SingleActivator(LogicalKeyboardKey.numpadEnter, meta: true): onSend,
      },
      child: child,
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
