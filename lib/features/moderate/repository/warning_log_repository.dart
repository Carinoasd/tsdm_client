import 'dart:io' if (dart.libaray.js) 'package:web/web.dart';

import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/moderate/models/warning_log.dart';
import 'package:tsdm_client/features/moderate/repository/moderate_repository.dart';
import 'package:tsdm_client/features/tsdmapp/small_form.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';

/// The warnings of a member, read from the forum's warning window (`forum.php?mod=misc&action=viewwarning`).
///
/// The forum's app API leaves the window alone (no JSON answer: it would tell the author of an anonymous floor), so
/// the ajax window is read as the web page opens it. The forum decides who may look: anyone who may read the thread's
/// forum, a guest too. An answer that comes after the account changed is dropped ([IdentityChangedException]).
final class WarningLogRepository {
  /// Constructor; the transport is injected so the flow is tested without the forum.
  WarningLogRepository({required ModerateGet get, int Function()? currentUid})
    : _get = get,
      _currentUid = currentUid ?? currentLoginUid;

  /// Uses the app's client.
  factory WarningLogRepository.network() => WarningLogRepository(
    get: (url) async => switch (await getIt.get<NetClientProvider>().get(url).run()) {
      Left(:final value) => left(value),
      Right(:final value) => right((statusCode: value.statusCode ?? 0, data: value.data)),
    },
  );

  final ModerateGet _get;
  final int Function() _currentUid;

  /// The warnings of member [uid], asked from thread [tid].
  Future<Either<AppException, WarningLogAnswer>> fetch({required int tid, required int uid}) async {
    final url = warningLogUrl(tid: tid, uid: uid);
    if (url == null) {
      return left(HttpRequestFailedException(null));
    }
    final asker = _currentUid();
    switch (await _get(url)) {
      case Left(:final value):
        return left(value);
      case Right(:final value) when value.statusCode != HttpStatus.ok:
        return left(HttpRequestFailedException(value.statusCode));
      case Right(:final value):
        if (_currentUid() != asker) {
          return left(IdentityChangedException());
        }
        final data = value.data;
        final answer = data is String ? parseWarningLog(data) : null;
        return answer == null ? left(HttpRequestFailedException(HttpStatus.ok)) : right(answer);
    }
  }
}
