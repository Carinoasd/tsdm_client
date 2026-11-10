import 'dart:io' if (dart.library.js) 'package:web/web.dart';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/space/models/space_models.dart';
import 'package:tsdm_client/features/space/repository/space_write_repository.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/logger.dart';

final _succeedRe = RegExp(r"succeedhandle_\w*\('[^']*',\s*'([^']*)'");
final _errorRe = RegExp(r"errorhandle_\w*\('([^']*)'");

/// What the repositories that post the forms of the space for one account share: the account they were built for,
/// and how the answer of a post is read.
///
/// Every request goes on the account the repository was built for, never once another account is current
/// ([isCurrent]) or once [invalidate]d, and a page or form served to another account is never posted ([owns]). A post
/// is sent once (single attempt): an answer that does not tell the outcome is [SpaceWriteOutcome.unconfirmed], never
/// sent again by itself.
///
/// Every post goes as the website's popups send it (`inajax=1`): the forum's app API (plugin 2.6.0) answers its
/// result as JSON ([tsdmAppWriteResultOf]), the forum without it the AJAX answer (`succeedhandle_…('url', 'message')`,
/// `errorhandle_…('message')`).
abstract base class SpaceAccountRepository with LoggerMixin {
  /// Constructor.
  SpaceAccountRepository({required NetClientProvider client, required int? Function() currentUid})
    : this.withTransport(
        currentUid: currentUid,
        getPage: (url) => client.get(url).run(),
        // A redirect is an answer (the forum's "done" of a form without a message), not a failed request.
        sendForm: (url, body) => client
            .postForm(
              url,
              data: body,
              singleAttempt: true,
              acceptStatus: const {HttpStatus.movedPermanently, HttpStatus.found},
            )
            .run(),
      );

  /// Injectable transports; a post is never retried.
  SpaceAccountRepository.withTransport({
    required int? Function() currentUid,
    required Future<SyncEither<Response<dynamic>>> Function(String) getPage,
    required Future<SyncEither<Response<dynamic>>> Function(String, Map<String, String>) sendForm,
  }) : _get = getPage,
       _post = sendForm,
       _currentUid = currentUid,
       ownerUid = currentUid();

  final Future<SyncEither<Response<dynamic>>> Function(String) _get;
  final Future<SyncEither<Response<dynamic>>> Function(String, Map<String, String>) _post;
  final int? Function() _currentUid;

  /// The account this repository belongs to: the one current when it was built.
  @protected
  final int? ownerUid;

  bool _invalidated = false;

  /// Nothing more is sent, even when the account comes back.
  void invalidate() => _invalidated = true;

  /// Whether requests may still go out for the account this repository belongs to.
  bool get isCurrent => !_invalidated && ownerUid != null && ownerUid! > 0 && ownerUid == _currentUid();

  /// Whether a form of the page served with [session] may be posted: the page belongs to the account of this
  /// repository, which is still the one in use.
  @protected
  bool owns(SpaceSession session) => isCurrent && session.uid == ownerUid;

  /// Read the page [url].
  @protected
  Future<SyncEither<Response<dynamic>>> getPage(String url) => _get(url);

  /// Post [body] to [url], once.
  @protected
  Future<SyncEither<Response<dynamic>>> sendForm(String url, Map<String, String> body) => _post(url, body);

  /// What the answer [result] of a post tells.
  ///
  /// [redirectIsDone] for a form the forum answers by going back to where it came from once done (a record posted or
  /// deleted): the redirect itself, on a forum without the app API.
  @protected
  SpaceWriteResult outcomeOf(SyncEither<Response<dynamic>> result, {bool redirectIsDone = false}) {
    final Response<dynamic> response;
    switch (result) {
      case Left(:final value):
        // The request may still have reached the forum.
        error('post failed, result unknown: $value');
        return const SpaceWriteResult(SpaceWriteOutcome.unconfirmed);
      case Right(:final value):
        response = value;
    }
    if (redirectIsDone &&
        (response.statusCode == HttpStatus.movedPermanently || response.statusCode == HttpStatus.found)) {
      return const SpaceWriteResult(SpaceWriteOutcome.done);
    }
    if (response.statusCode != HttpStatus.ok) {
      return const SpaceWriteResult(SpaceWriteOutcome.unconfirmed);
    }
    if (tsdmAppWriteResultOf(response.data) case final api?) {
      if (api.asksVerification) {
        return SpaceWriteResult(SpaceWriteOutcome.rejected, message: t.postEditPage.verificationRequired);
      }
      if (api.login) {
        return SpaceWriteResult(SpaceWriteOutcome.loginRequired, message: api.reason);
      }
      if (api.kind != TsdmAppWriteKind.page && api.succeeded) {
        return SpaceWriteResult(SpaceWriteOutcome.done, message: api.message.isEmpty ? null : api.message);
      }
      if (api.isError || (api.kind != TsdmAppWriteKind.page && !api.ok)) {
        return SpaceWriteResult(SpaceWriteOutcome.rejected, message: api.reason);
      }
      return SpaceWriteResult(SpaceWriteOutcome.unconfirmed, message: api.reason.isEmpty ? null : api.reason);
    }
    final text = tsdmAppAnswerText(response.data);
    if (_succeedRe.firstMatch(text)?.group(1)?.trim() case final String message) {
      return SpaceWriteResult(SpaceWriteOutcome.done, message: message.isEmpty ? null : message);
    }
    if (_errorRe.firstMatch(text)?.group(1)?.trim() case final String message) {
      return SpaceWriteResult(SpaceWriteOutcome.rejected, message: message.isEmpty ? null : message);
    }
    return const SpaceWriteResult(SpaceWriteOutcome.unconfirmed);
  }
}
