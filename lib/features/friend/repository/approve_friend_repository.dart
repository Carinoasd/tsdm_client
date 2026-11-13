import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/blocking/models/notice_ignore.dart';
import 'package:tsdm_client/features/blocking/repository/notice_ignore_repository.dart'
    show failureOfPageStatus, pageReadOptions;
import 'package:tsdm_client/features/friend/models/add_friend.dart';
import 'package:tsdm_client/features/friend/models/approve_friend.dart';
import 'package:tsdm_client/features/friend/utils/approve_friend_link.dart';
import 'package:tsdm_client/features/friend/utils/parse_approve_friend.dart';
import 'package:tsdm_client/features/tsdmapp/small_form.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/features/tsdmapp/v4.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/logger.dart';

/// HTTP 200, without `dart:io` so the repository also builds for the web.
const _httpOk = 200;

/// Approves pending friend requests, the way the "批准申请" link of a friend request notice does.
///
/// Every call takes the [NetClientProvider] of the account it acts for, built by [clientFor]: the client drops its
/// requests and answers once another account is current, so an approval can never go out as another account.
///
/// Nothing is retried: the approval is posted at most once per [approve] call, only with a form the forum served for
/// that member, and never to anything but [approveFriendSubmitUrl].
class ApproveFriendRepository with LoggerMixin {
  /// Constructor.
  const ApproveFriendRepository();

  /// A client bound to [user] for the whole approval.
  NetClientProvider clientFor(UserLoginInfo user) => NetClientProvider.build(userLoginInfo: user);

  /// Load the approval form of the friend request of [targetUid].
  ///
  /// Read with the write result of the forum's app API (plugin 2.6.0, [tsdmAppWriteResultOf]): a `page` with the
  /// form, or the refusal as a `handle`; an older plugin answers the AJAX fragment, parsed as before.
  ///
  /// Plugin 4.0.0 answers the window as a small form (`friendadd`, `mode: approve`, [approveFriendFormFromApi]) when
  /// its `status` lists it; anything else of it reads the window as above. [viewerUid] is the account of [client]: an
  /// answer served to another one is never used.
  Future<Either<ApproveFriendFailure, ApproveFriendFormResult>> fetchForm(
    NetClientProvider client, {
    required int targetUid,
    int? viewerUid,
  }) async {
    if (viewerUid != null) {
      await TsdmAppApi.ensureStatus(client);
      if (TsdmAppV4.has(TsdmAppV4Group.forms, SmallFormKind.friendadd.name)) {
        switch (await client
            .get(withTsdmAppV4Form(approveFriendFormUrl(targetUid)), options: pageReadOptions())
            .run()) {
          case Left(value: IdentityChangedException()):
            return left(ApproveFriendFailure.accountMismatch);
          case Right(:final value) when value.statusCode == _httpOk:
            try {
              if (approveFriendFormFromApi(value.data, targetUid: targetUid, viewerUid: viewerUid) case final form?) {
                return right(form);
              }
            } on ApproveFriendRejected catch (e) {
              error('approval form answer rejected: $e');
              return left(e.failure);
            }
          case _:
            // The window read as before tells a challenge from a network failure.
            break;
        }
      }
    }
    final resp = await client
        .get(withTsdmAppJsonWrite(approveFriendFormUrl(targetUid)), options: pageReadOptions())
        .run();
    switch (resp) {
      case Left(value: IdentityChangedException()):
        return left(ApproveFriendFailure.accountMismatch);
      case Left(:final value):
        error('failed to load the approval form: $value');
        return left(ApproveFriendFailure.network);
      case Right(:final value) when value.statusCode != _httpOk:
        final failure = failureOfPageStatus(value) == NoticeIgnoreFailure.challenge
            ? ApproveFriendFailure.challenge
            : ApproveFriendFailure.network;
        error('approval form answered ${value.statusCode}: $failure');
        return left(failure);
      case Right(:final value) when value.data is! String && tsdmAppWriteResultOf(value.data) == null:
        return left(ApproveFriendFailure.unknownForm);
      case Right(:final value):
        try {
          return right(parseApproveFriendForm(value.data, targetUid: targetUid));
        } on ApproveFriendRejected catch (e) {
          error('approval form rejected: $e');
          return left(e.failure);
        }
    }
  }

  /// Approve the request of [form] filing the new friend under [gid], one of the groups the form offered.
  ///
  /// Sends the hidden fields exactly as the forum served them plus the chosen group. The result is the forum's answer:
  /// a success only when the forum called the success handler of this form.
  Future<Either<ApproveFriendFailure, AddFriendResult>> approve(
    NetClientProvider client, {
    required ApproveFriendForm form,
    required String gid,
  }) async {
    if (!form.offers(gid)) {
      error('group $gid is not offered by the approval form, not sent');
      return left(ApproveFriendFailure.unknownForm);
    }
    final handleKey = form.field('handlekey');
    if (form.field('add2submit') != 'true' || (form.field('formhash') ?? '').isEmpty || handleKey == null) {
      return left(ApproveFriendFailure.unknownForm);
    }
    final data = <String, String>{
      for (final (name, value) in form.fields) name: value,
      'gid': gid,
    };
    if (form.fromApi) {
      // Plugin 4.0.0: posted once with the result parameters; `friends_add` is the forum's approval.
      return switch (await postTsdmAppV4(client, approveFriendSubmitUrl(form.targetUid), data).run()) {
        Left(value: IdentityChangedException()) => left(ApproveFriendFailure.accountMismatch),
        Left(value: HttpHandshakeFailedException(statusCode: 403 || 503, :final headers))
            when headers?.value('cf-mitigated')?.toLowerCase() == 'challenge' =>
          left(ApproveFriendFailure.challenge),
        Left() => left(ApproveFriendFailure.unknownAfterSubmit),
        Right(:final value) => approveFriendResultFromApi(value, targetUid: form.targetUid, viewerUid: form.viewerUid),
      };
    }
    final Object? raw;
    switch (await client.postForm(approveFriendSubmitUrl(form.targetUid), data: data).run()) {
      case Left(value: IdentityChangedException()):
        return left(ApproveFriendFailure.accountMismatch);
      case Left(value: HttpHandshakeFailedException(statusCode: 403 || 503, :final headers))
          when headers?.value('cf-mitigated')?.toLowerCase() == 'challenge':
        warning('approval stopped by a site challenge');
        return left(ApproveFriendFailure.challenge);
      case Left(:final value):
        // The request may have reached the forum: do not claim either outcome.
        error('approval failed, result unknown: $value');
        return left(ApproveFriendFailure.unknownAfterSubmit);
      case Right(:final value):
        raw = value.data;
    }
    if (raw is! String && tsdmAppWriteResultOf(raw) == null) {
      return left(ApproveFriendFailure.unknownAfterSubmit);
    }
    try {
      return right(parseApproveFriendResult(raw, handleKey: handleKey, targetUid: form.targetUid));
    } on ApproveFriendRejected catch (e) {
      warning('approval answer rejected: $e');
      return left(e.failure);
    }
  }
}

/// The approval window of plugin 4.0.0 [data] (small form `friendadd`, `mode: approve`) of the request of [targetUid],
/// served to [viewerUid]: the form, checked as the web window is (posting to that member's approval with
/// `add2submit`, a `formhash` and a `handlekey`, offering groups), or the forum's refusal (no such request any more,
/// friends already). Null to read the web window instead: another answer, the add-friend window (`mode: add`, no
/// request pending), a refusal without a message.
///
/// Throws [ApproveFriendRejected] for the login prompt and for an answer served to another account.
ApproveFriendFormResult? approveFriendFormFromApi(Object? data, {required int targetUid, required int viewerUid}) {
  final answer = smallFormAnswerOf(data, SmallFormKind.friendadd);
  if (answer == null) {
    return null;
  }
  if (answer.uid == 0 || (answer is SmallFormMessage && answer.login)) {
    throw const ApproveFriendRejected(ApproveFriendFailure.notLoggedIn, 'login prompt');
  }
  if (!answer.servedTo(viewerUid)) {
    throw const ApproveFriendRejected(ApproveFriendFailure.accountMismatch, 'answer of another account');
  }
  switch (answer) {
    case SmallFormMessage(:final message):
      return message.trim().isEmpty ? null : ApproveFriendRefused(message.trim());
    case final SmallFormFields form:
      final json = form.json;
      final url = form.submitUrl('home.php', {'mod': 'spacecp', 'ac': 'friend', 'op': 'add', 'uid': '$targetUid'});
      final fields = form.submitFields;
      final gid = tsdmAppMap(json['gid']);
      final groups = [
        for (final c in tsdmAppList(gid['choices']))
          if (tsdmAppText(c['value']) case final String value when RegExp(r'^\d{1,3}$').hasMatch(value))
            FriendGroup(gid: value, name: tsdmAppText(c['label']).trim()),
      ];
      if (json['mode'] != 'approve' ||
          tsdmAppInt(json['touid']) != targetUid ||
          url == null ||
          !form.usable ||
          fields['add2submit'] != 'true' ||
          (fields['formhash'] ?? '').isEmpty ||
          fields['handlekey'] == null ||
          groups.isEmpty) {
        return null;
      }
      final selected = tsdmAppText(gid['value']);
      return ApproveFriendForm(
        targetUid: targetUid,
        targetName: tsdmAppText(json['username']).trim(),
        groups: groups,
        selectedGid: groups.any((g) => g.gid == selected) ? selected : groups.first.gid,
        fields: [for (final MapEntry(:key, :value) in fields.entries) (key, value)],
        fromApi: true,
        viewerUid: viewerUid,
      );
  }
}

/// The answer [data] to an approval of plugin 4.0.0 for [targetUid]: approved when the forum said `friends_add` (its
/// `uid`, when it names one, being [targetUid]); the forum's refusal with its message otherwise. The login prompt and
/// an answer that tells nothing are failures: the approval may or may not have been applied.
///
/// A result served to another account than [viewerUid] (and not the login prompt) is never an approval.
Either<ApproveFriendFailure, AddFriendResult> approveFriendResultFromApi(
  Object? data, {
  required int targetUid,
  int? viewerUid,
}) {
  final result = switch (tsdmAppV4WriteOutcomeOf(data)) {
    TsdmAppV4Written(:final result) => result,
    _ => null,
  };
  if (result == null) {
    return left(ApproveFriendFailure.unknownAfterSubmit);
  }
  if (result.login) {
    return left(ApproveFriendFailure.notLoggedIn);
  }
  if (viewerUid != null && result.uid != viewerUid) {
    return left(ApproveFriendFailure.accountMismatch);
  }
  if (result.messageKey == 'friends_add') {
    final uid = result.values['uid'];
    if (uid != null && uid.isNotEmpty && uid != '$targetUid') {
      return left(ApproveFriendFailure.unknownAfterSubmit);
    }
    return right(AddFriendResult(success: true, message: result.message.trim()));
  }
  if (result.messageKey.isNotEmpty && result.reason.trim().isNotEmpty) {
    return right(AddFriendResult(success: false, message: result.reason.replaceAll(RegExp(r'\s+'), ' ').trim()));
  }
  return left(ApproveFriendFailure.unknownAfterSubmit);
}
