import 'package:dio/dio.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/authentication/utils/logged_user_parser.dart';
import 'package:tsdm_client/features/editor/utils/mention.dart';
import 'package:tsdm_client/features/post/models/models.dart';
import 'package:tsdm_client/features/post/utils/draft_marker.dart';
import 'package:tsdm_client/features/post/utils/submission_result.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

/// Repository for editing posts.
final class PostEditRepository with LoggerMixin {
  /// Keep load and submit on one account-bound client for the editor lifetime.
  PostEditRepository({required NetClientProvider client, required int? Function() currentUid})
    : this.withTransport(
        currentUid: currentUid,
        getPage: (url) => client.get(url).run(),
        sendForm: (url, body) => client.postForm(url, data: body, singleAttempt: true).run(),
      );

  /// Injectable identity-bound transports; submissions must never automatically retry.
  PostEditRepository.withTransport({
    required int? Function() currentUid,
    required Future<SyncEither<Response<dynamic>>> Function(String) getPage,
    required Future<SyncEither<Response<dynamic>>> Function(String, Map<String, String>) sendForm,
  }) : _get = getPage,
       _post = sendForm,
       _currentUid = currentUid,
       _ownerUid = currentUid();

  final Future<SyncEither<Response<dynamic>>> Function(String) _get;
  final Future<SyncEither<Response<dynamic>>> Function(String, Map<String, String>) _post;
  final int? Function() _currentUid;
  final int? _ownerUid;
  bool _invalidated = false;

  /// Once invalidated, switching back must not revive an old form.
  void invalidate() => _invalidated = true;

  /// Whether this editing session still belongs to the active account.
  bool get isCurrent => !_invalidated && _ownerUid != null && _ownerUid > 0 && _ownerUid == _currentUid();

  /// Ignore repeated verification events for the same active account.
  bool belongsTo(int? uid) => isCurrent && uid == _ownerUid;

  /// A successful POST may instead enter moderation; verify the draft marker through GET.
  Future<bool> confirmsDraft(String url) async =>
      (await fetchData(url).run()).match((_) => false, isDraftThreadDocument);

  static const _postSubmitTarget = '$baseUrl/forum.php?mod=post&action=edit&extra=&editsubmit=yes';

  static String _buildThreadInfoUrl(String fid) => '$homePage?mod=post&action=newthread&fid=$fid';

  static String _buildThreadPostUrl(String fid) =>
      '$homePage?mod=post&action=newthread&fid=$fid&extra=&topicsubmit=yes';

  /// Fetch edit data from given [url].
  AsyncEither<uh.Document> fetchData(String url) => AsyncEither(() async {
    if (!isCurrent) return left(IdentityChangedException());
    final result = await _get(url);
    if (!isCurrent) return left(IdentityChangedException());
    return result.flatMap((response) {
      if (response.statusCode != 200 || response.data is! String) {
        return left(HttpRequestFailedException(response.statusCode));
      }
      final document = parseHtmlDocument(response.data as String);
      if (parseLoggedUidFromDocument(document) != _ownerUid) return left(IdentityChangedException());
      return right(document);
    });
  });

  AsyncEither<String> _submit(String url, Map<String, String> body, {String? expectedTid}) => AsyncEither(() async {
    if (!isCurrent) return left(IdentityChangedException());
    final result = await _post(url, body);
    if (!isCurrent) return left(IdentityChangedException());
    final Response<dynamic> response;
    switch (result) {
      case Left(:final value) when value is HttpHandshakeFailedException && [301, 302, 303].contains(value.statusCode):
        final target = submittedThreadUrl(value.headers?.value('location'), expectedTid: expectedTid);
        return target == null ? left(ThreadPublishLocationNotFoundException()) : right(target);
      case Left(:final value):
        return left(value);
      case Right(:final value):
        response = value;
    }
    final target = parseSubmissionResult(response, expectedTid: expectedTid);
    if (target != null) return right(target);
    if (response.data is String) {
      final document = parseHtmlDocument(response.data as String);
      final message = document.querySelector('#messagetext');
      if (message != null && !message.classes.contains('alert_right')) {
        return left(PostEditFailedToUploadResult(message.querySelector('p')?.innerText ?? ''));
      }
    }
    return left(ThreadPublishLocationNotFoundException());
  });

  /// Post some edited content to server. The content is in a certain post, with
  /// additional options provided by server.
  ///
  /// What's more, when editing a thread (means the first floor post in some
  /// thread), additional [threadType] and [threadTitle] are required.
  ///
  /// All fields are strings; submit once with URL-encoded form data.
  ///
  /// [fid], [tid] and [pid] is used to specify the post we made modification.
  ///
  /// [data] is post content, now in plain text.
  ///
  /// [threadType] is the number (String) of thread type.
  ///
  /// [options] is a map of option-name - option-value pair.
  AsyncVoidEither postEditedContent({
    required String formHash,
    required String postTime,
    required String delattachop,
    required String wysiwyg,
    required String fid,
    required String tid,
    required String pid,
    required String page,
    required String? threadType,
    required String? threadTitle,
    required String data,
    required Map<String, String> options,
    required String save,
    required String? perm,
    required int? price,
    String tags = '',
  }) => AsyncVoidEither(() async {
    final body = <String, String>{
      'formhash': formHash,
      'posttime': postTime,
      'delattachop': delattachop,
      'wysiwyg': wysiwyg,
      'fid': fid,
      'tid': tid,
      'pid': pid,
      'checkbox': '0',
      'page': page,
      'subject': threadTitle ?? '',
      'message': toOfficialMentions(data),
      'editsubmit': 'true',
      'save': save,
      'tags': tags,
      'price': '${price ?? ""}',
    };
    if (threadType != null) {
      body['typeid'] = threadType;
    }
    if (perm != null) {
      body['readperm'] = perm;
    }

    for (final entry in options.entries) {
      body[entry.key] = entry.value;
    }
    return (await _submit(_postSubmitTarget, body, expectedTid: tid).run()).map((_) {});
  });

  /// Fetch required info that used in posting new thread.
  ///
  /// This step is far before posting final thread content to server.
  AsyncEither<uh.Document> prepareInfo(String fid) => fetchData(_buildThreadInfoUrl(fid));

  /// Post new thread data to server.
  ///
  /// Generally the serer will response a status code of 301 with location in
  /// header to redirect to published thread page.
  AsyncEither<String> postThread(ThreadPublishInfo info) =>
      _submit(_buildThreadPostUrl(info.fid), info.toPostPayload());
}
