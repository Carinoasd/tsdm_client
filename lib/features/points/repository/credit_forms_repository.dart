import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/points/models/credit_forms.dart';
import 'package:tsdm_client/features/tsdmapp/small_form.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/features/tsdmapp/v4.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';

/// What [CreditFormsRepository.fetchTransfer] or [CreditFormsRepository.fetchExchange] found for a form.
sealed class CreditFormAnswer<T> {
  const CreditFormAnswer();
}

/// The form, as fields.
final class CreditFormReady<T> extends CreditFormAnswer<T> {
  /// Constructor.
  const CreditFormReady(this.form);

  /// The form.
  final T form;
}

/// The forum's message instead of the form (switched off, not allowed for the account's group, log in).
final class CreditFormMessage<T> extends CreditFormAnswer<T> {
  /// Constructor.
  const CreditFormMessage(this.message);

  /// The message, plain text.
  final String message;
}

/// No form as fields (a plugin before 4.1.0, an answer that is not the page): the web page is the way.
final class CreditFormWebOnly<T> extends CreditFormAnswer<T> {
  /// Constructor.
  const CreditFormWebOnly();
}

/// Reads the transfer and the exchange forms of the credits of plugin 4.1.0 (`credit_transfer`, `schema` 72;
/// `credit_exchange`, `schema` 73) and posts them back to the forum, once each.
///
/// The forms are asked only when the last `status` named them (`credit_forms: 1`, [TsdmAppV4.creditForms]); without
/// it nothing is asked and the web page is the way. A write is never sent again by itself, the login password is only
/// in the body of its request: never kept, never logged.
final class CreditFormsRepository {
  /// Constructor; tests inject the client and the account.
  CreditFormsRepository({NetClientProvider? client, this.currentUid}) : _client = client;

  final NetClientProvider? _client;

  /// The account the forms are asked for, the one logged in when null.
  final int Function()? currentUid;

  NetClientProvider get _net => _client ?? getIt.get<NetClientProvider>();

  int get _uid => (currentUid ?? currentLoginUid)();

  /// The transfer form.
  AsyncEither<CreditFormAnswer<CreditTransferForm>> fetchTransfer() =>
      _fetch(CreditFormKind.transfer, (json, uid) => CreditTransferForm.fromJson(json, uid: uid));

  /// The exchange form; one with nothing to exchange (no two different credits) is left to the web page, which also
  /// offers the exchanges with the user center's other applications.
  AsyncEither<CreditFormAnswer<CreditExchangeForm>> fetchExchange() => _fetch(
    CreditFormKind.exchange,
    (json, uid) => switch (CreditExchangeForm.fromJson(json, uid: uid)) {
      final form? when form.usable => form,
      _ => null,
    },
  );

  AsyncEither<CreditFormAnswer<T>> _fetch<T>(
    CreditFormKind kind,
    T? Function(Map<String, dynamic> json, int uid) parse,
  ) => AsyncEither(() async {
    final client = _net;
    await TsdmAppApi.ensureStatus(client);
    if (!TsdmAppV4.creditForms) {
      return right(CreditFormWebOnly<T>());
    }
    final uid = _uid;
    switch (await fetchTsdmAppV4Page(client, kind.pageUrl, type: kind.type, schema: kind.schema, uid: uid).run()) {
      case Left(:final value):
        return left(value);
      case Right(value: TsdmAppV4Page(:final json)):
        return right(switch (parse(json, uid)) {
          final form? => CreditFormReady(form),
          null => CreditFormWebOnly<T>(),
        });
      case Right(value: TsdmAppV4Message(:final reason)) when reason.isNotEmpty:
        return right(CreditFormMessage<T>(reason));
      case Right(value: TsdmAppV4Refused(:final message)) when message.isNotEmpty:
        return right(CreditFormMessage<T>(message));
      case Right():
        return right(CreditFormWebOnly<T>());
    }
  });

  /// Send the transfer of [form] once.
  Future<CreditFormOutcome> transfer(
    CreditTransferForm form, {
    required String to,
    required int amount,
    required String message,
    required String password,
  }) => _post(
    CreditFormKind.transfer,
    form.uid,
    form.body(to: to, amount: amount, message: message, password: password),
  );

  /// Send the exchange of [form] once.
  Future<CreditFormOutcome> exchange(
    CreditExchangeForm form, {
    required ExchangeCredit target,
    required ExchangeCredit source,
    required int amount,
    required String password,
  }) => _post(
    CreditFormKind.exchange,
    form.uid,
    form.body(target: target, source: source, amount: amount, password: password),
  );

  Future<CreditFormOutcome> _post(CreditFormKind kind, int servedUid, Map<String, String> body) async {
    if (_uid != servedUid) {
      return const CreditFormAccountChanged();
    }
    switch (await postTsdmAppV4(_net, kind.submitUrl, body).run()) {
      case Left(value: HttpHandshakeFailedException(statusCode: 503) || HttpRequestFailedException(statusCode: 503)):
        // The forum refuses a wrong formhash with its 503 page before it looks at anything else.
        return const CreditFormExpired();
      case Left(:final value):
        // The url and the kind only: the body carries the password.
        talker.warning('credit ${kind.op} failed: ${kind.submitUrl}: ${value.runtimeType}');
        return const CreditFormUnknown();
      case Right(:final value):
        return creditFormOutcomeOf(kind, value, servedUid: servedUid);
    }
  }
}

/// The outcome of the answer [data] of form [kind] posted for account [servedUid]: done only for the success key of
/// [kind] (whatever `ok` says), refused for any other key the forum names (it checks all of them before it takes
/// anything), unknown for anything else.
CreditFormOutcome creditFormOutcomeOf(CreditFormKind kind, Object? data, {required int servedUid}) {
  final result = switch (tsdmAppV4WriteOutcomeOf(data)) {
    TsdmAppV4Written(:final result) => result,
    _ => null,
  };
  if (result == null) {
    return const CreditFormUnknown();
  }
  if (result.uid != servedUid) {
    return const CreditFormAccountChanged();
  }
  final key = result.messageKey;
  if (key == kind.successKey) {
    return const CreditFormDone();
  }
  if (key.isEmpty) {
    return const CreditFormUnknown();
  }
  return CreditFormRefused(messageKey: key, message: result.reason);
}
