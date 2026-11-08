import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/space/models/space_models.dart';
import 'package:tsdm_client/features/space/repository/space_write_repository.dart';

/// Where a form of the space is.
enum SpaceWriteStatus {
  /// Loading the form.
  loading,

  /// The form failed to load, or the forum printed its words instead ([SpaceWriteState.message]).
  loadFailed,

  /// The form was served to a guest.
  needLogin,

  /// The account changed: nothing more is sent from this page.
  identityChanged,

  /// The form is ready.
  ready,

  /// Sending.
  sending,

  /// Done: the blog posted, the pictures filed ([SpaceWriteState.id]).
  done,

  /// The forum refused ([SpaceWriteState.message]): nothing was done, the form can be sent again.
  rejected,

  /// The request may have reached the forum: not sent again by itself.
  unconfirmed,
}

/// State of a form of the space.
final class SpaceWriteState<F> {
  /// Constructor.
  const SpaceWriteState({
    this.status = SpaceWriteStatus.loading,
    this.form,
    this.message,
    this.id,
    this.sent = 0,
    this.total = 0,
    this.refused = const [],
  });

  /// Where the form is.
  final SpaceWriteStatus status;

  /// The form, once loaded.
  final F? form;

  /// The forum's words.
  final String? message;

  /// The blog posted, the album the pictures went to.
  final int? id;

  /// Pictures sent so far.
  final int sent;

  /// Pictures to send.
  final int total;

  /// The pictures the forum did not take, with why.
  final List<({String path, SpaceUploadRefusal reason})> refused;
}

/// Shared by the new blog and the album upload pages: one form, for one account, sent once per tap.
abstract base class _SpaceWriteCubit<F> extends Cubit<SpaceWriteState<F>> {
  _SpaceWriteCubit(this.repository, {Stream<AuthStatus>? authChanges}) : super(SpaceWriteState<F>()) {
    _authSubscription = authChanges?.listen((status) {
      if (status is AuthStatusAuthed && repository.belongsTo(status.userInfo.uid)) return;
      if (status is AuthStatusLoading || status is AuthStatusUnknown) return;
      repository.invalidate();
      if (!isClosed) emit(SpaceWriteState<F>(status: SpaceWriteStatus.identityChanged));
    });
  }

  /// The repository of the account.
  final SpaceWriteRepository repository;

  StreamSubscription<AuthStatus>? _authSubscription;

  /// Whether the form can be sent now.
  bool get canSend =>
      repository.isCurrent &&
      state.form != null &&
      (state.status == SpaceWriteStatus.ready || state.status == SpaceWriteStatus.rejected);

  Future<SpaceFormLoad<F>> _loadForm();

  /// Load the form.
  Future<void> load() async {
    emit(SpaceWriteState<F>());
    final load = await _loadForm();
    if (isClosed || state.status == SpaceWriteStatus.identityChanged) return;
    emit(switch (load.kind) {
      SpaceFormLoadKind.ready => SpaceWriteState<F>(status: SpaceWriteStatus.ready, form: load.form),
      SpaceFormLoadKind.denied => SpaceWriteState<F>(status: SpaceWriteStatus.loadFailed, message: load.message),
      SpaceFormLoadKind.loginRequired => SpaceWriteState<F>(status: SpaceWriteStatus.needLogin),
      SpaceFormLoadKind.identityChanged => SpaceWriteState<F>(status: SpaceWriteStatus.identityChanged),
      SpaceFormLoadKind.failed => SpaceWriteState<F>(status: SpaceWriteStatus.loadFailed),
    });
  }

  void _finish(SpaceWriteResult result, {List<({String path, SpaceUploadRefusal reason})> refused = const []}) {
    if (isClosed || state.status == SpaceWriteStatus.identityChanged) return;
    final form = state.form;
    emit(switch (result.outcome) {
      SpaceWriteOutcome.done => SpaceWriteState<F>(
        status: SpaceWriteStatus.done,
        form: form,
        id: result.id,
        message: result.message,
        refused: refused,
      ),
      SpaceWriteOutcome.rejected => SpaceWriteState<F>(
        status: SpaceWriteStatus.rejected,
        form: form,
        message: result.message,
        refused: refused,
      ),
      SpaceWriteOutcome.unconfirmed => SpaceWriteState<F>(
        status: SpaceWriteStatus.unconfirmed,
        form: form,
        message: result.message,
        refused: refused,
      ),
      SpaceWriteOutcome.identityChanged => SpaceWriteState<F>(status: SpaceWriteStatus.identityChanged),
    });
  }

  @override
  Future<void> close() async {
    repository.invalidate();
    await _authSubscription?.cancel();
    return super.close();
  }
}

/// The new blog page.
final class BlogPostCubit extends _SpaceWriteCubit<BlogPostForm> {
  /// Constructor.
  BlogPostCubit(super.repository, {super.authChanges});

  @override
  Future<SpaceFormLoad<BlogPostForm>> _loadForm() => repository.loadBlogForm();

  /// Post [draft], once.
  Future<void> post(BlogDraft draft) async {
    if (!canSend) return;
    final form = state.form!;
    emit(SpaceWriteState(status: SpaceWriteStatus.sending, form: form));
    _finish(await repository.postBlog(form, draft));
  }
}

/// The album upload page.
final class AlbumUploadCubit extends _SpaceWriteCubit<AlbumUploadForm> {
  /// Constructor; [albumId] is the album chosen first.
  AlbumUploadCubit(super.repository, {this.albumId, super.authChanges, this.fileSize});

  /// The album chosen first.
  final int? albumId;

  /// The size of a file in bytes, for tests; the file system's by default.
  final int Function(String path)? fileSize;

  @override
  Future<SpaceFormLoad<AlbumUploadForm>> _loadForm() => repository.loadUploadForm(albumId: albumId);

  /// Upload the pictures [paths] one after the other, then file those the forum took to [target], once.
  Future<void> upload(List<String> paths, AlbumTarget target) async {
    if (!canSend || paths.isEmpty) return;
    final form = state.form!;
    final picIds = <int>[];
    final refused = <({String path, SpaceUploadRefusal reason})>[];
    for (final (i, path) in paths.indexed) {
      if (isClosed || state.status == SpaceWriteStatus.identityChanged) return;
      emit(SpaceWriteState(status: SpaceWriteStatus.sending, form: form, sent: i, total: paths.length));
      switch (await repository.uploadPhoto(form, path, fileSize: fileSize)) {
        case Left(value: SpaceUploadRefusal.identityChanged):
          _finish(const SpaceWriteResult(SpaceWriteOutcome.identityChanged));
          return;
        case Left(:final value):
          refused.add((path: path, reason: value));
        case Right(:final value):
          picIds.add(value);
      }
    }
    if (isClosed || state.status == SpaceWriteStatus.identityChanged) return;
    if (picIds.isEmpty) {
      _finish(const SpaceWriteResult(SpaceWriteOutcome.rejected), refused: refused);
      return;
    }
    emit(SpaceWriteState(status: SpaceWriteStatus.sending, form: form, sent: paths.length, total: paths.length));
    _finish(await repository.fileUploads(form, picIds, target), refused: refused);
  }
}
