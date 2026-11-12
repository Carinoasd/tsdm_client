import 'package:flutter/widgets.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/admin_tools/models/admin_models.dart';
import 'package:tsdm_client/features/admin_tools/repository/admin_repository.dart';
import 'package:tsdm_client/features/admin_tools/widgets/admin_widgets.dart';
import 'package:tsdm_client/features/report_handling/models/report_handling.dart';
import 'package:tsdm_client/features/report_handling/repository/report_source.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';

/// The reports of the whole forum through the forum's admin actions (`adminreport`, plugin 3.9.0, `schema` 29): the
/// ones waiting and the ones handled, handled (`op=resolve`) and deleted (`op=delete`) with the admin token, the
/// second login asked through [reauth] when the forum asks it.
///
/// Every write is sent once with an `opid`: the same one while the same handling is sent again after a failed request,
/// `busy` or a second login not finished; a new one otherwise. `duplicate` is a handling the forum did already.
final class AdminReportSource implements ReportSource {
  /// Constructor.
  AdminReportSource({required this.repository, required this.writable, this.reauth});

  /// The admin actions' requests.
  final AdminRepository repository;

  /// The account may post `adminreport` (`write` 1): handling and deleting offered.
  final bool writable;

  /// The second login, when the forum asks it.
  final AdminReauth? reauth;

  /// The write being sent (its fields) and its `opid`, kept while the same one is sent again.
  String? _opKey;
  String? _opId;

  /// The lists, in the order of the tabs.
  static const scopes = <ReportScope>[
    (key: AdminReportScopes.pending, label: AdminReportScopes.pending),
    (key: AdminReportScopes.resolved, label: AdminReportScopes.resolved),
  ];

  @override
  Future<Either<AppException, ReportAnswer>> load({String scope = '', int page = 1}) async {
    final reply = await repository.request(
      AdminActions.report,
      query: {
        'op': scope == AdminReportScopes.resolved ? AdminReportScopes.resolved : AdminReportScopes.pending,
        if (page > 1) 'page': '$page',
      },
      reauth: reauth,
    );
    return answerOf(reply, writable: writable);
  }

  /// The list in [reply]; the forum's refusal in the app's words otherwise.
  static Either<AppException, ReportAnswer> answerOf(AdminReply reply, {required bool writable}) {
    if (reply.identityChanged) {
      return left(IdentityChangedException());
    }
    if (adminReportFromApi(reply.json, writable: writable, scopes: scopes) case final list?) {
      return right(ReportReady(list));
    }
    return right(ReportRefused('', describe: (context) => adminErrorText(context, reply)));
  }

  @override
  Future<Either<AppException, ReportOutcome>> resolve(ReportList list, List<ReportDecision> decisions) async {
    if (list is! AdminReportList || !list.canResolve || decisions.isEmpty) {
      return right(const ReportNotDone(''));
    }
    return _write(list, resolveForm(decisions, withReward: list.reward != null));
  }

  @override
  Future<Either<AppException, ReportOutcome>> delete(ReportList list, List<ReportItem> items) async {
    if (list is! AdminReportList || !list.canDelete || items.isEmpty) {
      return right(const ReportNotDone(''));
    }
    return _write(list, deleteForm(items));
  }

  /// The form of `op=resolve` (without `formhash` and `opid`): the ids indexed, each reporter's reward and message
  /// only when [withReward] (the forum sets a reward) and not empty. The reporter is the forum's to tell.
  static Map<String, String> resolveForm(List<ReportDecision> decisions, {required bool withReward}) => {
    'op': 'resolve',
    for (final (i, d) in decisions.indexed) ...{
      'ids[$i]': '${d.item.id}',
      if (withReward && d.credit != 0) 'credits[${d.item.id}]': '${d.credit}',
      if (withReward && d.message.trim().isNotEmpty) 'msg[${d.item.id}]': d.message.trim(),
    },
  };

  /// The form of `op=delete` (without `formhash` and `opid`).
  static Map<String, String> deleteForm(List<ReportItem> items) => {
    'op': 'delete',
    for (final (i, item) in items.indexed) 'ids[$i]': '${item.id}',
  };

  Future<Either<AppException, ReportOutcome>> _write(AdminReportList list, Map<String, String> form) async {
    if (list.uid != repository.currentUid) {
      return left(IdentityChangedException());
    }
    final key = (form.entries.toList()..sort((a, b) => a.key.compareTo(b.key))).map((e) => '${e.key}=${e.value}');
    final opKey = key.join('&');
    if (_opKey != opKey || _opId == null) {
      _opKey = opKey;
      _opId = newAdminOpId();
    }
    final reply = await repository.request(AdminActions.report, form: {...form, 'opid': _opId!}, reauth: reauth);
    if (reply.identityChanged) {
      return left(IdentityChangedException());
    }
    final again = reply.json == null || reply.error == 'busy' || reply.error == 'admin_login';
    if (!again) {
      _opKey = null;
      _opId = null;
    }
    return right(outcomeOf(reply, op: form['op']!));
  }

  /// What became of a write [op] (`resolve`, `delete`) the forum answered with [reply].
  static ReportOutcome outcomeOf(AdminReply reply, {required String op}) {
    final json = reply.json;
    if (json == null) {
      return const ReportUnknown();
    }
    if (reply.error == 'duplicate') {
      // The same write was done already: the request before it went through.
      return ReportDone('', describe: (context) => context.t.adminTools.errorDuplicate);
    }
    if (reply.ok && json['op'] == op) {
      List<int> ids(String key) => [
        for (final v in (json[key] is List ? json[key] as List : const <Object?>[]))
          if (tsdmAppInt(v) > 0) tsdmAppInt(v),
      ];
      if (op == 'delete') {
        final deleted = ids('deleted').length;
        return ReportDone('', describe: (context) => context.t.reportHandling.deleted(n: deleted));
      }
      final skipped = ids('skipped').length;
      return ReportDone(
        '',
        describe: (context) => skipped == 0
            ? context.t.reportHandling.done
            : context.t.reportHandling.doneSkipped(n: ids('resolved').length, skipped: skipped),
      );
    }
    return ReportNotDone(
      '',
      describe: (context) => switch (reply.error) {
        'credits' => context.t.reportHandling.errorCredits(
          min: tsdmAppInt(json['min']),
          max: tsdmAppInt(json['max']),
        ),
        'msg' => context.t.reportHandling.errorMessage,
        'ids' => context.t.reportHandling.errorIds,
        _ => adminErrorText(context, reply),
      },
    );
  }

  /// The admin API asks no login of its own on the page: its second login is a dialog ([reauth]).
  @override
  Widget loginView(ReportNeedsLogin need, Future<void> Function() onLoggedIn) => const SizedBox.shrink();
}
