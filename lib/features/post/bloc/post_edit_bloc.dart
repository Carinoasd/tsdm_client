import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/fp.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/local_draft/models/local_draft.dart';
import 'package:tsdm_client/features/local_draft/repository/local_draft_store.dart';
import 'package:tsdm_client/features/post/models/models.dart';
import 'package:tsdm_client/features/post/models/post_form.dart';
import 'package:tsdm_client/features/post/repository/post_edit_repository.dart';
import 'package:tsdm_client/features/post/repository/sec_check_repository.dart';
import 'package:tsdm_client/features/post/utils/flood_control.dart';
import 'package:tsdm_client/features/post/utils/verification.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/utils/logger.dart';

part 'post_edit_bloc.mapper.dart';

part 'post_edit_event.dart';

part 'post_edit_state.dart';

/// Emitter for post edit.
typedef _Emit = Emitter<PostEditState>;

/// Bloc of editing a post.
final class PostEditBloc extends Bloc<PostEditEvent, PostEditState> with LoggerMixin {
  /// Constructor.
  PostEditBloc({required PostEditRepository postEditRepository, Stream<AuthStatus>? authenticationChanges})
    : _repo = postEditRepository,
      super(const PostEditState()) {
    on<PostEditLoadDataRequested>(_onPostEditLoadDataRequested);
    on<PostEditCompleteEditRequested>(_sending(_onPostEditCompleteEditRequested));
    on<ThreadPubFetchInfoRequested>((event, emit) => _onFetchNewThreadInfo(event.fid, emit));
    on<ThreadPubPostThread>(_sending(_onPostNewThread));
    on<PostEditIdentityChanged>((event, emit) => emit(const PostEditState(status: PostEditStatus.identityChanged)));
    _authenticationSubscription = authenticationChanges?.listen((status) {
      if (status is AuthStatusAuthed && _repo.belongsTo(status.userInfo.uid)) return;
      if ((status is AuthStatusLoading || status is AuthStatusUnknown) && _repo.isCurrent) return;
      _repo.invalidate();
      add(const PostEditIdentityChanged());
    });
  }

  static final _tidRe = RegExp(r'tid=(?<tid>\d+)');

  final PostEditRepository _repo;
  StreamSubscription<AuthStatus>? _authenticationSubscription;
  bool _submitting = false;

  /// The loaded form can only be used by its original account.
  bool get canSubmit =>
      _repo.isCurrent &&
      !_submitting &&
      state.content != null &&
      (state.status == PostEditStatus.editing || state.status == PostEditStatus.failedToUpload);

  @override
  Future<void> close() async {
    await _authenticationSubscription?.cancel();
    return super.close();
  }

  bool _active(_Emit emit) {
    if (emit.isDone) return false;
    if (_repo.isCurrent) return true;
    emit(const PostEditState(status: PostEditStatus.identityChanged));
    return false;
  }

  Future<void> _onPostEditLoadDataRequested(PostEditLoadDataRequested event, _Emit emit) async {
    if (!_active(emit) || _submitting) return;
    emit(state.copyWith(status: PostEditStatus.loading));
    final answer = await _repo.fetchForm(event.editUrl).run();
    if (!_active(emit)) return;
    _onFormLoaded(answer, emit, action: 'edit');
  }

  /// Take the post form [answer] of an edit or a new thread ([action] `edit` or `newthread`) into the editor.
  ///
  /// The web page is read as it always was ([PostEditContent.supportsDocument], [PostEditContent.fromDocument]), the
  /// post form of the forum's app API (plugin 2.9.0) from its fields ([PostForm.editorSupport],
  /// [PostEditContent.fromPostForm]); the forum's message instead of the form is a failure with its text. Either way
  /// a form asking for a captcha or a security question is edited here when it tells their ids
  /// ([PostEditContent.secCheck]: the page asks the user before sending), else it goes to the website before anything
  /// is typed ([PostEditStatus.verificationRequired]).
  void _onFormLoaded(Either<AppException, PostEditFormAnswer> answer, _Emit emit, {required String action}) {
    switch (answer) {
      case Left():
        emit(state.copyWith(status: PostEditStatus.failedToLoad, errorText: null));
      case Right(value: PostEditFormRefused(:final message)):
        emit(state.copyWith(status: PostEditStatus.failedToLoad, errorText: message.isEmpty ? null : message));
      case Right(value: PostEditFormPage(:final document)):
        SecCheck? check;
        if (documentAsksVerification(document)) {
          check = SecCheck.fromElement(document.querySelector('form#postform') ?? document.querySelector('#ct'));
          if (check == null) {
            emit(const PostEditState(status: PostEditStatus.verificationRequired));
            return;
          }
        }
        if (!PostEditContent.supportsDocument(document)) {
          emit(const PostEditState(status: PostEditStatus.unsupported));
          return;
        }
        final content = PostEditContent.fromDocument(document, requireThreadInfo: action == 'edit')?.copyWith(
          secCheck: check,
        );
        if (content == null) {
          error('failed to build edit content');
          emit(state.copyWith(status: PostEditStatus.failedToLoad));
          return;
        }
        emit(
          state.copyWith(
            status: PostEditStatus.editing,
            content: content,
            forumName: document
                .querySelectorAll(
                  action == 'edit' ? 'div#pt > div.z > a[href*="fid="]' : 'div#pt > div.z > a[href*="&fid="]',
                )
                .lastOrNull
                ?.text,
          ),
        );
      case Right(value: PostEditFormApi(:final form)):
        switch (form.editorSupport(action)) {
          case PostFormSupport.verification:
            emit(const PostEditState(status: PostEditStatus.verificationRequired));
            return;
          case PostFormSupport.unsupported:
            emit(const PostEditState(status: PostEditStatus.unsupported));
            return;
          case PostFormSupport.supported:
            break;
        }
        final content = PostEditContent.fromPostForm(form);
        if (content == null) {
          emit(state.copyWith(status: PostEditStatus.failedToLoad));
          return;
        }
        emit(state.copyWith(status: PostEditStatus.editing, content: content, forumName: form.forumName));
    }
  }

  /// [handler] sending the content, its unexpected failure (an exception, not a failed request) made a failed upload:
  /// the page stayed "uploading" for good, and leaving it was refused while sending.
  EventHandler<E, PostEditState> _sending<E extends PostEditEvent>(EventHandler<E, PostEditState> handler) =>
      (event, emit) async {
        try {
          await handler(event, emit);
        } on Object catch (e, st) {
          handleRaw(e, st);
          final wasSending = _submitting;
          _submitting = false;
          if (wasSending && _active(emit)) {
            emit(
              state.copyWith(
                status: PostEditStatus.failedToUpload,
                errorText: null,
                needsBrowser: false,
                secCheck: null,
                wrongAnswer: false,
              ),
            );
          }
        }
      };

  Future<void> _onPostEditCompleteEditRequested(PostEditCompleteEditRequested event, _Emit emit) async {
    if (!canSubmit || !_active(emit)) return;
    if (event.save == '1' && !state.content!.canSaveDraft) return;
    _submitting = true;
    emit(state.copyWith(status: PostEditStatus.uploading));
    final form = state.content!.form;
    final result = form != null
        ? (await _repo
                  .submitForm(
                    form,
                    PostFormEdits(
                      message: event.data,
                      subject: event.threadTitle,
                      typeId: event.threadType?.typeID,
                      perm: event.perm,
                      price: event.price,
                      options: {for (final option in event.options) option.name: option.checked},
                      save: event.save,
                    ),
                    expectedTid: event.tid,
                  )
                  .run())
              .map((_) {})
        : await _repo
              .postEditedContent(
                formHash: event.formHash,
                postTime: event.postTime,
                delattachop: event.delattachop,
                wysiwyg: event.wysiwyg,
                fid: event.fid,
                tid: event.tid,
                pid: event.pid,
                page: event.page,
                threadType: event.threadType?.typeID,
                threadTitle: event.threadTitle,
                data: event.data,
                save: event.save,
                perm: event.perm,
                price: event.price,
                tags: state.content!.tags,
                options: Map.fromEntries(
                  event.options.where((e) => !e.disabled && e.checked).map((e) => MapEntry(e.name, e.value)),
                ),
              )
              .run();
    if (result case Left(:final value)) {
      _markMaybeSent(value, event.draftKey);
    }
    if (!_active(emit)) {
      _submitting = false;
      return;
    }
    if (result.isLeft()) {
      final error = result.unwrapErr();
      _submitting = false;
      emit(_uploadFailed(error));
      return;
    }
    _taken(event.draftKey);
    final threadUrl = '$baseUrl/forum.php?mod=viewthread&tid=${event.tid}';
    final confirmed = event.save != '1' || await _repo.confirmsDraft(threadUrl);
    // A draft published from a post form of the app API (its first post: the thread itself): the forum may keep it a
    // draft (a scheduled publication, a plugin) although it took the edits; the thread tells. A reply edited in one's
    // own draft thread publishes nothing.
    final stillDraft =
        event.save != '1' &&
        (form?.first ?? false) &&
        (form?.isDraftThread ?? false) &&
        await _repo.confirmsDraft(threadUrl);
    _submitting = false;
    if (_active(emit)) {
      emit(
        state.copyWith(
          status: stillDraft
              ? PostEditStatus.stillDraft
              : (confirmed ? PostEditStatus.success : PostEditStatus.draftUnconfirmed),
          redirectTid: event.tid,
          needsBrowser: false,
        ),
      );
    }
  }

  Future<void> _onFetchNewThreadInfo(String fid, _Emit emit) async {
    if (!_active(emit) || _submitting) return;
    emit(state.copyWith(status: PostEditStatus.loading));
    final answer = await _repo.prepareForm(fid).run();
    if (!_active(emit)) return;
    _onFormLoaded(answer, emit, action: 'newthread');
  }

  /// The failed upload of [error]: the forum's reason, or what it asks before taking the post ([SecCheck]: the page asks
  /// the user and sends again; none known, the website).
  /// Whether the post may have been taken although [error] came back: the request left and no answer came, or one
  /// that could not be read.
  static bool _mayHaveSent(AppException error) =>
      error is! PostEditFailedToUploadResult &&
      error is! PostVerificationRequiredException &&
      error is! IdentityChangedException &&
      !isNoNetworkFailure(error);

  /// The local draft of [draftKey] says it may have been sent ([_mayHaveSent]), also for a page closed meanwhile.
  void _markMaybeSent(AppException error, String? draftKey) {
    final uid = _repo.ownerUid;
    final key = draftKey == null ? null : LocalDraftKey.parse(draftKey);
    if (_mayHaveSent(error) && uid != null && key != null) {
      LocalDraftStore.app?.markMaybeSent(uid, key);
    }
  }

  PostEditState _uploadFailed(AppException error) => state.copyWith(
    maybeSent: _mayHaveSent(error),
    status: PostEditStatus.failedToUpload,
    errorText: error is PostEditFailedToUploadResult ? error.errorText : null,
    needsBrowser: error is PostVerificationRequiredException && error.check == null,
    secCheck: error is PostVerificationRequiredException ? error.check : null,
    wrongAnswer: error is PostVerificationRequiredException && error.wrongAnswer,
  );

  /// The post was taken: the local draft of [draftKey] goes, the forum's interval between two posts counts from now.
  void _taken(String? draftKey) {
    final uid = _repo.ownerUid;
    FloodControl.notePosted(uid);
    final key = draftKey == null ? null : LocalDraftKey.parse(draftKey);
    if (uid != null && key != null) {
      LocalDraftStore.app?.delete(uid, key);
    }
  }

  Future<void> _onPostNewThread(ThreadPubPostThread event, _Emit emit) async {
    final info = event.info;
    if (!canSubmit || !_active(emit)) return;
    if (info.save == '1' && !state.content!.canSaveDraft) return;
    _submitting = true;
    emit(state.copyWith(status: PostEditStatus.uploading));

    final form = state.content!.form;
    final told = state.content!.secCheck;
    final tidEither = form != null
        ? await _repo
              .submitForm(
                form,
                PostFormEdits(
                  message: info.message,
                  subject: info.subject,
                  typeId: info.threadType?.typeID,
                  perm: info.perm,
                  price: info.price,
                  options: {for (final option in info.options) option.name: option.checked},
                  save: info.save,
                ),
                verification: event.verification,
                told: told,
              )
              .run()
        : await _repo.postThread(info, verification: event.verification, told: told).run();
    if (event.verification != null) {
      // Posted with the answers: the forum is done with the cookies of the checks.
      await clearSecCheckCookies();
    }
    switch (tidEither) {
      case Right():
        // Taken: whatever the page does now (it may be gone), the local draft goes.
        _taken(event.draftKey);
      case Left(:final value):
        _markMaybeSent(value, event.draftKey);
    }
    if (!_active(emit)) {
      _submitting = false;
      return;
    }
    if (tidEither.isLeft()) {
      _submitting = false;
      emit(_uploadFailed(tidEither.unwrapErr()));
      return;
    }
    final tid = _tidRe.firstMatch(tidEither.unwrap())?.namedGroup('tid');
    final confirmed = info.save != '1' || await _repo.confirmsDraft(tidEither.unwrap());
    _submitting = false;
    if (_active(emit)) {
      emit(
        state.copyWith(
          status: confirmed ? PostEditStatus.success : PostEditStatus.draftUnconfirmed,
          redirectTid: tid,
          needsBrowser: false,
        ),
      );
    }
  }
}
