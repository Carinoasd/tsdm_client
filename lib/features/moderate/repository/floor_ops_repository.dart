import 'dart:io' if (dart.libaray.js) 'package:web/web.dart';

import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/moderate/models/remove_rate.dart';
import 'package:tsdm_client/features/moderate/repository/moderate_repository.dart';
import 'package:tsdm_client/features/tsdmapp/small_form.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:universal_html/parsing.dart';

/// The operations on one floor that are no management window of `topicadmin`: rates taken back by a moderator
/// (`forum.php?mod=misc&action=removerate`) and an attachment deleted from the edit page
/// (`forum.php?mod=ajax&action=deleteattach`).
///
/// Bound to the account logged in when each request is made (`currentUid`): an answer served to another account is
/// dropped ([IdentityChangedException]), and nothing is sent once the account changed. Every write is sent once.
final class FloorOpsRepository {
  /// Constructor; transports are injected so the flow is tested without the forum. [get] reads, [getOnce] is a GET
  /// that writes (never retried), [post] posts once.
  FloorOpsRepository({
    required ModerateGet get,
    required ModerateGet getOnce,
    required ModeratePost post,
    int Function()? currentUid,
  }) : _get = get,
       _getOnce = getOnce,
       _post = post,
       _currentUid = currentUid ?? currentLoginUid;

  /// Uses the app's client.
  factory FloorOpsRepository.network() => FloorOpsRepository(
    get: (url) async => switch (await getIt.get<NetClientProvider>().get(url).run()) {
      Left(:final value) => left(value),
      Right(:final value) => right((statusCode: value.statusCode ?? 0, data: value.data)),
    },
    getOnce: (url) async => switch (await getIt.get<NetClientProvider>().get(url, singleAttempt: true).run()) {
      Left(:final value) => left(value),
      Right(:final value) => right((statusCode: value.statusCode ?? 0, data: value.data)),
    },
    post: (url, body) async =>
        switch (await getIt.get<NetClientProvider>().postForm(url, data: body, singleAttempt: true).run()) {
          Left(:final value) => left(value),
          Right(:final value) => right((statusCode: value.statusCode ?? 0, data: value.data)),
        },
  );

  final ModerateGet _get;
  final ModerateGet _getOnce;
  final ModeratePost _post;
  final int Function() _currentUid;

  /// Ask the window taking rates of floor [pid] of thread [tid] back: the app API's `page`, or the AJAX fragment
  /// without the plugin; the forum's refusal is a [RemoveRateWindowRefused] with its words.
  AsyncEither<RemoveRateWindow> fetchRemoveRateWindow({required String tid, required String pid}) =>
      AsyncEither(() async {
        final uid = _currentUid();
        if (uid <= 0) {
          return left(IdentityChangedException());
        }
        final resp = await _get(withTsdmAppJsonWrite(RemoveRateForm.windowUrl(tid: tid, pid: pid)));
        switch (resp) {
          case Left(:final value):
            return left(value);
          case Right(:final value) when value.statusCode != HttpStatus.ok:
            return left(HttpRequestFailedException(value.statusCode));
          case Right(:final value):
            if (_currentUid() != uid) {
              return left(IdentityChangedException());
            }
            return removeRateWindowOf(value.data, tid: tid, pid: pid, uid: uid);
        }
      });

  /// The window taking rates of floor [pid] back in answer [data], asked by account [uid].
  static Either<AppException, RemoveRateWindow> removeRateWindowOf(
    Object? data, {
    required String tid,
    required String pid,
    required int uid,
  }) {
    if (tsdmAppWriteResultOf(data) case final result?) {
      if (result.uid != uid) {
        return left(IdentityChangedException());
      }
      if (result.kind != TsdmAppWriteKind.page) {
        return right(RemoveRateWindowRefused(result.reason));
      }
      final form = RemoveRateForm.parse(result.document, tid: tid, pid: pid, uid: uid);
      return form == null ? left(HttpRequestFailedException(HttpStatus.ok)) : right(RemoveRateWindowReady(form));
    }
    final text = floorOpAjaxText(tsdmAppAnswerText(data));
    // The account was checked around the request (fetchRemoveRateWindow): the window is that account's.
    final form = RemoveRateForm.parse(parseHtmlDocument(text), tid: tid, pid: pid, uid: uid);
    if (form != null) {
      return right(RemoveRateWindowReady(form));
    }
    if (removeRateAjaxError(text) case final error?) {
      return right(RemoveRateWindowRefused(error));
    }
    return left(HttpRequestFailedException(HttpStatus.ok));
  }

  /// Take the rates [logIds] of the window [form] back with [reason] and [notify], once; never when none of them is
  /// in the window (the forum answers its success for nothing taken back) nor when the account changed since the
  /// window was served ([IdentityChangedException]).
  AsyncEither<FloorOpOutcome> removeRates(
    RemoveRateForm form,
    Iterable<String> logIds, {
    String reason = '',
    bool notify = false,
  }) => AsyncEither(() async {
    final uid = _currentUid();
    if (uid <= 0 || form.uid != uid) {
      return left(IdentityChangedException());
    }
    final body = form.body(logIds, reason: reason, notify: notify);
    if (!body.keys.any((e) => e.startsWith('logidarray['))) {
      return left(HttpRequestFailedException(null));
    }
    final resp = await _post(RemoveRateForm.submitUrl, body);
    return switch (resp) {
      Left(:final value) => left(value),
      Right(:final value) when value.statusCode != HttpStatus.ok => left(HttpRequestFailedException(value.statusCode)),
      Right(:final value) => right(removeRateOutcomeOf(value.data)),
    };
  });

  /// Delete attachment [aid] of floor [pid] of thread [tid] with the form hash [formHash] the edit page was served by
  /// account [formUid], once; never when the account changed since. The forum deletes it right away, whether the
  /// edit is saved or not.
  ///
  /// The forum answers only how many it deleted ([deleteAttachmentOutcomeOf]): a refusal has no words. An answer the
  /// app can not read is an [HttpRequestFailedException]: the attachment may be gone.
  AsyncEither<FloorOpOutcome> deleteAttachment({
    required String tid,
    required String pid,
    required int aid,
    required String formHash,
    required int formUid,
  }) => AsyncEither(() async {
    final uid = _currentUid();
    if (uid <= 0 || formUid != uid) {
      return left(IdentityChangedException());
    }
    final resp = await _getOnce(
      withTsdmAppJsonWrite(deleteAttachmentUrl(tid: tid, pid: pid, aid: aid, formHash: formHash)),
    );
    switch (resp) {
      case Left(:final value):
        return left(value);
      case Right(:final value) when value.statusCode != HttpStatus.ok:
        return left(HttpRequestFailedException(value.statusCode));
      case Right(:final value):
        if (tsdmAppWriteResultOf(value.data) case final result? when result.uid != uid) {
          return left(IdentityChangedException());
        }
        final outcome = deleteAttachmentOutcomeOf(value.data);
        return outcome == null ? left(HttpRequestFailedException(HttpStatus.ok)) : right(outcome);
    }
  });
}
