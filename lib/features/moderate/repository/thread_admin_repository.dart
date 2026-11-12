import 'dart:io' if (dart.libaray.js) 'package:web/web.dart';

import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/moderate/models/thread_admin_forms.dart';
import 'package:tsdm_client/features/moderate/repository/moderate_repository.dart';
import 'package:tsdm_client/features/tsdmapp/small_form.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';

/// What the forum answered for a window: its fields, or its refusal in its words.
sealed class ThreadAdminWindow<T> {
  const ThreadAdminWindow();
}

/// The window.
final class ThreadAdminWindowReady<T> extends ThreadAdminWindow<T> {
  /// Constructor.
  const ThreadAdminWindowReady(this.value);

  /// What it holds.
  final T value;
}

/// The forum's refusal (no permission, not a bounty any more, a special thread…), in its words.
final class ThreadAdminWindowRefused<T> extends ThreadAdminWindow<T> {
  /// Constructor.
  const ThreadAdminWindowRefused(this.message);

  /// The forum's message, may be empty.
  final String message;
}

/// What became of a [ThreadAdminForm] sent: done only for the forum's `admin_succeed`; its message otherwise.
typedef ThreadAdminOutcome = ({bool done, String message});

/// The windows of a moderator the forum's app API gives as small forms since plugin 3.9.0: the poster's IP of a floor
/// (`getip`), taking the bounty off a thread (`removereward`) and refunding a paid thread (`refund`).
///
/// Bound to the account logged in when each request is made: an answer served to another account is dropped
/// ([IdentityChangedException]), and nothing is posted once the account changed. The form is posted once.
final class ThreadAdminRepository {
  /// Constructor; transports are injected so the flow is tested without the forum.
  ThreadAdminRepository({required ModerateGet get, required ModeratePost post, int Function()? currentUid})
    : _get = get,
      _post = post,
      _currentUid = currentUid ?? currentLoginUid;

  /// Uses the app's client.
  factory ThreadAdminRepository.network() => ThreadAdminRepository(
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

  final ModerateGet _get;
  final ModeratePost _post;
  final int Function() _currentUid;

  Future<Either<AppException, ThreadAdminWindow<T>>> _window<T>(
    String url,
    SmallFormKind kind,
    T? Function(SmallFormFields form, int uid) read,
  ) async {
    final uid = _currentUid();
    if (uid <= 0) {
      return left(IdentityChangedException());
    }
    switch (await _get(url)) {
      case Left(:final value):
        return left(value);
      case Right(:final value) when value.statusCode != HttpStatus.ok:
        return left(HttpRequestFailedException(value.statusCode));
      case Right(:final value):
        if (_currentUid() != uid) {
          return left(IdentityChangedException());
        }
        final answer = smallFormAnswerOf(value.data, kind);
        if (answer == null) {
          return left(HttpRequestFailedException(HttpStatus.ok));
        }
        if (!answer.servedTo(uid)) {
          if (answer.uid == 0) {
            return right(ThreadAdminWindowRefused(answer.identityProblem(uid) ?? ''));
          }
          return left(IdentityChangedException());
        }
        switch (answer) {
          case SmallFormMessage(:final reason):
            return right(ThreadAdminWindowRefused(reason));
          case final SmallFormFields form:
            final v = read(form, uid);
            return v == null ? left(HttpRequestFailedException(HttpStatus.ok)) : right(ThreadAdminWindowReady(v));
        }
    }
  }

  /// The poster's IP of floor [pid] from its `urls.viewip` [url] (checked to be that window of this forum).
  Future<Either<AppException, ThreadAdminWindow<FloorIp>>> fetchFloorIp(String url, {required int pid}) async {
    if (!isFloorIpUrl(url, pid: pid)) {
      return left(HttpRequestFailedException(null));
    }
    return _window(
      withTsdmAppForm(url, page: true),
      SmallFormKind.getip,
      (f, uid) => FloorIp.of(f, uid: uid, pid: pid),
    );
  }

  /// The window of [action] on thread [tid] of forum [fid].
  Future<Either<AppException, ThreadAdminWindow<ThreadAdminForm>>> fetchForm(
    ThreadAdminAction action, {
    required int fid,
    required int tid,
  }) => _window(
    threadAdminWindowUrl(baseUrl, action, fid: fid, tid: tid),
    action.kind,
    (f, uid) => ThreadAdminForm.of(f, action, uid: uid, tid: tid),
  );

  /// Post [form] once with [reason] and [notify]; never when the account changed since it was served.
  Future<Either<AppException, ThreadAdminOutcome>> submit(
    ThreadAdminForm form, {
    String reason = '',
    bool notify = false,
  }) async {
    final uid = _currentUid();
    if (uid <= 0 || form.uid != uid) {
      return left(IdentityChangedException());
    }
    final resp = await _post(
      withTsdmAppJsonWrite(withSmallFormInAjax(form.submitUrl)),
      form.body(reason: reason, notify: notify || form.notifyForced),
    );
    switch (resp) {
      case Left(:final value):
        return left(value);
      case Right(:final value) when value.statusCode != HttpStatus.ok:
        return left(HttpRequestFailedException(value.statusCode));
      case Right(:final value):
        return outcomeOf(value.data, uid: uid);
    }
  }

  /// The outcome in the answer [data] (a write result, `schema` 13) of a form sent by account [uid].
  static Either<AppException, ThreadAdminOutcome> outcomeOf(Object? data, {required int uid}) {
    final result = tsdmAppWriteResultOf(data);
    if (result == null) {
      return left(HttpRequestFailedException(HttpStatus.ok));
    }
    if (result.uid != uid) {
      if (result.uid == 0 && result.login) {
        return right((done: false, message: result.reason));
      }
      return left(IdentityChangedException());
    }
    return right((done: result.messageKey == 'admin_succeed', message: result.reason.trim()));
  }
}
