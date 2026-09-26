import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/fp.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/post/models/models.dart';
import 'package:tsdm_client/features/post/repository/post_edit_repository.dart';
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
    on<PostEditCompleteEditRequested>(_onPostEditCompleteEditRequested);
    on<ThreadPubFetchInfoRequested>((event, emit) => _onFetchNewThreadInfo(event.fid, emit));
    on<ThreadPubPostThread>((event, emit) => _onPostNewThread(event.info, emit));
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
    await _repo
        .fetchData(event.editUrl)
        .match(
          (e) {
            if (!_active(emit)) return;
            emit(state.copyWith(status: PostEditStatus.failedToLoad));
          },
          (v) {
            if (!_active(emit)) return;
            final document = v;
            if (!PostEditContent.supportsDocument(document)) {
              emit(const PostEditState(status: PostEditStatus.unsupported));
              return;
            }
            final content = PostEditContent.fromDocument(document);
            if (content == null) {
              emit(state.copyWith(status: PostEditStatus.failedToLoad));
              return;
            }
            emit(
              state.copyWith(
                status: PostEditStatus.editing,
                content: content,
                forumName: document.querySelectorAll('div#pt > div.z > a[href*="fid="]').lastOrNull?.text,
              ),
            );
          },
        )
        .run();
  }

  Future<void> _onPostEditCompleteEditRequested(PostEditCompleteEditRequested event, _Emit emit) async {
    if (!canSubmit || !_active(emit)) return;
    if (event.save == '1' && !state.content!.canSaveDraft) return;
    _submitting = true;
    emit(state.copyWith(status: PostEditStatus.uploading));
    final result = await _repo
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
    if (!_active(emit)) {
      _submitting = false;
      return;
    }
    if (result.isLeft()) {
      final error = result.unwrapErr();
      _submitting = false;
      emit(
        state.copyWith(
          status: PostEditStatus.failedToUpload,
          errorText: error is PostEditFailedToUploadResult ? error.errorText : null,
        ),
      );
      return;
    }
    final confirmed =
        event.save != '1' || await _repo.confirmsDraft('$baseUrl/forum.php?mod=viewthread&tid=${event.tid}');
    _submitting = false;
    if (_active(emit)) {
      emit(
        state.copyWith(
          status: confirmed ? PostEditStatus.success : PostEditStatus.draftUnconfirmed,
          redirectTid: event.tid,
        ),
      );
    }
  }

  Future<void> _onFetchNewThreadInfo(String fid, _Emit emit) async {
    if (!_active(emit) || _submitting) return;
    emit(state.copyWith(status: PostEditStatus.loading));

    final docEither = await _repo.prepareInfo(fid).run();
    if (!_active(emit)) return;
    if (docEither.isLeft()) {
      emit(state.copyWith(status: PostEditStatus.failedToLoad));
      return;
    }

    final doc = docEither.unwrap();
    if (!PostEditContent.supportsDocument(doc)) {
      emit(const PostEditState(status: PostEditStatus.unsupported));
      return;
    }

    final editContent = PostEditContent.fromDocument(doc, requireThreadInfo: false);
    if (editContent == null) {
      error('failed to build edit content');
      emit(state.copyWith(status: PostEditStatus.failedToLoad));
      return;
    }

    final forumName = doc.querySelectorAll('div#pt > div.z > a[href*="&fid="]').lastOrNull?.text;

    emit(state.copyWith(status: PostEditStatus.editing, content: editContent, forumName: forumName));
  }

  Future<void> _onPostNewThread(ThreadPublishInfo info, _Emit emit) async {
    if (!canSubmit || !_active(emit)) return;
    if (info.save == '1' && !state.content!.canSaveDraft) return;
    _submitting = true;
    emit(state.copyWith(status: PostEditStatus.uploading));

    final tidEither = await _repo.postThread(info).run();
    if (!_active(emit)) {
      _submitting = false;
      return;
    }
    if (tidEither.isLeft()) {
      _submitting = false;
      final err = tidEither.unwrapErr();
      emit(
        state.copyWith(
          status: PostEditStatus.failedToUpload,
          errorText: err is PostEditFailedToUploadResult ? err.errorText : null,
        ),
      );
      return;
    }
    final tid = _tidRe.firstMatch(tidEither.unwrap())?.namedGroup('tid');
    final confirmed = info.save != '1' || await _repo.confirmsDraft(tidEither.unwrap());
    _submitting = false;
    if (_active(emit)) {
      emit(
        state.copyWith(status: confirmed ? PostEditStatus.success : PostEditStatus.draftUnconfirmed, redirectTid: tid),
      );
    }
  }
}
