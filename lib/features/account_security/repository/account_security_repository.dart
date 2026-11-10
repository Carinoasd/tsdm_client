import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/account_security/models/account_security.dart';
import 'package:tsdm_client/features/account_security/utils/account_security_parser.dart';
import 'package:tsdm_client/features/blocking/repository/notice_ignore_repository.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:universal_html/parsing.dart';

/// How opening a way of the account center ended.
sealed class AccountOpenResult {
  const AccountOpenResult();
}

/// The way's form, signed for this session.
final class AccountOpenForm extends AccountOpenResult {
  /// Constructor.
  const AccountOpenForm(this.form);

  /// The form.
  final AccountMethodForm form;
}

/// The forum asks for the current password first, and none was given.
final class AccountOpenNeedsPassword extends AccountOpenResult {
  /// Constructor.
  const AccountOpenNeedsPassword();
}

/// The forum only offers another check (the email or the phone code): only its web page does it.
final class AccountOpenOtherCheck extends AccountOpenResult {
  /// Constructor.
  const AccountOpenOtherCheck();
}

/// Not opened: the forum's [message] (the current password is wrong…), empty when the request failed or the answer
/// was not understood.
final class AccountOpenFailed extends AccountOpenResult {
  /// Constructor.
  const AccountOpenFailed([this.message = '']);

  /// The forum's message.
  final String message;
}

/// How posting a way's form ended.
sealed class AccountSubmitResult {
  const AccountSubmitResult();
}

/// Changed; [message] is the forum's (`修改成功`).
final class AccountSubmitDone extends AccountSubmitResult {
  /// Constructor.
  const AccountSubmitDone(this.message);

  /// The forum's message.
  final String message;
}

/// Refused: the forum's [message] (the passwords differ, the email is taken…).
final class AccountSubmitRefused extends AccountSubmitResult {
  /// Constructor.
  const AccountSubmitRefused(this.message);

  /// The forum's message.
  final String message;
}

/// Not known: the request failed after it may have reached the forum, or the answer was not understood.
final class AccountSubmitUnknown extends AccountSubmitResult {
  /// Constructor.
  const AccountSubmitUnknown();
}

/// The privacy settings of an account: the tabs the app shows, each with its form (null when the app can not save
/// it).
typedef PrivacySettings = List<({PrivacyTab tab, PrivacySection? section})>;

/// The account center (password, security question, email) and the privacy page of an account.
///
/// Every call is for one account: the client is built for it ([NetClientProvider.build]), and once another account is
/// in use its answers are dropped and the call fails. The writes are sent once (`singleAttempt`), only when the user
/// asked for them. No password, answer or email is ever logged: they only travel in the body of the posts.
final class AccountSecurityRepository with LoggerMixin {
  /// Constructor; [buildClient] builds the client of an account.
  AccountSecurityRepository({NetClientProvider Function(int uid)? buildClient})
    : _buildClient = buildClient ?? _clientOf;

  static NetClientProvider _clientOf(int uid) =>
      NetClientProvider.build(userLoginInfo: UserLoginInfo(username: null, uid: uid));

  final NetClientProvider Function(int uid) _buildClient;

  Future<String?> _read(NetClientProvider client, String url) async {
    switch (await client.get(url, options: pageReadOptions()).run()) {
      case Left(:final value):
        error('failed to read an account page: $value');
        return null;
      case Right(:final value) when value.statusCode != 200 || value.data is! String:
        error('account page answered ${value.statusCode}');
        return null;
      case Right(:final value):
        return value.data as String;
    }
  }

  /// The rows of the account center of [uid], null when it could not be read.
  Future<AccountSecurityOverview?> overview(int uid) async {
    final raw = await _read(_buildClient(uid), accountCenterUrl);
    if (raw == null) {
      return null;
    }
    final parsed = parseAccountOverview(raw, expectedUid: uid);
    if (parsed == null) {
      warning('account center page not understood');
    }
    return parsed;
  }

  Future<AccountStep> _step(NetClientProvider client, Uri url, AccountMethod method) async {
    final raw = await _read(client, asAccountFloat(url).toString());
    return raw == null ? const AccountStepUnknown() : parseAccountStep(raw, method: method);
  }

  /// Open [method] for [uid] with the form hash [formHash] of the account center: the forum's form of the way.
  ///
  /// When the forum asks for the current password first, it is checked with [currentPassword]; without it the answer
  /// is [AccountOpenNeedsPassword] and nothing is posted.
  Future<AccountOpenResult> open(
    int uid,
    AccountMethod method, {
    required String formHash,
    String? currentPassword,
  }) async {
    final client = _buildClient(uid);
    var step = await _step(client, Uri.parse(accountMethodOpenUrl(method, formHash)), method);
    if (step case AccountStepChoose(:final password?)) {
      if (currentPassword == null) {
        return const AccountOpenNeedsPassword();
      }
      step = await _step(client, password, method);
    }
    if (step case AccountStepVerify(:final form)) {
      if (currentPassword == null) {
        return const AccountOpenNeedsPassword();
      }
      step = await _verify(client, form, method, currentPassword);
    }
    if (step case AccountStepSigned(:final url)) {
      step = await _step(client, url, method);
    }
    return switch (step) {
      AccountStepForm(:final form) => AccountOpenForm(form),
      AccountStepChoose() => const AccountOpenOtherCheck(),
      AccountStepMessage(:final text) => AccountOpenFailed(text),
      AccountStepSigned() || AccountStepVerify() || AccountStepUnknown() => const AccountOpenFailed(),
    };
  }

  /// Post the current password [password] to the check [form]: the forum answers the signed link of the way's form,
  /// or its refusal. Posted as it is: the result of the app API leaves the link out.
  Future<AccountStep> _verify(
    NetClientProvider client,
    AccountVerifyForm form,
    AccountMethod method,
    String password,
  ) async {
    final data = formDataOf([...form.hidden, ('password', password)]);
    if (data == null) {
      return const AccountStepUnknown();
    }
    final resp = await client
        .postForm(asAccountFloat(form.action).toString(), data: data, singleAttempt: true, tsdmAppJson: false)
        .run();
    switch (resp) {
      case Left(:final value):
        error('account check failed: ${value.runtimeType}');
        return const AccountStepUnknown();
      case Right(:final value) when value.data is String:
        return parseAccountStep(value.data as String, method: method);
      case Right():
        return const AccountStepUnknown();
    }
  }

  /// Post [form] of [uid] with the user's [values] (field name to value).
  Future<AccountSubmitResult> submit(int uid, AccountMethodForm form, Map<String, String> values) async {
    final data = formDataOf([
      ...form.hidden,
      for (final f in form.fields) (f.name, values[f.name] ?? ''),
    ]);
    if (data == null) {
      return const AccountSubmitUnknown();
    }
    final resp = await _buildClient(
      uid,
    ).postForm(asAccountFloat(form.action).toString(), data: data, singleAttempt: true).run();
    switch (resp) {
      case Left(:final value):
        // The request may have reached the forum: do not claim either outcome.
        error('account form of ${form.method.method} failed, result unknown: ${value.runtimeType}');
        return const AccountSubmitUnknown();
      case Right(:final value):
        final result = tsdmAppWriteResultOf(value.data);
        if (result != null) {
          if (result.messageKey == 'account_change_success') {
            return AccountSubmitDone(result.message);
          }
          final text = result.message.isNotEmpty
              ? result.message
              : (parseHtmlDocument(result.documentHtml).body?.text ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
          info('account form of ${form.method.method} answered ${result.messageKey}');
          return text.isEmpty ? const AccountSubmitUnknown() : AccountSubmitRefused(text);
        }
        if (value.data is! String) {
          return const AccountSubmitUnknown();
        }
        return switch (parseAccountStep(value.data as String, method: form.method)) {
          AccountStepMessage(:final text, success: true) => AccountSubmitDone(text),
          AccountStepMessage(:final text) => AccountSubmitRefused(text),
          _ => const AccountSubmitUnknown(),
        };
    }
  }

  /// The privacy settings of [uid]: the tabs the forum lists (but the ignore filter), each read from its own page.
  /// Null when the first page could not be read.
  Future<PrivacySettings?> privacy(int uid) async {
    final client = _buildClient(uid);
    final first = await _readPrivacy(client, uid, 'base');
    if (first == null) {
      return null;
    }
    final out = <({PrivacyTab tab, PrivacySection? section})>[];
    for (final tab in first.tabs) {
      if (tab.op == 'base') {
        out.add((tab: tab, section: first.section));
        continue;
      }
      final page = await _readPrivacy(client, uid, tab.op);
      if (page == null) {
        return null;
      }
      out.add((tab: tab, section: page.section));
    }
    return out;
  }

  Future<({List<PrivacyTab> tabs, PrivacySection? section})?> _readPrivacy(
    NetClientProvider client,
    int uid,
    String op,
  ) async {
    final raw = await _read(client, privacyPageUrl(op));
    if (raw == null) {
      return null;
    }
    final parsed = parsePrivacyPage(raw, expectedUid: uid, op: op);
    if (parsed == null) {
      warning('privacy page $op not understood');
    }
    return parsed;
  }

  /// Save [section] of [uid]: the whole tab, as the forum replaces it. True when the forum took it (its result
  /// `do_success`, or the redirect it answers a form it handled with).
  Future<bool> savePrivacy(int uid, PrivacySection section) async {
    final data = formDataOf(section.pairs);
    if (data == null) {
      return false;
    }
    final resp = await _buildClient(uid).postForm(section.action.toString(), data: data, singleAttempt: true).run();
    switch (resp) {
      case Left(value: HttpHandshakeFailedException(statusCode: 301 || 302 || 303)):
        // The forum's redirect after it handled the form, not followed for a single attempt. A redirect to the login
        // page is taken the same way: the caller reads the tabs again and goes by what the forum has.
        return true;
      case Left(:final value):
        error('privacy tab ${section.tab.op} failed: ${value.runtimeType}');
        return false;
      case Right(:final value):
        final result = tsdmAppWriteResultOf(value.data);
        if (result != null) {
          return result.messageKey == 'do_success' || (result.kind == TsdmAppWriteKind.redirect && result.succeeded);
        }
        if (value.data case final String raw) {
          final doc = parseHtmlDocument(raw);
          return doc.querySelector('#messagetext.alert_right, div.alert_right') != null;
        }
        return false;
    }
  }
}
