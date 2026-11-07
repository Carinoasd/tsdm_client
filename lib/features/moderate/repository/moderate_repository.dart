import 'dart:io' if (dart.libaray.js) 'package:web/web.dart';

import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/moderate/models/moderate_form.dart';
import 'package:tsdm_client/features/tsdmapp/small_form.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:universal_html/parsing.dart';

/// An answer of the forum: the http status and the body as dio decoded it (a JSON object, or text).
typedef ModerateResponse = ({int statusCode, Object? data});

/// Read [url]. Returns the failure of the transport as its left.
typedef ModerateGet = Future<Either<AppException, ModerateResponse>> Function(String url);

/// Post [body] to [url] once, never retried. Returns the failure of the transport as its left.
typedef ModeratePost = Future<Either<AppException, ModerateResponse>> Function(String url, Map<String, String> body);

/// The error handler call of the AJAX answer to a management request the forum refused (without the app API):
/// `errorhandle_mods('抱歉，您没有权限设置主题置顶', {});`, the message quoted with `\'` escaped.
final _errorHandleRe = RegExp(r"errorhandle_mods\('(?<error>(?:[^'\\]|\\.)*)'");

/// The success handler call of the AJAX answer to a management request (without the app API).
final _succeedHandleRe = RegExp(r"succeedhandle_mods\('(?:[^'\\]|\\.)*',\s*'(?<message>(?:[^'\\]|\\.)*)'");

String _unescape(String s) => s.replaceAllMapped(RegExp(r'\\(.)'), (m) => m.group(1)!);

/// Thread management of a moderator: whether the account moderates a forum, the forum's management windows, and the
/// management requests.
///
/// Bound to the account logged in when each request is made (`currentUid`): an answer served to another account is
/// dropped ([IdentityChangedException]), and a window is never posted once the account changed.
///
/// The app decides nothing about permissions: the forum says whether the account moderates the forum, lists the
/// levels and forums the account may choose from, and refuses what the account may not do, in its own words.
final class ModerateRepository with LoggerMixin {
  /// Constructor; transports are injected so the flow is tested without the forum.
  ModerateRepository({required ModerateGet get, required ModeratePost post, int Function()? currentUid})
    : _get = get,
      _post = post,
      _currentUid = currentUid ?? currentLoginUid;

  /// Uses the app's client.
  factory ModerateRepository.network() => ModerateRepository(
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

  /// Whether an account moderates a forum, by `uid:fid`, with the time it was learnt.
  static final _moderates = <String, (bool, DateTime)>{};

  /// How long [isModerator] keeps an answer.
  static const moderatorKeptFor = Duration(minutes: 10);

  /// Forget every [isModerator] answer (tests).
  static void resetModeratorCache() => _moderates.clear();

  /// Whether the account logged in moderates forum [fid], as the forum's app API tells on the forum page
  /// (`forum.ismoderator`, plugin 2.0.0): the thread page answer does not carry it.
  ///
  /// False for a guest, a forum page that is not the structured answer (no plugin, the forum's message: no
  /// permission), an answer served to another account, and a failed request. Kept for [moderatorKeptFor] per account
  /// and forum.
  Future<bool> isModerator(int fid) async {
    final uid = _currentUid();
    if (uid <= 0 || fid <= 0) {
      return false;
    }
    final key = '$uid:$fid';
    if (_moderates[key] case (final known, final at) when DateTime.now().difference(at) < moderatorKeptFor) {
      return known;
    }
    final resp = await _get(withTsdmAppJson('$baseUrl/forum.php?mod=forumdisplay&fid=$fid'));
    final json = switch (resp) {
      Right(:final value) when value.statusCode == HttpStatus.ok => tsdmAppAnswerJson(value.data),
      _ => null,
    };
    if (json == null || _currentUid() != uid) {
      return false;
    }
    final moderates = moderatorOf(json, uid: uid, fid: fid);
    if (moderates != null) {
      _moderates[key] = (moderates, DateTime.now());
    }
    return moderates ?? false;
  }

  /// Whether forum page answer [json] says account [uid] moderates forum [fid]; null when it is not that answer
  /// (no `schema`, another account, another forum).
  static bool? moderatorOf(Map<String, dynamic> json, {required int uid, required int fid}) {
    if (json['schema'] is! num || tsdmAppInt(json['uid']) != uid) {
      return null;
    }
    final forum = tsdmAppMap(json['forum']);
    if (tsdmAppInt(forum['fid']) != fid) {
      return null;
    }
    return tsdmAppInt(forum['ismoderator']) == 1;
  }

  /// Ask the window of [operation] for thread [tid] in forum [fid].
  ///
  /// The window comes as the app API's write result (plugin 2.6.0, a `page`), or as the AJAX fragment of a forum
  /// without the plugin; the forum's refusal to open it (`admin_nopermission`, no such thread) is a
  /// [ModerateWindowRefused] with its words. A window served to another account is an [IdentityChangedException].
  AsyncEither<ModerateWindow> fetchWindow(ModerateOperation operation, {required String tid, required int fid}) =>
      AsyncEither(() async {
        final uid = _currentUid();
        final resp = await _get(withTsdmAppJsonWrite(ModerateForm.windowUrl(operation, tid: tid, fid: fid)));
        switch (resp) {
          case Left(:final value):
            return left(value);
          case Right(:final value) when value.statusCode != HttpStatus.ok:
            return left(HttpRequestFailedException(value.statusCode));
          case Right(:final value):
            if (_currentUid() != uid) {
              return left(IdentityChangedException());
            }
            return windowOf(value.data, operation, tid: tid, fid: fid, uid: uid);
        }
      });

  /// The window of [operation] in answer [data], asked by account [uid].
  static Either<AppException, ModerateWindow> windowOf(
    Object? data,
    ModerateOperation operation, {
    required String tid,
    required int fid,
    required int uid,
  }) {
    final result = tsdmAppWriteResultOf(data);
    if (result != null) {
      if (result.uid != uid) {
        return left(IdentityChangedException());
      }
      if (result.kind != TsdmAppWriteKind.page) {
        return right(ModerateWindowRefused(result.reason));
      }
      final form = ModerateForm.parse(result.document, operation, tid: tid, fid: fid, uid: uid);
      return form == null ? left(HttpRequestFailedException(HttpStatus.ok)) : right(ModerateWindowReady(form));
    }
    final text = _ajaxText(tsdmAppAnswerText(data));
    final form = ModerateForm.parse(parseHtmlDocument(text), operation, tid: tid, fid: fid);
    if (form != null) {
      return right(ModerateWindowReady(form));
    }
    if (_errorHandleRe.firstMatch(text)?.namedGroup('error') case final error?) {
      return right(ModerateWindowRefused(_unescape(error)));
    }
    return left(HttpRequestFailedException(HttpStatus.ok));
  }

  /// Send [request] with the window [form] it was chosen in, once.
  ///
  /// Never sent when the account changed since the window was served ([IdentityChangedException]). The forum's
  /// verdict is read from the app API's result (the `admin_succeed` message key) or, without the plugin, from the
  /// handler the AJAX answer calls; anything else is a refusal in the forum's words.
  AsyncEither<ModerateOutcome> submit(ModerateForm form, ModerateRequest request) => AsyncEither(() async {
    if (request.operation.group != form.operation.group) {
      return left(HttpRequestFailedException(null));
    }
    final uid = _currentUid();
    if (uid <= 0 || (form.uid > 0 && form.uid != uid)) {
      return left(IdentityChangedException());
    }
    final resp = await _post(form.submitUrl, request.body(form));
    return switch (resp) {
      Left(:final value) => left(value),
      Right(:final value) when value.statusCode != HttpStatus.ok => left(HttpRequestFailedException(value.statusCode)),
      Right(:final value) => right(outcomeOf(value.data)),
    };
  });

  /// The forum's verdict in answer [data] to a management request.
  static ModerateOutcome outcomeOf(Object? data) {
    if (tsdmAppWriteResultOf(data) case final result?) {
      // Told by the language key, not by the words.
      if (result.succeeded && result.messageKey == 'admin_succeed') {
        return ModerateSucceeded(result.message);
      }
      return ModerateRefused(result.reason);
    }
    final text = _ajaxText(tsdmAppAnswerText(data));
    if (_succeedHandleRe.firstMatch(text) case final match?) {
      return ModerateSucceeded(_unescape(match.namedGroup('message')!).trim());
    }
    if (_errorHandleRe.firstMatch(text)?.namedGroup('error') case final error?) {
      return ModerateRefused(_unescape(error));
    }
    return const ModerateRefused('');
  }

  /// The html inside the AJAX answer [text] (`<root><![CDATA[…]]></root>`), [text] itself when it is not one.
  static String _ajaxText(String text) {
    if (!text.trimLeft().startsWith('<?xml')) {
      return text;
    }
    try {
      return parseXmlDocument(text).documentElement?.text ?? text;
    } on Object catch (_) {
      return text;
    }
  }
}
