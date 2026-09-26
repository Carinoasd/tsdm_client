import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/features/authentication/utils/logged_user_parser.dart';
import 'package:tsdm_client/features/bank/models/bank_data.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

/// Bank access bound to one network client's account. Never retries a POST.
class BankRepository {
  /// Injected transports allow transactions to be tested without a live account.
  BankRepository({required this.getPage, required this.postForm});

  /// Uses the existing account-bound client and string-only Android form encoding.
  factory BankRepository.network(NetClientProvider client) => BankRepository(
    getPage: (url) async => switch (await client.get(url).run()) {
      Right(:final value) => value.data as String,
      Left(:final value) => throw value,
    },
    postForm: (url, body) async => switch (await client.postForm(url, data: body, singleAttempt: true).run()) {
      Right(:final value) => value.data as String,
      Left(:final value) => throw value,
    },
  );

  /// Reads bank pages only.
  final Future<String> Function(String url) getPage;

  /// Sends one explicitly confirmed transaction.
  final Future<String> Function(String url, Map<String, String> body) postForm;

  Future<uh.Document> _fetch(String url, int uid) async {
    if (uid <= 0) throw const FormatException('Bank login required');
    final document = parseHtmlDocument(await getPage(url));
    if (parseLoggedUidFromDocument(document) != uid) {
      throw const FormatException('Bank identity not verified');
    }
    return document;
  }

  /// Fetches banks for the authenticated account, including membership markers.
  Future<BankDirectory> fetchDirectory(int uid) async => parseBankDirectory(await _fetch(bankPageUrl(), uid));

  /// Loads balances and a fresh form without changing the account.
  Future<BankSavings> fetchSavings(int bankId, int uid) async => parseBankSavings(
    await _fetch(bankPageUrl(bankId: bankId, action: 'cur'), uid),
    bankId: bankId,
  );

  /// Retrieves one page of records; IP addresses are deliberately not retained.
  Future<BankLogs> fetchLogs(int bankId, int uid, {bool received = false, int page = 1}) async => parseBankLogs(
    await _fetch(bankPageUrl(bankId: bankId, action: 'log', received: received, page: page), uid),
    bankId: bankId,
    received: received,
    page: page,
  );

  /// A response, including HTTP 200, is not evidence that a transaction succeeded.
  /// The caller must show an unconfirmed result and refresh via GET only.
  Future<void> submit(BankTransactionForm form, BankOperation operation, String amount, String password) async {
    await postForm(form.action, form.body(operation, amount, password));
  }
}
