import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';

/// What the forum answered grabbing a share of a red packet, or withdrawing it (plugin 3.5.0, [HongbaoRepository]).
sealed class HongbaoOutcome {
  const HongbaoOutcome();
}

/// A share grabbed: [amount] of the credit named [unit], the luckiest so far when [best]. [already] when the account
/// had grabbed it before (a request sent twice, a page read before): [amount] is that share, nothing new was paid.
final class HongbaoGrabbed extends HongbaoOutcome {
  /// Constructor.
  const HongbaoGrabbed({required this.amount, required this.unit, required this.best, required this.already});

  /// The credits, as the forum wrote them.
  final String amount;

  /// The credit's name.
  final String unit;

  /// The luckiest share so far.
  final bool best;

  /// Grabbed before.
  final bool already;
}

/// The rest of the packet withdrawn: [refunded] credits went back to the sender.
final class HongbaoWithdrawn extends HongbaoOutcome {
  /// Constructor.
  const HongbaoWithdrawn(this.refunded);

  /// The credits refunded, as the forum wrote them.
  final String refunded;
}

/// Refused: [message] is the forum's words, [reason] the plugin's key for them (`badpw`, `done`, `needreply`…,
/// `error` for words it does not know; empty when it gave none).
final class HongbaoRefused extends HongbaoOutcome {
  /// Constructor.
  const HongbaoRefused({required this.message, required this.reason});

  /// The forum's words, or the app's when the forum gave none.
  final String message;

  /// The plugin's key.
  final String reason;

  /// The packet changed since the page was read (or the page is stale): the page read again shows how it is now.
  bool get reloads => const {
    'done',
    'withdrawn',
    'expired',
    'closed',
    'nopacket',
    'disabled',
    'claimed',
    'formhash',
    'ended',
  }.contains(reason);

  /// A wrong password, which may be tried again.
  bool get badPassword => reason == 'badpw';
}

/// No verdict: the request failed, or the forum answered something else than the plugin's result (a web page, the
/// forum's 503 of a stale form hash, an older plugin). It may have been done all the same: only the page read again
/// tells.
final class HongbaoUnknown extends HongbaoOutcome {
  /// Constructor.
  const HongbaoUnknown();
}

/// The outcome of the forum's answer [data] to grabbing (`hongbao_grab`) or withdrawing (`hongbao_withdraw`): the
/// plugin's `handle` result of its own JSON ([tsdmAppWriteResultOf]); anything else tells nothing.
HongbaoOutcome hongbaoOutcomeOf(Object? data, {required bool withdraw}) {
  final result = tsdmAppWriteResultOf(data);
  if (result == null ||
      result.kind != TsdmAppWriteKind.handle ||
      result.handleKey != (withdraw ? 'hongbao_withdraw' : 'hongbao_grab')) {
    return const HongbaoUnknown();
  }
  final values = result.values;
  if (!result.succeeded) {
    return HongbaoRefused(
      message: result.reason.isEmpty ? t.specialThread.refused : result.reason,
      reason: values['reason'] ?? (result.login ? 'login' : ''),
    );
  }
  if (withdraw) {
    return HongbaoWithdrawn(values['refunded'] ?? '');
  }
  return HongbaoGrabbed(
    amount: values['amount'] ?? '',
    unit: values['unit'] ?? '',
    best: values['best'] == '1',
    already: values['already'] == '1',
  );
}

/// One share grabbed, in the records of a red packet.
final class HongbaoRecord {
  /// Constructor.
  const HongbaoRecord({
    required this.uid,
    required this.username,
    required this.avatar,
    required this.amount,
    required this.time,
    required this.best,
  });

  /// Who grabbed it, 0 when unknown.
  final int uid;

  /// Their name when they grabbed it.
  final String username;

  /// Their avatar (absolute), null when none.
  final String? avatar;

  /// The credits.
  final int amount;

  /// When, as the forum's wall clock.
  final DateTime? time;

  /// The luckiest share.
  final bool best;
}

/// The records of a red packet as the forum answered them ([hongbaoRecordsOf]).
sealed class HongbaoRecordsOutcome {
  const HongbaoRecordsOutcome();
}

/// The shares grabbed, oldest first, out of [shares].
final class HongbaoRecords extends HongbaoRecordsOutcome {
  /// Constructor.
  const HongbaoRecords({required this.records, required this.shares, required this.credit});

  /// The shares grabbed.
  final List<HongbaoRecord> records;

  /// How many shares the packet has.
  final int shares;

  /// The credit it is paid in.
  final SpecialCredit? credit;
}

/// The forum refused to show them: [message] is its words.
final class HongbaoRecordsRefused extends HongbaoRecordsOutcome {
  /// Constructor.
  const HongbaoRecordsRefused(this.message);

  /// The forum's words.
  final String message;
}

/// Nothing to read: the request failed, or the answer is not the plugin's records.
final class HongbaoRecordsFailed extends HongbaoRecordsOutcome {
  /// Constructor.
  const HongbaoRecordsFailed();
}

/// The records of a red packet in the forum's answer [data] (plugin 3.5.0, `type: hongbao_record`, `schema: 19`),
/// times as the forum's wall clock with [timeOffset] (the thread page's: the records answer has none); the forum's
/// message (`ok` 0, `error: message`) is a refusal.
HongbaoRecordsOutcome hongbaoRecordsOf(Object? data, {num timeOffset = 8}) {
  final json = tsdmAppAnswerJson(data);
  if (json == null) {
    return const HongbaoRecordsFailed();
  }
  if (json['ok'] == 0 && json['error'] == 'message') {
    final message = tsdmAppText(json['message']);
    return HongbaoRecordsRefused(message.isEmpty ? t.specialThread.refused : message);
  }
  final schema = json['schema'];
  if (json['ok'] != 1 || json['type'] != 'hongbao_record' || schema is! num || schema < 19) {
    return const HongbaoRecordsFailed();
  }
  final list = json['records'] is List ? json['records'] as List : const <Object?>[];
  final credit = json['credit'];
  return HongbaoRecords(
    shares: tsdmAppInt(json['shares']),
    credit: SpecialCredit.fromApi(credit),
    records: [
      for (final r in list.whereType<Map<String, dynamic>>())
        HongbaoRecord(
          uid: tsdmAppInt(r['uid']),
          username: tsdmAppText(r['username']),
          avatar: switch (tsdmAppText(r['avatar'])) {
            '' => null,
            final url => url,
          },
          amount: tsdmAppInt(r['amount']),
          time: tsdmAppWallClockTime(r['dateline'], timeOffset),
          best: tsdmAppInt(r['best']) == 1,
        ),
    ],
  );
}

/// Grabs a share of the red packet of a thread, withdraws it, reads its records (the hongbao plugin's endpoints, with
/// the result of the forum's app API, plugin 3.5.0). A grab or a withdrawal is sent once (no automatic retry of a
/// write).
final class HongbaoRepository {
  /// Constructor; [post] and [get] are the transport (tests inject their own).
  const HongbaoRepository({required this.post, required this.get});

  /// The app's client: a POST through [NetClientProvider.postForm] (which adds the result parameter) sent once, the
  /// records read in the JSON mode.
  factory HongbaoRepository.network(NetClientProvider client) => HongbaoRepository(
    post: (url, fields) async => switch (await client.postForm(url, data: fields, singleAttempt: true).run()) {
      Right(:final value) => value.data,
      Left(:final value) => throw value,
    },
    get: (url) async => switch (await client.get(withTsdmAppJson(url)).run()) {
      Right(:final value) => value.data,
      Left(:final value) => throw value,
    },
  );

  /// Post a form, return the forum's answer; throws when the request failed.
  final Future<Object?> Function(String url, Map<String, String> fields) post;

  /// Read a page, return the forum's answer; throws when the request failed.
  final Future<Object?> Function(String url) get;

  /// Send [request] (a grab when not [withdraw]) and tell what the forum answered.
  Future<HongbaoOutcome> submit(SpecialRequest request, {required bool withdraw}) async {
    final Object? data;
    try {
      data = await post(request.url, request.fields);
    } on Exception catch (e) {
      talker.warning('hongbao action failed: $request: $e');
      return const HongbaoUnknown();
    }
    return hongbaoOutcomeOf(data, withdraw: withdraw);
  }

  /// Read the records of [url] ([HongbaoSpecial.recordsUrl]).
  Future<HongbaoRecordsOutcome> records(String url, {num timeOffset = 8}) async {
    final Object? data;
    try {
      data = await get(url);
    } on Exception catch (e) {
      talker.warning('hongbao records failed: $url: $e');
      return const HongbaoRecordsFailed();
    }
    return hongbaoRecordsOf(data, timeOffset: timeOffset);
  }
}
