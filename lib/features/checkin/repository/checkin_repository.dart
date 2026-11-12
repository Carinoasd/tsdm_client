import 'package:tsdm_client/features/checkin/models/models.dart';
import 'package:tsdm_client/features/checkin/utils/checkin_day.dart';
import 'package:tsdm_client/features/checkin/utils/do_checkin.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/logger.dart';

/// Repository of checkin feature.
final class CheckinRepository with LoggerMixin {
  /// Constructor.
  const CheckinRepository({required StorageProvider storageProvider}) : _storageProvider = storageProvider;

  final StorageProvider _storageProvider;

  /// Whether this app recorded a check-in of the account [uid] today (a manual or automatic check-in that succeeded
  /// or was answered "already checked in").
  ///
  /// Only what the app did itself: a check-in made on the website is not known until the next attempt here.
  Future<bool> checkedInToday(int uid) async => isCheckedInToday(await _storageProvider.getLastCheckinTime(uid));

  /// Check-ins of the account in use running right now ([checkin]).
  static int _running = 0;

  /// Whether a check-in of the account in use is running.
  ///
  /// An account switch waits for it, as for a reply being sent (`ReplyBloc.sendingAny`): the check-in is sent with the
  /// cookie of the account in use, read anew by each of its requests, so a switch meanwhile posted the form (and the
  /// form hash) of one account with the session of the other, and its result was recorded for the first one. The auto
  /// check-in sends each account with a client of its own cookie, the switch does not reach it.
  static bool get checkingInAny => _running > 0;

  /// Perform a checkin for user [uid], the account in use.
  Future<CheckinResult> checkin(int uid, CheckinFeeling feeling, String message) async {
    _running++;
    try {
      final netClient = getIt.get<NetClientProvider>();
      final checkinResult = await doCheckin(netClient, feeling, message).run();
      if (checkinResult is CheckinResultSuccess || checkinResult is CheckinResultAlreadyChecked) {
        await _storageProvider.updateLastCheckinTime(uid, DateTime.now()).run();
      }
      return checkinResult;
    } finally {
      _running--;
    }
  }
}
