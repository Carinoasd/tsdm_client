part of 'manage_account_bloc.dart';

/// Event of the manage accounts page.
@MappableClass()
sealed class ManageAccountEvent with ManageAccountEventMappable {
  /// Constructor.
  const ManageAccountEvent();
}

/// Enter selection mode with nothing selected.
@MappableClass()
final class ManageAccountSelectionStarted extends ManageAccountEvent with ManageAccountSelectionStartedMappable {
  /// Constructor.
  const ManageAccountSelectionStarted();
}

/// Select or unselect the account [uid]; entering selection mode when not in it yet.
@MappableClass()
final class ManageAccountSelectionToggled extends ManageAccountEvent with ManageAccountSelectionToggledMappable {
  /// Constructor.
  const ManageAccountSelectionToggled(this.uid);

  /// Uid of the account.
  final int uid;
}

/// Select all accounts in [uids].
@MappableClass()
final class ManageAccountSelectAllRequested extends ManageAccountEvent with ManageAccountSelectAllRequestedMappable {
  /// Constructor.
  const ManageAccountSelectAllRequested(this.uids);

  /// Uids of all accounts listed.
  final List<int> uids;
}

/// Leave selection mode.
@MappableClass()
final class ManageAccountSelectionCleared extends ManageAccountEvent with ManageAccountSelectionClearedMappable {
  /// Constructor.
  const ManageAccountSelectionCleared();
}

/// Delete the selected accounts from this device.
@MappableClass()
final class ManageAccountDeleteSelectedRequested extends ManageAccountEvent
    with ManageAccountDeleteSelectedRequestedMappable {
  /// Constructor.
  const ManageAccountDeleteSelectedRequested();
}
