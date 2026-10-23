import 'dart:convert';
import 'dart:io' if (dart.libaray.js) 'package:web/web.dart';

import 'package:collection/collection.dart';
import 'package:dio/dio.dart' show Options;
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/extensions/universal_html.dart';
import 'package:tsdm_client/features/authentication/utils/logged_user_parser.dart';
import 'package:tsdm_client/features/blocking/repository/notice_ignore_repository.dart' show isCloudflareChallengePage;
import 'package:tsdm_client/features/post_report/models/post_report.dart';
import 'package:tsdm_client/features/post_report/utils/report_page_context.dart';
import 'package:tsdm_client/features/thread/v1/utils/thread_page_api.dart';
import 'package:tsdm_client/features/tsdmapp/small_form.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:universal_html/parsing.dart';

/// Answer of one request: status and text body.
final class PostReportResponse {
  /// Constructor.
  const PostReportResponse(this.statusCode, this.body, {this.challenge = false});

  /// Http status.
  final int statusCode;

  /// Text body, empty when there was none; a JSON answer of the forum's app API (the thread page asked in the JSON
  /// mode) as its JSON text.
  final String body;

  /// Cloudflare marked the answer as a challenge (`cf-mitigated: challenge`).
  final bool challenge;
}

/// Read [url]; [ajax] adds the `X-Requested-With` header of the forum's own dialogs. Throws on transport errors.
typedef PostReportGet = Future<PostReportResponse> Function(Uri url, {required bool ajax});

/// Send one form. Throws when the request failed or its result is unknown; never retried.
typedef PostReportPost = Future<PostReportResponse> Function(Uri url, Map<String, String> body);

/// Report requests of one account-bound client (#127).
///
/// Every read proves the account and the floor again; the report itself is sent at most once per [submit] call and
/// never retried.
class PostReportRepository with LoggerMixin {
  /// Transports are injected so the flow is tested without the forum.
  PostReportRepository({required this.get, required this.post});

  /// Uses [client], which drops requests once its account is not current.
  factory PostReportRepository.network(NetClientProvider client) => PostReportRepository(
    get: (url, {required ajax}) async {
      final resp = await client
          .get(
            url.toString(),
            options: Options(
              validateStatus: (_) => true,
              headers: ajax ? const {'X-Requested-With': 'XMLHttpRequest'} : null,
            ),
          )
          .run();
      return switch (resp) {
        Left(:final value) => throw value,
        Right(:final value) => PostReportResponse(
          value.statusCode ?? 0,
          switch (value.data) {
            final String text => text,
            // The JSON answer dio decoded already (the thread page in the JSON mode).
            final Map<dynamic, dynamic> json => jsonEncode(json),
            _ => '',
          },
          challenge: value.headers.value('cf-mitigated')?.toLowerCase() == 'challenge',
        ),
      };
    },
    post: (url, body) async => switch (await client.postForm(url.toString(), data: body, singleAttempt: true).run()) {
      Left(:final value) => throw value,
      Right(:final value) => PostReportResponse(
        value.statusCode ?? 0,
        switch (value.data) {
          final String text => text,
          // The write result of the forum's app API dio decoded already (plugin 2.6.0).
          final Map<dynamic, dynamic> json => jsonEncode(json),
          _ => '',
        },
      ),
    },
  );

  /// Page reads.
  final PostReportGet get;

  /// The report request.
  final PostReportPost post;

  Future<String> _read(Uri url, {required bool ajax}) async {
    final PostReportResponse resp;
    try {
      resp = await get(url, ajax: ajax);
    } on Object catch (e) {
      error('report page read failed: ${e.runtimeType}');
      throw const PostReportFailure(PostReportProblem.network);
    }
    if (resp.challenge) {
      throw const PostReportFailure(PostReportProblem.challenge);
    }
    if (resp.statusCode != HttpStatus.ok) {
      try {
        if (isCloudflareChallengePage(parseHtmlDocument(resp.body))) {
          throw const PostReportFailure(PostReportProblem.challenge);
        }
      } on PostReportFailure {
        rethrow;
      } on Object {
        // Not a page.
      }
      throw const PostReportFailure(PostReportProblem.network);
    }
    return resp.body;
  }

  /// Check on a fresh full thread page that [uid] is still served and still offered the report of [target].
  ///
  /// The page is asked in the JSON mode of the forum's app API. A structured answer (plugin 2.1.0, `schema: 3`) is
  /// checked on its fields ([_verifyFloorBuilt]) when it names the account it was served to (`uid`: every thread
  /// answer, and the forum's message since plugin 2.2.0); any other answer is the page, read as before. The message of
  /// plugin 2.1.0 names no account, and the account is what tells a change from a refusal: its document is read.
  Future<void> _verifyFloor(PostReportTarget target, int uid) async {
    final raw = await _read(Uri.parse(withTsdmAppJson(target.floorUrl.toString())), ajax: false);
    final api = threadApiAnswerOf(raw);
    if (api != null && api.containsKey('uid')) {
      _verifyFloorBuilt(target, uid, api);
      return;
    }
    final doc = tsdmAppPageDocument(raw);
    if (isCloudflareChallengePage(doc)) {
      throw const PostReportFailure(PostReportProblem.challenge);
    }
    final pageUid = parseLoggedUidFromDocument(doc);
    if (pageUid == null) {
      if (doc.querySelector('#messagelogin') != null || doc.querySelector('form#lsform') != null) {
        throw const PostReportFailure(PostReportProblem.notLoggedIn);
      }
      throw const PostReportFailure(PostReportProblem.unsupported);
    }
    if (pageUid != uid) {
      throw const PostReportFailure(PostReportProblem.accountChanged);
    }
    final postNode = doc.querySelector('div#post_${target.pid}');
    if (postNode == null) {
      final message = doc.querySelector('#messagetext p')?.innerText.trim();
      if (message != null && message.isNotEmpty) {
        throw PostReportFailure(PostReportProblem.forumMessage, message: plainForumText(message));
      }
      throw const PostReportFailure(PostReportProblem.noPermission);
    }
    final context = postReportPageContextOf(doc, expectedTid: '${target.tid}');
    if (context == null || context.fid != target.fid) {
      throw const PostReportFailure(PostReportProblem.noPermission);
    }
    final fresh = Post.fromPostNode(postNode, doc.currentPage() ?? 1, reportContext: context)?.reportTarget;
    if (fresh != target) {
      throw const PostReportFailure(PostReportProblem.noPermission);
    }
  }

  /// [_verifyFloor] on the page built from the structured answer [api], which names the account it was served to:
  /// a guest (the login prompt, or the thread served to one) is not logged in, another account is a change, as the
  /// page's `discuz_uid` tells first on the document path; then the forum's message (no such thread, no permission),
  /// the floor among the posts, the thread and forum of [target], and the same report still offered ([Post.fromApi]
  /// builds the target from `can.report`).
  void _verifyFloorBuilt(PostReportTarget target, int uid, Map<String, dynamic> api) {
    final pageUid = threadApiViewerUid(api);
    if (pageUid == null) {
      throw const PostReportFailure(PostReportProblem.notLoggedIn);
    }
    if (pageUid != uid) {
      throw const PostReportFailure(PostReportProblem.accountChanged);
    }
    final page = threadPageFromApi(api, 1);
    if (!page.havePermission) {
      final message = page.permissionDeniedMessage?.innerText.trim();
      if (message != null && message.isNotEmpty) {
        throw PostReportFailure(PostReportProblem.forumMessage, message: plainForumText(message));
      }
      throw const PostReportFailure(PostReportProblem.noPermission);
    }
    final post = page.postList.firstWhereOrNull((e) => e.postID == '${target.pid}');
    if (post == null) {
      throw const PostReportFailure(PostReportProblem.noPermission);
    }
    if (page.tid != '${target.tid}' || page.fid != target.fid || post.reportTarget != target) {
      throw const PostReportFailure(PostReportProblem.noPermission);
    }
  }

  /// A fresh report form of [target] for account [uid].
  ///
  /// First the full thread page proves the account (the ajax dialog has no page header) and that the forum still
  /// offers this report to it, then the dialog is read like the forum's `showWindow` does, with the write result of
  /// the forum's app API: plugin 3.0.0 answers the form as structured fields ([withTsdmAppForm],
  /// [postReportFormFromApi]) or the forum's message instead of it, served to [uid] or never used; an older plugin
  /// answers its write result (plugin 2.6.0: a `page` with the form, [parsePostReportForm]), which is parsed as
  /// before. Nothing is sent to the forum's report handler. Throws [PostReportFailure] only.
  Future<PostReportForm> prepare(PostReportTarget target, {required int uid}) async {
    if (uid <= 0 || uid != target.viewerUid) {
      throw const PostReportFailure(PostReportProblem.accountChanged);
    }
    await _verifyFloor(target, uid);
    final url = target.reportUrl.replace(
      queryParameters: {
        ...target.reportUrl.queryParameters,
        'inajax': '1',
        'infloat': 'yes',
        'handlekey': target.handleKey,
      },
    );
    final raw = await _read(Uri.parse(withTsdmAppForm(url.toString())), ajax: true);
    switch (smallFormAnswerOf(raw, SmallFormKind.report)) {
      case final SmallFormAnswer answer when !answer.servedTo(uid):
        // A guest's answer (the session expired) or another account's: never used.
        throw PostReportFailure(answer.uid == 0 ? PostReportProblem.notLoggedIn : PostReportProblem.accountChanged);
      case SmallFormMessage(:final login, :final reason):
        if (login) {
          throw const PostReportFailure(PostReportProblem.notLoggedIn);
        }
        final message = plainForumText(reason);
        throw PostReportFailure(
          message.isEmpty ? PostReportProblem.unsupported : PostReportProblem.forumMessage,
          message: message.isEmpty ? null : message,
        );
      case final SmallFormFields form when form.usable:
        return postReportFormFromApi(form, target: target);
      case SmallFormFields():
        // Other plugins' fields or something the plugin says the app cannot fill: the dialog as before, whose
        // parser refuses any field it does not know.
        return parsePostReportForm(
          await _read(Uri.parse(withTsdmAppJsonWrite(url.toString())), ajax: true),
          target: target,
        );
      case null when isSmallFormUnknown(raw):
        return parsePostReportForm(
          await _read(Uri.parse(withTsdmAppJsonWrite(url.toString())), ajax: true),
          target: target,
        );
      case null:
        // An older plugin's answer (its write result of the dialog), or the dialog itself without the plugin.
        return parsePostReportForm(raw, target: target);
    }
  }

  /// Send [message] with [form] once. Never throws and never retries.
  Future<PostReportOutcome> submit(PostReportForm form, String message) async {
    final PostReportResponse resp;
    try {
      resp = await post(form.action, form.body(message));
    } on Object catch (e) {
      // The request may have reached the forum, including a drop because the account changed meanwhile.
      error('report request ended without a readable answer: ${e.runtimeType}');
      return const PostReportUnknown();
    }
    if (resp.statusCode != HttpStatus.ok) {
      error('report request answered ${resp.statusCode}');
      return const PostReportUnknown();
    }
    return parsePostReportResult(resp.body, form: form);
  }
}
