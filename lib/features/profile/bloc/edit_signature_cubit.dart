import 'package:bloc/bloc.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/profile/models/signature_form.dart';
import 'package:tsdm_client/features/profile/repository/edit_user_profile_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/logger.dart';

/// Status of [EditSignatureCubit].
enum EditSignatureStatus {
  /// Loading the signature form.
  loading,

  /// Failed to load the signature form.
  loadFailed,

  /// The form is loaded and can be edited.
  ready,

  /// Posting the signature.
  saving,

  /// The signature was saved.
  saved,

  /// The forum did not save the signature.
  saveFailed,
}

/// State of [EditSignatureCubit].
final class EditSignatureState {
  /// Constructor.
  const EditSignatureState({this.status = EditSignatureStatus.loading, this.form, this.reason, this.saved});

  /// Status.
  final EditSignatureStatus status;

  /// The signature form loaded.
  final SignatureForm? form;

  /// The forum's words (or the app's own) on the failure, null when there are none.
  final String? reason;

  /// The signature saved, once [status] is [EditSignatureStatus.saved].
  final String? saved;
}

/// Load and save the signature of the member.
final class EditSignatureCubit extends Cubit<EditSignatureState> with LoggerMixin {
  /// Constructor.
  EditSignatureCubit(this._repo) : super(const EditSignatureState());

  final EditUserProfileRepository _repo;

  /// Load the signature form.
  Future<void> load() async {
    emit(const EditSignatureState());
    await _repo.loadSignature().match(
      (e) {
        handle(e);
        emit(
          EditSignatureState(
            status: EditSignatureStatus.loadFailed,
            reason: e is EditUserProfileFormNotFound ? e.reason : null,
          ),
        );
      },
      (form) => emit(EditSignatureState(status: EditSignatureStatus.ready, form: form)),
    ).run();
  }

  /// Save the signature [value]; nothing is posted while a save runs, or when it is too long for the forum.
  Future<void> save(String value) async {
    final form = state.form;
    if (form == null || state.status == EditSignatureStatus.saving || !form.fits(value)) {
      return;
    }
    emit(EditSignatureState(status: EditSignatureStatus.saving, form: form));
    await _repo.uploadSignature(form, value).match(
      (e) {
        handle(e);
        emit(
          EditSignatureState(
            status: EditSignatureStatus.saveFailed,
            form: form,
            reason: switch (e) {
              EditUserProfileUploadFailed(:final reason) => reason,
              IdentityChangedException() => t.general.accountChangedRetry,
              _ => null,
            },
          ),
        );
      },
      (_) => emit(EditSignatureState(status: EditSignatureStatus.saved, form: form, saved: value)),
    ).run();
  }
}
