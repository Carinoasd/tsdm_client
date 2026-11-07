import 'package:bloc/bloc.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/profile/models/avatar_upload.dart';
import 'package:tsdm_client/features/profile/repository/profile_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/logger.dart';

part 'edit_avatar_bloc.mapper.dart';
part 'edit_avatar_event.dart';
part 'edit_avatar_state.dart';

typedef _Emit = Emitter<EditAvatarState>;

/// The edit state.
final class EditAvatarBloc extends Bloc<EditAvatarEvent, EditAvatarState> with LoggerMixin {
  /// Constructor.
  EditAvatarBloc(this._repo) : super(const EditAvatarState()) {
    on<EditAvatarEvent>(
      (event, emit) => switch (event) {
        EditAvatarLoadInfoRequested() => _onLoadInfo(emit),
        EditAvatarUploadRequested(:final avatarUrl, :final formHash) => _onUpload(emit, avatarUrl, formHash),
        EditAvatarImageUploadRequested(:final images) => _onUploadImages(emit, images),
      },
    );
  }

  final ProfileRepository _repo;

  Future<void> _onLoadInfo(_Emit emit) async {
    emit(state.copyWith(status: EditAvatarStatus.loading));

    await _repo
        .loadAvatarEditPage()
        .map(
          (v) => emit(
            EditAvatarState(
              status: EditAvatarStatus.waitingForUpload,
              avatarUrl: v.externalUrl,
              formHash: v.hasExternal ? v.formHash : null,
              canUpload: v.hasUpload,
              currentAvatar: v.currentAvatar,
            ),
          ),
        )
        .mapLeft((e) {
          handle(e);
          emit(state.copyWith(status: EditAvatarStatus.failure));
        })
        .run();
  }

  Future<void> _onUpload(_Emit emit, String avatarUrl, String formHash) async {
    emit(state.copyWith(status: EditAvatarStatus.uploading, uploadFailure: null));

    await _repo.uploadAvatarUrl(url: avatarUrl, formHash: formHash).handle((e) {
      handle(e);
      emit(state.copyWith(status: EditAvatarStatus.failure));
    }, (_) => emit(state.copyWith(status: EditAvatarStatus.success)));
  }

  Future<void> _onUploadImages(_Emit emit, AvatarImages images) async {
    emit(state.copyWith(status: EditAvatarStatus.uploading, uploadFailure: null));

    await _repo.uploadAvatarImages(images).handle((e) {
      handle(e);
      // The page stays: the forum's words on why, and the editor to try another image.
      emit(
        state.copyWith(
          status: EditAvatarStatus.waitingForUpload,
          uploadFailure: switch (e) {
            EditAvatarUploadFailed(answer: 'denied') || IdentityChangedException() => t.general.needLogin,
            _ => t.editAvatarPage.uploadFailed,
          },
        ),
      );
    }, (_) => emit(state.copyWith(status: EditAvatarStatus.success)));
  }
}
