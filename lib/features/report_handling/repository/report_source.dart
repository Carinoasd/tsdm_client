import 'dart:io' if (dart.libaray.js) 'package:web/web.dart';

import 'package:flutter/widgets.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/moderate/models/moderate_posts.dart';
import 'package:tsdm_client/features/moderate/repository/modcp_repository.dart';
import 'package:tsdm_client/features/moderate/repository/moderate_repository.dart';
import 'package:tsdm_client/features/moderate/widgets/moderate_panel_login.dart';
import 'package:tsdm_client/features/report_handling/models/report_handling.dart';
import 'package:tsdm_client/features/tsdmapp/small_form.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:universal_html/html.dart' as uh;

/// Where the reports come from and how they are handled: the page lists and handles them the same way whichever it is.
abstract interface class ReportSource {
  /// Page [page] of the part [scope] (empty: none chosen yet).
  Future<Either<AppException, ReportAnswer>> load({String scope = '', int page = 1});

  /// Handle [decisions] of [list], once.
  Future<Either<AppException, ReportOutcome>> resolve(ReportList list, List<ReportDecision> decisions);

  /// The login asked by [need], calling [onLoggedIn] once logged in.
  Widget loginView(ReportNeedsLogin need, Future<void> Function() onLoggedIn);
}

/// The reports of the moderation panel (`forum.php?mod=modcp&action=report`) in the JSON mode of the forum's app API
/// (plugin 3.9.0, `type: modcp_report`): one forum at a time, the panel's password asked as the panel asks it, the
/// panel's own form posted back as it describes it.
///
/// Bound to the account logged in, as [ModcpRepository]: an answer served to another account, or an account changed
/// meanwhile, is an [IdentityChangedException]; a form is never posted once the account changed.
final class ModcpReportSource implements ReportSource {
  /// Constructor; transports are injected so the flow is tested without the forum.
  ModcpReportSource({
    required this.panel,
    required ModerateGet get,
    required ModeratePost post,
    int Function()? currentUid,
  }) : _get = get,
       _post = post,
       _currentUid = currentUid ?? currentLoginUid;

  /// Uses the app's client, with the panel [panel] (its login).
  factory ModcpReportSource.network(ModcpRepository panel) => ModcpReportSource(
    panel: panel,
    get: (url) async => switch (await getIt.get<NetClientProvider>().get(url).run()) {
      Left(:final value) => left(value),
      Right(:final value) => right((statusCode: value.statusCode ?? 0, data: value.data)),
    },
    post: (url, body) async =>
        switch (await getIt.get<NetClientProvider>().postForm(url, data: body, singleAttempt: true).run()) {
          Left(:final value) => left(value),
          Right(:final value) => right((statusCode: value.statusCode ?? 0, data: value.data)),
        },
  );

  /// The panel, for its login.
  final ModcpRepository panel;

  final ModerateGet _get;
  final ModeratePost _post;
  final int Function() _currentUid;

  /// The url of page [page] of forum [fid] (0: none, the forums offered only).
  static String url({int fid = 0, int page = 1}) => withTsdmAppJson(
    '$baseUrl/forum.php?mod=modcp&action=report${fid > 0 ? '&fid=$fid' : ''}${page > 1 ? '&page=$page' : ''}',
  );

  @override
  Future<Either<AppException, ReportAnswer>> load({String scope = '', int page = 1}) async {
    final uid = _currentUid();
    if (uid <= 0) {
      return left(IdentityChangedException());
    }
    final fid = int.tryParse(scope) ?? 0;
    switch (await _get(url(fid: fid, page: page))) {
      case Left(:final value):
        return left(value);
      case Right(:final value) when value.statusCode != HttpStatus.ok:
        return left(HttpRequestFailedException(value.statusCode));
      case Right(:final value):
        if (_currentUid() != uid) {
          return left(IdentityChangedException());
        }
        return answerOf(value.data, uid: uid);
    }
  }

  /// The report page in answer [data], asked by account [uid]:
  ///
  /// * the page as fields (`type: modcp_report`, `schema` 28);
  /// * the forum's message instead of the panel (`error: message`: a guest, a member without the panel, the panel
  ///   locked) is its refusal in its words;
  /// * the panel's own page in the answer's `document` (`error: modcp_login`, its login form) asks the login;
  /// * anything else (an older plugin's web page) is not read: the entry is offered on plugin 3.9.0 only.
  static Either<AppException, ReportAnswer> answerOf(Object? data, {required int uid}) {
    final json = tsdmAppAnswerJson(data);
    if (json == null) {
      return left(HttpRequestFailedException(HttpStatus.ok));
    }
    if (json['uid'] is num && tsdmAppInt(json['uid']) != uid) {
      // The forum's login ended (the app's account is the same): its login prompt, not another account.
      if (tsdmAppInt(json['uid']) == 0 && json['error'] == 'message' && tsdmAppInt(json['login']) == 1) {
        return right(ReportRefused(tsdmAppText(json['message']).trim()));
      }
      return left(IdentityChangedException());
    }
    if (modcpReportFromApi(json) case final list?) {
      return list.uid == uid ? right(ReportReady(list)) : left(IdentityChangedException());
    }
    if (json['ok'] == 0 && json['error'] == 'message') {
      return right(ReportRefused(tsdmAppText(json['message']).trim()));
    }
    if (json['document'] is String) {
      final doc = tsdmAppPageDocument(json);
      if (moderatePageUid(doc) case final served? when served != uid) {
        return left(IdentityChangedException());
      }
      if (moderatePanelLoginFormHash(doc) case final formHash?) {
        return right(ReportNeedsLogin(formHash));
      }
      return right(ReportRefused(moderatePageMessage(doc)));
    }
    return left(HttpRequestFailedException(HttpStatus.ok));
  }

  @override
  Future<Either<AppException, ReportOutcome>> resolve(ReportList list, List<ReportDecision> decisions) async {
    final uid = _currentUid();
    if (list is! ModcpReportList || list.form == null || decisions.isEmpty) {
      return right(const ReportNotDone(''));
    }
    if (uid <= 0 || list.uid != uid) {
      return left(IdentityChangedException());
    }
    final body = list.form!.body(decisions, withReward: list.reward != null);
    switch (await _post(list.form!.url, body)) {
      case Left(:final value):
        return left(value);
      case Right(:final value) when value.statusCode != HttpStatus.ok:
        return left(HttpRequestFailedException(value.statusCode));
      case Right(:final value):
        if (_currentUid() != uid) {
          return left(IdentityChangedException());
        }
        return outcomeOf(value.data, uid: uid);
    }
  }

  /// The outcome in the answer [data] to a handling sent by account [uid] (a write result, `schema` 13): done only for
  /// the panel's `modcp_report_success`; the panel's login page (its session ended) did nothing; any other message is
  /// the panel's refusal (a reward out of range stops the batch at that report: those before it were handled).
  static Either<AppException, ReportOutcome> outcomeOf(Object? data, {required int uid}) {
    final result = tsdmAppWriteResultOf(data);
    if (result == null) {
      return right(const ReportUnknown());
    }
    if (result.uid != uid) {
      // The forum's login ended: nothing was done, its login prompt is the reason.
      if (result.uid == 0 && result.login) {
        return right(ReportNotDone(result.reason.trim()));
      }
      return left(IdentityChangedException());
    }
    if (result.messageKey == 'modcp_report_success') {
      return right(ReportDone(result.message.trim()));
    }
    switch (result.kind) {
      case TsdmAppWriteKind.page:
        final uh.Document doc = result.document;
        if (moderatePanelLoginFormHash(doc) != null) {
          return right(const ReportSessionEnded());
        }
        final message = moderatePageMessage(doc);
        return right(message.isEmpty ? const ReportUnknown() : ReportNotDone(message));
      case TsdmAppWriteKind.redirect when !result.login:
        return right(const ReportUnknown());
      case _:
        return right(ReportNotDone(result.reason.trim()));
    }
  }

  @override
  Widget loginView(ReportNeedsLogin need, Future<void> Function() onLoggedIn) => ModeratePanelLoginView(
    login: (password) => panel.loginPanel(formHash: need.token, password: password),
    onLoggedIn: onLoggedIn,
  );
}
