import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/blocking/models/notice_ignore.dart';
import 'package:tsdm_client/features/blocking/repository/notice_ignore_repository.dart'
    show failureOfPageStatus, pageReadOptions;
import 'package:tsdm_client/features/friend/models/add_friend.dart';
import 'package:tsdm_client/features/friend/models/approve_friend.dart';
import 'package:tsdm_client/features/friend/utils/approve_friend_link.dart';
import 'package:tsdm_client/features/friend/utils/parse_approve_friend.dart';
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
  Future<Either<ApproveFriendFailure, ApproveFriendFormResult>> fetchForm(
    NetClientProvider client, {
    required int targetUid,
  }) async {
    final resp = await client.get(approveFriendFormUrl(targetUid), options: pageReadOptions()).run();
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
      case Right(:final value) when value.data is! String:
        return left(ApproveFriendFailure.unknownForm);
      case Right(:final value):
        try {
          return right(parseApproveFriendForm(value.data as String, targetUid: targetUid));
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
    if (raw is! String) {
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
