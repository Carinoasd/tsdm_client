import 'dart:io' if (dart.library.js) 'package:web/web.dart';

import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/utils/log_redaction.dart';

/// What went wrong when a page or a list failed to load, as the user is told: one sentence and what to do about it
/// (`FailureView`).
enum LoadFailureKind {
  /// The forum was never reached: no network, the name not resolved, the connection refused or timed out while
  /// connecting ([isNoNetworkFailure]). Check the network, retry.
  noNetwork,

  /// The connection was made and then dropped (reset, closed, a failed TLS handshake). Retry.
  connectionLost,

  /// Connected, but the answer did not come in time ([HttpHandshakeFailedException.timedOut]). Retry later.
  timeout,

  /// Too many requests: HTTP 429, or the forum's own "too frequent" message. Wait, then retry.
  rateLimited,

  /// The forum answered an error status: 5xx, or another status than the page ([LoadFailure.statusCode]). Retry later.
  server,

  /// The site in front of the forum asked for a browser check (`cf-mitigated: challenge`). Retry later, or open the
  /// forum in the browser.
  challenge,

  /// The forum says it is closed or under maintenance (its own words in [LoadFailure.message]). Come back later.
  closed,

  /// The forum asks to log in first. Log in.
  needLogin,

  /// The forum refuses the account in use (its own words in [LoadFailure.message]).
  noPermission,

  /// Another message of the forum, shown as the forum wrote it ([LoadFailure.message]).
  forumMessage,

  /// The account changed while the page was loading ([IdentityChangedException]). Load the page again.
  accountChanged,

  /// Anything else: an answer the app could not read, an unexpected failure. Retry; the details tell more.
  unknown,
}

/// A failed load as the user is told about it: its [kind], the forum's own words ([message]) when it gave any, and
/// the technical [details] (the exception, the HTTP status) kept for the details part of the failure view.
///
/// Built from the failure of a request ([LoadFailure.of]) or from the forum's message instead of a page
/// ([LoadFailure.fromMessage]).
final class LoadFailure {
  /// Constructor.
  LoadFailure(this.kind, {String? message, this.statusCode, this.retryAfterSeconds, String? details, DateTime? at})
    : message = message == null || message.trim().isEmpty ? null : message.trim(),
      details = details == null || details.trim().isEmpty ? null : redactSensitive(details.trim()),
      at = at ?? DateTime.now();

  /// The failure of a request [e] (null: nothing tells, an [LoadFailureKind.unknown] failure).
  factory LoadFailure.of(AppException? e) {
    if (e == null) {
      return LoadFailure(LoadFailureKind.unknown);
    }
    final details = _detailsOf(e);
    switch (e) {
      case IdentityChangedException():
        return LoadFailure(LoadFailureKind.accountChanged, details: details);
      case ProfileNeedLoginException():
        return LoadFailure(LoadFailureKind.needLogin, details: details);
      case HttpHandshakeFailedException(:final statusCode, :final headers):
        if (isNoNetworkFailure(e)) {
          return LoadFailure(LoadFailureKind.noNetwork, details: details);
        }
        if (e.timedOut) {
          return LoadFailure(LoadFailureKind.timeout, details: details);
        }
        if (statusCode == null) {
          return LoadFailure(LoadFailureKind.connectionLost, details: details);
        }
        final challenged = headers?.value('cf-mitigated')?.toLowerCase() == 'challenge';
        return LoadFailure._ofStatus(
          statusCode,
          details: details,
          retryAfter: headers?.value('retry-after'),
          challenge: challenged,
        );
      case HttpRequestFailedException(:final statusCode):
        if (statusCode == null || statusCode == HttpStatus.ok) {
          return LoadFailure(LoadFailureKind.unknown, details: details);
        }
        return LoadFailure._ofStatus(statusCode, details: details);
      case ServerRespondedErrorException(:final message?) ||
              ServerRespFailure(:final message?) ||
              RateInfoWithErrorException(:final message?) ||
              ReplyToPostFetchParameterFailedException(:final message?) ||
              PurchaseRefusedException(:final message?)
          when message.trim().isNotEmpty:
        return LoadFailure.fromMessage(message, details: details);
      default:
        return LoadFailure(LoadFailureKind.unknown, details: details);
    }
  }

  /// The forum's [message] shown instead of the page: what it is about (too frequent, closed, log in, no
  /// permission), the words kept as the forum wrote them.
  factory LoadFailure.fromMessage(String message, {String? details}) {
    final text = message.trim();
    final kind = forumMessageKind(text);
    return LoadFailure(
      kind,
      message: text,
      retryAfterSeconds: kind == LoadFailureKind.rateLimited ? forumMessageWaitSeconds(text) : null,
      details: details,
    );
  }

  /// The failure of the last request of the app that failed (`NetErrorSaver`): the best guess for a page that did not
  /// keep its own, an [LoadFailureKind.unknown] failure when nothing failed or the record is gone.
  factory LoadFailure.lastRequest() {
    if (!getIt.isRegistered<NetErrorSaver>()) {
      return LoadFailure(LoadFailureKind.unknown);
    }
    final saver = getIt.get<NetErrorSaver>();
    final failure = saver.failure();
    if (failure != null) {
      return LoadFailure.of(failure);
    }
    return LoadFailure(LoadFailureKind.unknown, details: saver.error());
  }

  /// The failure of an answer with the HTTP [status]: a check of the site ([challenge], its `cf-mitigated` header), too
  /// many requests (and the wait of its `Retry-After`), else an error of the server.
  factory LoadFailure._ofStatus(int status, {String? details, String? retryAfter, bool challenge = false}) {
    if (challenge && (status == HttpStatus.forbidden || status == HttpStatus.serviceUnavailable)) {
      return LoadFailure(LoadFailureKind.challenge, statusCode: status, details: details);
    }
    if (status == HttpStatus.tooManyRequests) {
      return LoadFailure(
        LoadFailureKind.rateLimited,
        statusCode: status,
        retryAfterSeconds: int.tryParse(retryAfter?.trim() ?? ''),
        details: details,
      );
    }
    return LoadFailure(LoadFailureKind.server, statusCode: status, details: details);
  }

  /// What went wrong.
  final LoadFailureKind kind;

  /// The forum's own words, null when it gave none.
  final String? message;

  /// The HTTP status of the answer, null when none came back or it does not matter.
  final int? statusCode;

  /// Seconds to wait before trying again, when the forum or the server said so (`Retry-After`, "N 秒内只能…").
  final int? retryAfterSeconds;

  /// Technical description of the failure (the exception and its message, the HTTP status), secrets redacted.
  final String? details;

  /// When the failure happened, the start of the wait of [retryAfterSeconds].
  final DateTime at;

  /// Whether the failure is the network's or the server's (the user cannot do anything but retry), not something the
  /// forum told.
  bool get isTransport => switch (kind) {
    LoadFailureKind.noNetwork ||
    LoadFailureKind.connectionLost ||
    LoadFailureKind.timeout ||
    LoadFailureKind.server ||
    LoadFailureKind.challenge ||
    LoadFailureKind.unknown => true,
    _ => false,
  };

  @override
  String toString() => 'LoadFailure($kind, status: $statusCode, message: $message, details: $details)';

  static String _detailsOf(AppException e) {
    final status = switch (e) {
      HttpHandshakeFailedException(:final statusCode?) ||
      HttpRequestFailedException(:final statusCode?) => ' (HTTP $statusCode)',
      _ => '',
    };
    final message = e.message;
    return '${e.runtimeType}$status${message == null || message.isEmpty ? '' : ': $message'}';
  }
}

// The forum's language pack may be simplified or traditional Chinese, its messages are matched in both.

final _rateLimitedRe = RegExp(
  r'[频頻]繁|\d+\s*秒[内內]只能|[间間]隔.{0,12}秒|秒.{0,6}[间間]隔|too (many|frequent)|flood',
  caseSensitive: false,
);

final _closedRe = RegExp(
  '(站点|站點|网站|網站|论坛|論壇|本站|系统|系統).{0,8}([关關][闭閉]|[维維][护護]|升[级級])|'
  '[暂暫][时時][关關][闭閉]|[维維][护護]中|maintenance|board.?closed|site.{0,8}closed',
  caseSensitive: false,
);

final _needLoginRe = RegExp(
  '(尚未|需要先|[请請]先|您需要|需要)登[录錄入陆陸]|登[录錄入陆陸](后|後)(才能|方可|可以|再)|'
  r'用[户戶][组組]\s*[(（]?\s*[游遊]客|not.?logged.?in|log ?in (first|required)|login required',
  caseSensitive: false,
);

final _noPermissionRe = RegExp(
  '[没沒]有[权權]限|[无無][权權]|[权權]限不足|用[户戶][组組].{0,16}([无無]法|不能|[没沒]有)|只有特定用[户戶]|'
  '禁止[访訪][问問]|[无無]法[访訪][问問]|不能[访訪][问問]|不允[许許]|[隐隱]私|no permission|not allowed|forbidden',
  caseSensitive: false,
);

/// What the forum's [message] (shown instead of a page) is about: too frequent, closed, log in first, no permission,
/// else [LoadFailureKind.forumMessage].
LoadFailureKind forumMessageKind(String message) {
  if (_rateLimitedRe.hasMatch(message)) {
    return LoadFailureKind.rateLimited;
  }
  if (_closedRe.hasMatch(message)) {
    return LoadFailureKind.closed;
  }
  if (_needLoginRe.hasMatch(message)) {
    return LoadFailureKind.needLogin;
  }
  if (_noPermissionRe.hasMatch(message)) {
    return LoadFailureKind.noPermission;
  }
  return LoadFailureKind.forumMessage;
}

final _waitSecondsRe = RegExp(r'(\d+)\s*秒');

/// Seconds the forum's "too frequent" [message] asks to wait ("您在 20 秒内只能进行一次搜索", "两次发表间隔少于 15 秒"),
/// null when it names none.
int? forumMessageWaitSeconds(String message) => int.tryParse(_waitSecondsRe.firstMatch(message)?.group(1) ?? '');
