import 'package:flutter/foundation.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';

/// What the forum answered a read of the account's document.
@immutable
sealed class SyncPullAnswer {
  const SyncPullAnswer();
}

/// The document (null when the account stored none yet) and its `updated` (0 for none), with the form hash a write
/// needs.
final class SyncPulled extends SyncPullAnswer {
  /// Constructor.
  const SyncPulled({required this.updated, required this.data, required this.formhash, this.uid});

  /// The account the forum answered for (the session's), null when the answer did not name it.
  final int? uid;

  /// The forum's time of the last write (seconds), 0 when nothing was written.
  final int updated;

  /// The stored document text, null when none.
  final String? data;

  /// The form hash of the session, for the writes.
  final String formhash;
}

/// The forum's plugin does not keep documents: it is older than 3.4.0, or its table is not created yet.
final class SyncUnsupported extends SyncPullAnswer {
  /// Constructor.
  const SyncUnsupported();
}

/// The forum says the session is not logged in.
final class SyncNotLoggedIn extends SyncPullAnswer {
  /// Constructor.
  const SyncNotLoggedIn();
}

/// No usable answer (a failed request, the API missing or switched off, too many calls).
final class SyncPullFailed extends SyncPullAnswer {
  /// Constructor.
  const SyncPullFailed(this.reason);

  /// Why.
  final String reason;
}

/// What the forum answered a write of the account's document.
@immutable
sealed class SyncPushAnswer {
  const SyncPushAnswer();
}

/// Written: the forum's `updated` of it.
final class SyncPushed extends SyncPushAnswer {
  /// Constructor.
  const SyncPushed(this.updated);

  /// The forum's time of this write (seconds).
  final int updated;
}

/// Not written: another device wrote since this one read (HTTP 409); the forum's document and its `updated`.
final class SyncConflict extends SyncPushAnswer {
  /// Constructor.
  const SyncConflict({required this.updated, required this.data});

  /// The forum's time of the other write (seconds).
  final int updated;

  /// The document the forum holds now, null when it was cleared.
  final String? data;
}

/// Not written: the document is over the plugin's limit (HTTP 413).
final class SyncTooLarge extends SyncPushAnswer {
  /// Constructor.
  const SyncTooLarge(this.maxBytes);

  /// The plugin's limit (bytes).
  final int maxBytes;
}

/// Not written, no usable answer (a failed request, the form hash refused, the API missing or switched off).
final class SyncPushFailed extends SyncPushAnswer {
  /// Constructor.
  const SyncPushFailed(this.reason);

  /// Why.
  final String reason;
}

/// The forum's `sync` action (plugin 3.4.0): one document per account, read with GET, written with POST.
abstract interface class SyncApi {
  /// Read the account's document.
  Future<SyncPullAnswer> pull();

  /// Write [data] as the account's document, when the forum's `updated` is still [baseUpdated].
  Future<SyncPushAnswer> push({required String data, required int baseUpdated, required String formhash});
}

/// [SyncApi] on the forum's app API ([TsdmAppApi]).
///
/// The client of each call is built then. A client is bound to the account it was built for (`NetClientProvider`):
/// built once at the start, it would stay the guest's or the previous account's and every call after a login or a
/// switch be dropped as another account's; built per call, each call goes out as the account in use.
final class TsdmAppSyncApi implements SyncApi {
  /// Constructor.
  const TsdmAppSyncApi(NetClientProvider Function() client) : _client = client;

  final NetClientProvider Function() _client;

  /// The action.
  static const action = 'sync';

  @override
  Future<SyncPullAnswer> pull() async {
    // Waits for a "too soon" answer: the read follows the notification poll at the start, on another action.
    final json = await TsdmAppApi.askWaitingKeepingAction(_client(), action);
    if (json == null) {
      return const SyncPullFailed('no answer');
    }
    if (json['ok'] == 0) {
      return switch (json['error']) {
        'login' => const SyncNotLoggedIn(),
        // An older plugin without the action.
        'action' => const SyncUnsupported(),
        final e => SyncPullFailed('$e'),
      };
    }
    if (json['supported'] != 1) {
      return const SyncUnsupported();
    }
    final data = json['data'];
    return SyncPulled(
      uid: (json['uid'] as num?)?.toInt(),
      updated: (json['updated'] as num?)?.toInt() ?? 0,
      data: data is String ? data : null,
      formhash: json['formhash'] is String ? json['formhash'] as String : '',
    );
  }

  @override
  Future<SyncPushAnswer> push({required String data, required int baseUpdated, required String formhash}) async {
    final json = await TsdmAppApi.post(
      _client(),
      action,
      {
        'formhash': formhash,
        'data': data,
        'base_updated': '$baseUpdated',
      },
      acceptStatus: const {409, 413},
    );
    if (json == null) {
      return const SyncPushFailed('no answer');
    }
    if (json['ok'] == 1) {
      if (json['supported'] == 0) {
        return const SyncPushFailed('unsupported');
      }
      return SyncPushed((json['updated'] as num?)?.toInt() ?? 0);
    }
    return switch (json['error']) {
      'conflict' => SyncConflict(
        updated: (json['updated'] as num?)?.toInt() ?? 0,
        data: json['data'] is String ? json['data'] as String : null,
      ),
      'size' => SyncTooLarge((json['max_bytes'] as num?)?.toInt() ?? 0),
      final e => SyncPushFailed('$e'),
    };
  }
}
