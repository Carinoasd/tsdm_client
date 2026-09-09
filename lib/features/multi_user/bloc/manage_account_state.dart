part of 'manage_account_bloc.dart';

/// What the last delete request did.
enum ManageAccountStatus {
  /// Nothing running.
  idle,

  /// Deleting the selected accounts.
  deleting,

  /// The selected accounts were deleted, [ManageAccountState.deletedCount] tells how many.
  deleted,

  /// Deleting failed.
  failed,
}

/// State of the manage accounts page: which accounts are selected and what deleting them did.
@MappableClass()
final class ManageAccountState with ManageAccountStateMappable {
  /// Constructor.
  const ManageAccountState({
    this.selecting = false,
    this.selectedUids = const {},
    this.status = ManageAccountStatus.idle,
    this.deletedCount = 0,
  });

  /// Whether the page is in selection mode.
  final bool selecting;

  /// Uids of the selected accounts.
  final Set<int> selectedUids;

  /// What the last delete request did.
  final ManageAccountStatus status;

  /// Accounts removed by the last delete request.
  final int deletedCount;
}
