import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

/// Tries when the account in use changed while it was being removed (a switch finishing meanwhile).
const _tries = 3;

/// Remove every account saved on this device, for "forgot PIN"; true when none is left.
///
/// Local only, like deleting accounts on the manage accounts page: the forum is not asked to log out (that would need
/// a switch to each account, and fails offline), the sessions stay valid elsewhere. The accounts other than the one in
/// use lose their saved login, then the one in use is removed through [AuthenticationRepository.forgetCurrentUser],
/// which also signs this device out.
Future<bool> forgetAllAccounts({
  required AuthenticationRepository authenticationRepository,
  required StorageProvider storageProvider,
}) async {
  for (var i = 0; i < _tries; i++) {
    final current = authenticationRepository.effectiveCurrentUid;
    final all = await storageProvider.getAllUsers();
    final others = all.map((e) => e.uid).nonNulls.where((uid) => uid != current);
    await storageProvider.deleteCookiesByUids(others);
    if (current != null) {
      switch (await authenticationRepository.forgetCurrentUser(uid: current).run()) {
        case Left(value: IdentityChangedException()):
          talker.info('app lock: the account in use changed while removing every account, again');
          continue;
        case Left(:final value):
          talker.handle(value, null, 'app lock: failed to remove the account in use');
          return false;
        case Right():
          break;
      }
    }
    if (authenticationRepository.effectiveCurrentUid == null && (await storageProvider.getAllUsers()).isEmpty) {
      talker.info('app lock: every account removed from this device');
      return true;
    }
  }
  return false;
}
